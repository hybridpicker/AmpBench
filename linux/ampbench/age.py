"""The age v1 file format (age-encryption.org/v1) with X25519 recipients, binary and not armored, as the sound store
uses it. A port of Sources/SoundStore/Age.swift and Bech32.swift: files written here open on the Mac and the iPad and
with `age -d -i key.txt`, and files written there open here.

The primitives (X25519, HKDF, ChaCha20-Poly1305) come from the `cryptography` package; only the file format and the
Bech32 text form of the keys are written out here."""
from __future__ import annotations

import base64
import hashlib
import hmac
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from .i18n import tr

INVALID_IDENTITY, INVALID_RECIPIENT = "invalid_identity", "invalid_recipient"
DAMAGED, WRONG_KEY = "damaged", "wrong_key"


class AgeError(Exception):
    """`kind` says what went wrong: `DAMAGED` is not an age file or one cut short, `WRONG_KEY` a file that is fine
    but was not encrypted for this key."""

    def __init__(self, kind: str):
        self.kind = kind
        super().__init__({
            INVALID_IDENTITY: tr("This is not a valid key. A key starts with AGE-SECRET-KEY-1."),
            INVALID_RECIPIENT: tr("This is not a valid public key. It starts with age1."),
            DAMAGED: tr("The encrypted file is damaged or incomplete."),
            WRONG_KEY: tr("The file was encrypted for a different key."),
        }[kind])


# MARK: Bech32

_ALPHABET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
_VALUES = {character: index for index, character in enumerate(_ALPHABET)}
_GENERATORS = (0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)


def _polymod(values: list[int]) -> int:
    checksum = 1
    for value in values:
        top = checksum >> 25
        checksum = (checksum & 0x1FFFFFF) << 5 ^ value
        for bit, generator in enumerate(_GENERATORS):
            if (top >> bit) & 1:
                checksum ^= generator
    return checksum


def _expand(prefix: str) -> list[int]:
    codes = prefix.encode("ascii")
    return [code >> 5 for code in codes] + [0] + [code & 31 for code in codes]


def _regroup(values, source: int, target: int, pad: bool) -> list[int] | None:
    """Regroups bits. Encoding pads the last group with zeros; decoding refuses padding that is not zero or too
    long."""
    accumulator, bits, output, mask = 0, 0, [], (1 << target) - 1
    for value in values:
        if value >> source:
            return None
        accumulator = (accumulator << source) | value
        bits += source
        while bits >= target:
            bits -= target
            output.append((accumulator >> bits) & mask)
    if pad:
        if bits:
            output.append((accumulator << (target - bits)) & mask)
    elif bits >= source or (accumulator << (target - bits)) & mask:
        return None
    return output


def bech32_encode(prefix: str, data: bytes) -> str:
    """Bech32 (BIP 173, not bech32m) without the 90-character limit, in lower case. `prefix` is lower case too."""
    groups = _regroup(data, 8, 5, True) or []
    residue = _polymod(_expand(prefix) + groups + [0] * 6) ^ 1
    checksum = [(residue >> (5 * (5 - index))) & 31 for index in range(6)]
    return prefix + "1" + "".join(_ALPHABET[group] for group in groups + checksum)


def bech32_decode(text: str) -> tuple[str, bytes] | None:
    """The prefix in lower case and the bytes, or None for anything that is not valid Bech32."""
    if not text or not all(32 < ord(character) < 127 for character in text):
        return None
    lower = text.lower()
    # Mixed case is an error, so a mistyped key is not silently accepted.
    if text != lower and text != text.upper():
        return None
    separator = lower.rfind("1")
    if separator < 1:
        return None
    prefix, rest = lower[:separator], lower[separator + 1:]
    if len(rest) < 6 or any(character not in _VALUES for character in rest):
        return None
    groups = [_VALUES[character] for character in rest]
    if _polymod(_expand(prefix) + groups) != 1:
        return None
    data = _regroup(groups[:-6], 5, 8, False)
    return None if data is None else (prefix, bytes(data))


# MARK: Keys

_IDENTITY_PREFIX = "age-secret-key-"
_RECIPIENT_PREFIX = "age"


