"""The age format of the sound store: keys as text, files, and the standard `age` tool on both sides."""
import shutil
import subprocess

import pytest

pytest.importorskip("cryptography")

from ampbench import age  # noqa: E402
from ampbench.age import AgeError, AgeIdentity  # noqa: E402


def made_up_bytes(count: int, seed: int = 7) -> bytes:
    """Bytes that look random but are the same in every run (as in Tests/SoundStoreTests/Support.swift)."""
    mask = (1 << 64) - 1
    state = (seed * 6364136223846793005 + 1442695040888963407) & mask
    data = bytearray(count)
    for index in range(count):
        state = (state * 6364136223846793005 + 1442695040888963407) & mask
        data[index] = (state >> 33) & 0xFF
    return bytes(data)


# MARK: Bech32

def test_bech32_reads_a_vector_of_the_standard():
    prefix, data = age.bech32_decode("abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw")
    assert prefix == "abcdef"
    assert data.hex() == "00443214c74254b635cf84653a56d7c675be77df"
    assert age.bech32_encode("abcdef", data) == "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw"
    assert age.bech32_decode("A12UEL5L") is not None


@pytest.mark.parametrize("text", [
    "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxx",  # wrong checksum
    "Abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",  # mixed case
    "abcdef",  # no separator
    "1qqqqqq",  # no prefix
    "abc1bqqqqqq",  # a character outside the alphabet
    "",
])
def test_bech32_refuses_what_is_wrong(text):
    assert age.bech32_decode(text) is None


# MARK: Identity

def test_an_identity_comes_back_from_its_text():
    identity = AgeIdentity.generate()
    assert identity.text.startswith("AGE-SECRET-KEY-1")
    assert identity.text == identity.text.upper()
    assert identity.recipient.startswith("age1") and len(identity.recipient) == 62
    again = AgeIdentity("  \n" + identity.text + "\n ")
    assert again == identity and again.recipient == identity.recipient
    assert AgeIdentity.generate() != identity
    assert AgeIdentity(identity.text.lower()) == identity
    assert identity.text not in repr(identity) and identity.text not in str(identity)


def test_a_known_key_gives_the_public_key_of_the_standard():
    # RFC 7748, section 6.1: Alice's private and public key. The text form is made here, so no key sits in this file.
    secret = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    identity = AgeIdentity(age.bech32_encode("age-secret-key-", secret).upper())
    public = bytes.fromhex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    assert identity.recipient == age.bech32_encode("age", public)


def test_what_is_not_an_identity_is_refused():
    identity = AgeIdentity.generate()
    last = "P" if identity.text.endswith("Q") else "Q"
    for text in ["", "AGE-SECRET-KEY-1", identity.recipient, identity.text[:-1] + last,
                 identity.text[:20] + identity.text[20:].lower()]:
        with pytest.raises(AgeError) as caught:
            AgeIdentity(text)
        assert caught.value.kind == age.INVALID_IDENTITY
    with pytest.raises(AgeError) as caught:
        age.encrypt(b"", identity.text)  # a secret key is not a recipient
    assert caught.value.kind == age.INVALID_RECIPIENT
    with pytest.raises(AgeError):
        age.encrypt(b"", "age1nonsense")
    with pytest.raises(AgeError):
        age.encrypt(b"", identity.recipient.upper())


# MARK: Files

