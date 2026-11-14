import XCTest
@testable import SoundStore

final class AgeTests: XCTestCase {
    // MARK: Bech32

    func testBech32ReadsAVectorOfTheStandard() throws {
        let decoded = try XCTUnwrap(Bech32.decode("abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw"))
        XCTAssertEqual(decoded.prefix, "abcdef")
        XCTAssertEqual(decoded.data.map { String(format: "%02x", $0) }.joined(), "00443214c74254b635cf84653a56d7c675be77df")
        XCTAssertEqual(Bech32.encode(prefix: "abcdef", data: decoded.data), "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw")
        XCTAssertNotNil(Bech32.decode("A12UEL5L"))
    }

    func testBech32RefusesWhatIsWrong() {
        XCTAssertNil(Bech32.decode("abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxx"), "wrong checksum")
        XCTAssertNil(Bech32.decode("Abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw"), "mixed case")
        XCTAssertNil(Bech32.decode("abcdef"), "no separator")
        XCTAssertNil(Bech32.decode("1qqqqqq"), "no prefix")
        XCTAssertNil(Bech32.decode("abc1bqqqqqq"), "a character outside the alphabet")
        XCTAssertNil(Bech32.decode(""))
    }

    // MARK: Identity

    func testAnIdentityComesBackFromItsText() throws {
        let identity = AgeIdentity.generate()
        XCTAssertTrue(identity.text.hasPrefix("AGE-SECRET-KEY-1"))
        XCTAssertEqual(identity.text, identity.text.uppercased())
        XCTAssertTrue(identity.recipient.hasPrefix("age1"))
        XCTAssertEqual(identity.recipient.count, 62)
        let again = try AgeIdentity("  \n" + identity.text + "\n ")
        XCTAssertEqual(again, identity)
        XCTAssertEqual(again.recipient, identity.recipient)
        XCTAssertNotEqual(AgeIdentity.generate(), identity)
    }

    func testWhatIsNotAnIdentityIsRefused() {
        let identity = AgeIdentity.generate()
        XCTAssertThrowsError(try AgeIdentity(""))
        XCTAssertThrowsError(try AgeIdentity("AGE-SECRET-KEY-1"))
        XCTAssertThrowsError(try AgeIdentity(identity.recipient), "a public key is not a key")
        XCTAssertThrowsError(try AgeIdentity(String(identity.text.dropLast()) + (identity.text.hasSuffix("Q") ? "P" : "Q")))
        XCTAssertThrowsError(try Age.encrypt(Data(), to: identity.text), "a secret key is not a recipient") { error in
            XCTAssertEqual(error as? AgeError, .invalidRecipient)
        }
        XCTAssertThrowsError(try Age.encrypt(Data(), to: "age1nonsense"))
    }

    // MARK: Files

    func testRoundTripAtEveryChunkEdge() throws {
        let identity = AgeIdentity.generate()
        for size in [0, 1, 15, 65535, 65536, 65537, 131072, 200_000] {
            let plain = madeUpBytes(size, seed: UInt64(size))
            let file = try Age.encrypt(plain, to: identity.recipient)
            XCTAssertTrue(file.starts(with: Data("age-encryption.org/v1\n-> X25519 ".utf8)))
            XCTAssertEqual(try Age.decrypt(file, with: identity), plain, "\(size) bytes")
        }
    }

    func testTheSameContentEncryptsDifferentlyEachTime() throws {
        let identity = AgeIdentity.generate()
        let plain = Data("a made-up sound".utf8)
        XCTAssertNotEqual(try Age.encrypt(plain, to: identity.recipient), try Age.encrypt(plain, to: identity.recipient))
    }

    func testAnotherKeyDoesNotOpenIt() throws {
        let file = try Age.encrypt(Data("secret".utf8), to: AgeIdentity.generate().recipient)
        XCTAssertThrowsError(try Age.decrypt(file, with: AgeIdentity.generate())) { error in
            XCTAssertEqual(error as? AgeError, .wrongKey)
        }
    }

    func testAChangedByteAnywhereIsNoticed() throws {
        let identity = AgeIdentity.generate()
        let file = try Age.encrypt(madeUpBytes(70_000), to: identity.recipient)
        // Header text, the MAC line, the nonce, both chunks and the last tag.
        for position in [3, 30, 80, 150, 190, 230, 300, 66_000, file.count - 1] {
            var changed = file
            changed[position] ^= 0x01
            XCTAssertThrowsError(try Age.decrypt(changed, with: identity), "byte \(position)")
        }
    }

    func testACutFileIsNoticed() throws {
        let identity = AgeIdentity.generate()
        let plain = madeUpBytes(65536 * 2)
        let file = try Age.encrypt(plain, to: identity.recipient)
        let headerLength = file.count - 16 - 2 * (65536 + 16)
        // Cut exactly after the first chunk: every remaining byte is authentic, only the end is missing.
        let cuts = [0, 10, headerLength, headerLength + 16, headerLength + 16 + 65536 + 16, file.count - 1]
        for cut in cuts {
            XCTAssertThrowsError(try Age.decrypt(file.prefix(cut), with: identity), "cut at \(cut)")
        }
        XCTAssertThrowsError(try Age.decrypt(file + Data([0]), with: identity), "a byte too many")
        XCTAssertEqual(try Age.decrypt(file, with: identity), plain)
    }