class AgeIdentity:
    """A secret key of the age format (X25519). Its text form, `AGE-SECRET-KEY-1…`, is what the user keeps to restore
    the store on another device, and what the standard `age` tool takes with `-i`."""

    def __init__(self, text: str):
        """Reads `AGE-SECRET-KEY-1…`. Whitespace around it is ignored, as it comes with copying."""
        decoded = bech32_decode(text.strip())
        if decoded is None or decoded[0] != _IDENTITY_PREFIX or len(decoded[1]) != 32:
            raise AgeError(INVALID_IDENTITY)
        self._secret = decoded[1]

    @classmethod
    def generate(cls) -> "AgeIdentity":
        identity = cls.__new__(cls)
        identity._secret = os.urandom(32)
        return identity

    @property
    def secret(self) -> bytes:
        """The 32 secret bytes. Only the store's naming of objects reads them; they are never shown or logged."""
        return self._secret

    @property
    def text(self) -> str:
        return bech32_encode(_IDENTITY_PREFIX, self._secret).upper()

    @property
    def recipient(self) -> str:
        """The public key, `age1…`. Enough to encrypt, useless for reading."""
        return bech32_encode(_RECIPIENT_PREFIX, self._public())

    def _agreement(self) -> X25519PrivateKey:
        return X25519PrivateKey.from_private_bytes(self._secret)

    def _public(self) -> bytes:
        return self._agreement().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)

    def __eq__(self, other) -> bool:
        return isinstance(other, AgeIdentity) and hmac.compare_digest(self._secret, other._secret)

    def __hash__(self) -> int:
        return hash(self.recipient)

    def __repr__(self) -> str:  # never the secret, wherever an identity ends up being printed
        return f"AgeIdentity({self.recipient})"


# MARK: Files

_VERSION_LINE = "age-encryption.org/v1"
_WRAP_INFO = b"age-encryption.org/v1/X25519"
_CHUNK = 64 * 1024
_TAG = 16


def _hkdf(key: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt or None, info=info).derive(key)


def _header_key(file_key: bytes) -> bytes:
    return _hkdf(file_key, b"", b"header")


def _payload_key(file_key: bytes, nonce: bytes) -> bytes:
    return _hkdf(file_key, nonce, b"payload")


def _chunk_nonce(counter: int, last: bool) -> bytes:
    """Eleven bytes of counter, big-endian, and one byte that marks the last chunk, so a cut file cannot pass."""
    return counter.to_bytes(11, "big") + (b"\x01" if last else b"\x00")


def _base64(data: bytes) -> str:
    """Standard alphabet without padding, as the format demands."""
    return base64.b64encode(data).decode("ascii").rstrip("=")


def _unbase64(text: str) -> bytes | None:
    """Only the canonical form: no padding, no stray bits."""
    if "=" in text or len(text) % 4 == 1:
        return None
    try:
        data = base64.b64decode(text + "=" * (-len(text) % 4), validate=True)
    except ValueError:
        return None
    return data if _base64(data) == text else None


def _shared(private: X25519PrivateKey, public: bytes) -> bytes | None:
    """The shared secret, or None for a point that gives none (all zeros)."""
    try:
        shared = private.exchange(X25519PublicKey.from_public_bytes(public))
    except ValueError:
        return None
    return shared if any(shared) else None


def encrypt(plain: bytes, recipient: str) -> bytes:
    decoded = bech32_decode(recipient.strip())
    if (decoded is None or decoded[0] != _RECIPIENT_PREFIX or len(decoded[1]) != 32
            or recipient.lower() != recipient):
        raise AgeError(INVALID_RECIPIENT)
    public = decoded[1]
    file_key = os.urandom(16)
    ephemeral = X25519PrivateKey.generate()
    share = ephemeral.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    shared = _shared(ephemeral, public)
    if shared is None:
        raise AgeError(INVALID_RECIPIENT)
    wrap_key = _hkdf(shared, share + public, _WRAP_INFO)
    wrapped = ChaCha20Poly1305(wrap_key).encrypt(bytes(12), file_key, None)
    header = f"{_VERSION_LINE}\n-> X25519 {_base64(share)}\n{_base64(wrapped)}\n---".encode("ascii")
    mac = hmac.new(_header_key(file_key), header, hashlib.sha256).digest()
    nonce = os.urandom(16)
    cipher = ChaCha20Poly1305(_payload_key(file_key, nonce))
    output = [header, f" {_base64(mac)}\n".encode("ascii"), nonce]
    offset, counter = 0, 0
    while True:
        end = min(offset + _CHUNK, len(plain))
        last = end == len(plain)
        output.append(cipher.encrypt(_chunk_nonce(counter, last), plain[offset:end], None))
        offset, counter = end, counter + 1
        if last:
            break
    return b"".join(output)