def test_round_trip_at_every_chunk_edge():
    identity = AgeIdentity.generate()
    for size in [0, 1, 15, 65535, 65536, 65537, 131072, 200_000]:
        plain = made_up_bytes(size, seed=size)
        file = age.encrypt(plain, identity.recipient)
        assert file.startswith(b"age-encryption.org/v1\n-> X25519 ")
        assert age.decrypt(file, identity) == plain, f"{size} bytes"
        # 16 bytes of nonce, and a tag of 16 for every chunk of 64 KiB.
        header = file.index(b"\n--- ") + 5 + 43 + 1
        assert len(file) == header + 16 + size + 16 * max(1, -(-size // 65536))


def test_the_same_content_encrypts_differently_each_time():
    identity = AgeIdentity.generate()
    assert age.encrypt(b"a made-up sound", identity.recipient) != age.encrypt(b"a made-up sound", identity.recipient)


def test_another_key_does_not_open_it():
    file = age.encrypt(b"secret", AgeIdentity.generate().recipient)
    with pytest.raises(AgeError) as caught:
        age.decrypt(file, AgeIdentity.generate())
    assert caught.value.kind == age.WRONG_KEY


def test_a_changed_byte_anywhere_is_noticed():
    identity = AgeIdentity.generate()
    file = age.encrypt(made_up_bytes(70_000), identity.recipient)
    # Header text, the stanza, the MAC line, the nonce, both chunks and the last tag.
    for position in [3, 30, 80, 150, 190, 230, 300, 66_000, len(file) - 1]:
        changed = bytearray(file)
        changed[position] ^= 0x01
        with pytest.raises(AgeError):
            age.decrypt(bytes(changed), identity)


def test_a_cut_or_lengthened_file_is_noticed():
    identity = AgeIdentity.generate()
    file = age.encrypt(made_up_bytes(140_000), identity.recipient)
    payload = file.index(b"\n--- ") + 49 + 16
    cuts = [0, 10, payload - 16, payload, payload + 10, payload + 65536 + 16, payload + 2 * (65536 + 16), len(file) - 1]
    for length in cuts:
        with pytest.raises(AgeError) as caught:
            age.decrypt(file[:length], identity)
        assert caught.value.kind == age.DAMAGED, length
    with pytest.raises(AgeError):
        age.decrypt(file + b"\x00", identity)
    # A whole chunk taken out of the middle, or the two swapped.
    first, second = file[payload:payload + 65552], file[payload + 65552:payload + 2 * 65552]
    for mixed in [file[:payload] + second + file[payload + 2 * 65552:], file[:payload] + second + first + file[payload + 2 * 65552:]]:
        with pytest.raises(AgeError):
            age.decrypt(mixed, identity)


def test_what_is_not_an_age_file_is_refused():
    identity = AgeIdentity.generate()
    file = age.encrypt(b"x", identity.recipient)
    for other in [b"", b"plain text", b"age-encryption.org/v2\n" + file[22:], file.replace(b"-> X25519", b"-> x25519", 1),
                  b"age-encryption.org/v1\n--- " + b"A" * 43 + b"\n" + bytes(40)]:
        with pytest.raises(AgeError):
            age.decrypt(other, identity)


# MARK: The standard tool

needs_age = pytest.mark.skipif(not (shutil.which("age") and shutil.which("age-keygen")), reason="the age tool is not installed")


@needs_age
def test_the_age_tool_opens_what_is_written_here(tmp_path):
    key_file = tmp_path / "key.txt"
    subprocess.run(["age-keygen", "-o", str(key_file)], check=True, capture_output=True)
    identity = AgeIdentity(next(line for line in key_file.read_text().splitlines() if not line.startswith("#")))
    public = subprocess.run(["age-keygen", "-y", str(key_file)], check=True, capture_output=True, text=True).stdout.strip()
    assert identity.recipient == public
    for size in [0, 5, 65536, 150_000]:
        plain = made_up_bytes(size, seed=size + 1)
        sealed = tmp_path / f"{size}.age"
        sealed.write_bytes(age.encrypt(plain, identity.recipient))
        opened = subprocess.run(["age", "-d", "-i", str(key_file), str(sealed)], check=True, capture_output=True).stdout
        assert opened == plain, f"{size} bytes"


@needs_age
def test_what_the_age_tool_writes_opens_here(tmp_path):
    identity = AgeIdentity.generate()
    other = AgeIdentity.generate()
    for size in [0, 5, 65536, 150_000]:
        plain = made_up_bytes(size, seed=size + 2)
        source = tmp_path / "plain"
        source.write_bytes(plain)
        sealed = subprocess.run(["age", "-r", identity.recipient, str(source)], check=True, capture_output=True).stdout
        assert age.decrypt(sealed, identity) == plain, f"{size} bytes"
    # For two recipients: the second stanza is ours.
    sealed = subprocess.run(["age", "-r", other.recipient, "-r", identity.recipient, str(source)], check=True,
                            capture_output=True).stdout
    assert age.decrypt(sealed, identity) == plain
    with pytest.raises(AgeError) as caught:
        age.decrypt(sealed, AgeIdentity.generate())
    assert caught.value.kind == age.WRONG_KEY