    func testWhatIsNotAnAgeFileIsDamaged() {
        let identity = AgeIdentity.generate()
        for text in ["", "hello", "age-encryption.org/v2\n", "age-encryption.org/v1\n--- abc\n", "age-encryption.org/v1\nnonsense\n"] {
            XCTAssertThrowsError(try Age.decrypt(Data(text.utf8), with: identity)) { error in
                XCTAssertEqual(error as? AgeError, .damaged, text)
            }
        }
    }

    func testBase64IsOnlyTakenInItsCanonicalForm() {
        XCTAssertEqual(Age.unbase64("AAEC"), Data([0, 1, 2]))
        XCTAssertEqual(Age.unbase64("AAE"), Data([0, 1]))
        XCTAssertNil(Age.unbase64("AAE="), "padding")
        XCTAssertNil(Age.unbase64("AAF"), "stray bits")
        XCTAssertNil(Age.unbase64("A"))
        XCTAssertNil(Age.unbase64("AA E"))
        XCTAssertEqual(Age.base64(Data([0, 1])), "AAE")
    }
}

/// The same files through the reference tool: what this app writes, `age` reads, and the other way around.
final class AgeInteropTests: XCTestCase {
    private static let age = "/opt/homebrew/bin/age"
    private static let keygen = "/opt/homebrew/bin/age-keygen"
    private static let sizes = [0, 1, 65535, 65536, 65537, 200_000]
    private var folder: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.age),
              FileManager.default.isExecutableFile(atPath: Self.keygen) else {
            throw XCTSkip("age is not installed at \(Self.age)")
        }
        folder = try makeTemporaryFolder(self, "age")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], input: Data? = nil) throws -> Data {
        let result = try SSHLocation.runProcess(tool, arguments, input)
        // Never the output of a failed call: it could hold a key.
        XCTAssertEqual(result.status, 0, "\(URL(fileURLWithPath: tool).lastPathComponent) failed")
        return result.output
    }

    /// The key as a file only the user reads, for `age -i`. The folder goes with the test.
    private func keyFile(_ identity: AgeIdentity) throws -> String {
        let url = folder.appendingPathComponent("key-\(UUID().uuidString).txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data((identity.text + "\n").utf8),
                                                     attributes: [.posixPermissions: 0o600]))
        return url.path
    }

    func testAgeOpensWhatThisAppWrites() throws {
        let identity = AgeIdentity.generate()
        let key = try keyFile(identity)
        for size in Self.sizes {
            let plain = madeUpBytes(size, seed: UInt64(size) + 1)
            let file = try Age.encrypt(plain, to: identity.recipient)
            XCTAssertEqual(try run(Self.age, ["-d", "-i", key], input: file), plain, "\(size) bytes")
        }
    }

    func testThisAppOpensWhatAgeWrites() throws {
        let identity = AgeIdentity.generate()
        for size in Self.sizes {
            let plain = madeUpBytes(size, seed: UInt64(size) + 2)
            let file = try run(Self.age, ["-r", identity.recipient], input: plain)
            XCTAssertEqual(try Age.decrypt(file, with: identity), plain, "\(size) bytes")
        }
    }

    func testAKeyOfAgeKeygenReadsTheSame() throws {
        let path = folder.appendingPathComponent("made.txt").path
        try run(Self.keygen, ["-o", path])
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        let secret = try XCTUnwrap(lines.first { $0.hasPrefix("AGE-SECRET-KEY-1") })
        let identity = try AgeIdentity(String(secret))
        XCTAssertTrue(identity.text == secret, "the key's text differs")
        let shown = String(decoding: try run(Self.keygen, ["-y", path]), as: UTF8.self)
        XCTAssertEqual(identity.recipient, shown.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A file for several recipients: stanzas of other keys and of other kinds are passed over.
    func testOtherRecipientsInTheFileAreIgnored() throws {
        let identity = AgeIdentity.generate()
        let other = AgeIdentity.generate()
        let plain = Data("for two".utf8)
        var arguments = ["-r", other.recipient]
        let sshKey = folder.appendingPathComponent("made-up-ssh").path
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen"),
           (try? SSHLocation.runProcess("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", sshKey], nil))?.status == 0 {
            arguments += ["-R", sshKey + ".pub"]
        }
        let file = try run(Self.age, arguments + ["-r", identity.recipient], input: plain)
        XCTAssertEqual(try Age.decrypt(file, with: identity), plain)
        XCTAssertEqual(try Age.decrypt(file, with: other), plain)
        XCTAssertThrowsError(try Age.decrypt(file, with: AgeIdentity.generate())) { error in
            XCTAssertEqual(error as? AgeError, .wrongKey)
        }
    }
}