def decrypt(file: bytes, identity: AgeIdentity) -> bytes:
    file = bytes(file)
    stanzas, mac, maced_end, payload_start = _parse_header(file)
    agreement = identity._agreement()
    own_public = identity._public()
    file_key = None
    for arguments, body in stanzas:
        if arguments[0] != "X25519":
            continue
        share = _unbase64(arguments[1]) if len(arguments) == 2 else None
        if share is None or len(share) != 32 or len(body) != 32:
            raise AgeError(DAMAGED)
        shared = _shared(agreement, share)
        if shared is None:
            raise AgeError(DAMAGED)
        try:
            file_key = ChaCha20Poly1305(_hkdf(shared, share + own_public, _WRAP_INFO)).decrypt(bytes(12), body, None)
        except InvalidTag:
            continue
        break
    if file_key is None:
        raise AgeError(WRONG_KEY)
    expected = hmac.new(_header_key(file_key), file[:maced_end], hashlib.sha256).digest()
    if not hmac.compare_digest(mac, expected):
        raise AgeError(DAMAGED)

    payload = file[payload_start:]
    if len(payload) < 16 + _TAG:
        raise AgeError(DAMAGED)
    cipher = ChaCha20Poly1305(_payload_key(file_key, payload[:16]))
    offset, counter, plain = 16, 0, []
    while True:
        end = min(offset + _CHUNK + _TAG, len(payload))
        last = end == len(payload)
        chunk = payload[offset:end]
        # A final chunk without content is only right for an empty file. Anywhere else it means a cut.
        if len(chunk) < _TAG or (len(chunk) == _TAG and counter != 0):
            raise AgeError(DAMAGED)
        try:
            plain.append(cipher.decrypt(_chunk_nonce(counter, last), chunk, None))
        except InvalidTag:
            raise AgeError(DAMAGED) from None
        if last:
            break
        offset, counter = end, counter + 1
    return b"".join(plain)


def _parse_header(file: bytes) -> tuple[list[tuple[list[str], bytes]], bytes, int, int]:
    """The stanzas, the MAC, where what the MAC covers ends (after the `---`), and where the payload starts."""
    position = 0

    def line() -> tuple[str, int]:
        # The next line without its newline. The header is ASCII; the payload after it is not read as lines.
        nonlocal position
        start = position
        newline = file.find(b"\n", start)
        if newline < 0 or newline - start > 4096 or not all(32 <= byte < 127 for byte in file[start:newline]):
            raise AgeError(DAMAGED)
        position = newline + 1
        return file[start:newline].decode("ascii"), start

    if line()[0] != _VERSION_LINE:
        raise AgeError(DAMAGED)
    stanzas: list[tuple[list[str], bytes]] = []
    while True:
        text, start = line()
        if text.startswith("--- "):
            mac = _unbase64(text[4:])
            if mac is None or len(mac) != 32 or not stanzas:
                raise AgeError(DAMAGED)
            return stanzas, mac, start + 3, position
        if not text.startswith("-> "):
            raise AgeError(DAMAGED)
        arguments = text[3:].split(" ")
        if "" in arguments:
            raise AgeError(DAMAGED)
        # The body ends with the first line shorter than 64 columns, which may be empty.
        body = b""
        while True:
            body_line, _ = line()
            data = _unbase64(body_line) if len(body_line) <= 64 else None
            if data is None:
                raise AgeError(DAMAGED)
            body += data
            if len(body_line) < 64:
                break
        stanzas.append((arguments, body))
        if len(stanzas) > 64:
            raise AgeError(DAMAGED)
