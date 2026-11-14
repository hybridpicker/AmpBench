import AmpText
import CryptoKit
import Foundation

public enum AgeError: LocalizedError, Equatable {
    case invalidIdentity
    case invalidRecipient
    /// Not an age file, or one damaged or cut short.
    case damaged
    /// The file is fine, but it was not encrypted for this key.
    case wrongKey

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: tr("This is not a valid key. A key starts with AGE-SECRET-KEY-1.")
        case .invalidRecipient: tr("This is not a valid public key. It starts with age1.")
        case .damaged: tr("The encrypted file is damaged or incomplete.")
        case .wrongKey: tr("The file was encrypted for a different key.")
        }
    }
}

/// A secret key of the age format (X25519). Its text form, `AGE-SECRET-KEY-1…`, is what the user keeps to restore the
/// store on another device, and what the standard `age` tool takes with `-i`.
public struct AgeIdentity: Sendable, Equatable {
    static let prefix = "age-secret-key-"
    static let recipientPrefix = "age"

    /// The 32 secret bytes. Internal, so that nothing outside the module can log them by accident.
    let secret: Data

    private init(secret: Data) {
        self.secret = secret
    }

    public static func generate() -> AgeIdentity {
        AgeIdentity(secret: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    /// Reads `AGE-SECRET-KEY-1…`. Whitespace around it is ignored, as it comes with copying.
    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (prefix, data) = Bech32.decode(trimmed), prefix == Self.prefix, data.count == 32,
              (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)) != nil else {
            throw AgeError.invalidIdentity
        }
        secret = data
    }

    public var text: String {
        Bech32.encode(prefix: Self.prefix, data: secret).uppercased()
    }

    /// The public key, `age1…`. Enough to encrypt, useless for reading.
    public var recipient: String {
        Bech32.encode(prefix: Self.recipientPrefix, data: agreement.publicKey.rawRepresentation)
    }

    var agreement: Curve25519.KeyAgreement.PrivateKey {
        // The bytes were checked when the identity was made.
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret)
    }
}

/// The age v1 file format (age-encryption.org/v1) with X25519 recipients, binary and not armored. Files written here
/// open with `age -d -i key.txt`, and files written by `age -r age1…` open here.
public enum Age {
    private static let versionLine = "age-encryption.org/v1"
    private static let wrapInfo = Data("age-encryption.org/v1/X25519".utf8)
    private static let chunkSize = 64 * 1024
    private static let tagSize = 16

    public static func encrypt(_ plain: Data, to recipient: String) throws -> Data {
        guard let (prefix, publicBytes) = Bech32.decode(recipient.trimmingCharacters(in: .whitespacesAndNewlines)),
              prefix == AgeIdentity.recipientPrefix, publicBytes.count == 32, recipient.lowercased() == recipient,
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicBytes) else {
            throw AgeError.invalidRecipient
        }
        let fileKey = SymmetricKey(size: .bits128)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let share = ephemeral.publicKey.rawRepresentation
        guard let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: publicKey), !isZero(shared) else {
            throw AgeError.invalidRecipient
        }
        let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: share + publicBytes,
                                                     sharedInfo: wrapInfo, outputByteCount: 32)
        let wrapped = try ChaChaPoly.seal(fileKey.withUnsafeBytes { Data($0) }, using: wrapKey,
                                          nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        var header = Data("\(versionLine)\n-> X25519 \(base64(share))\n\(base64(wrapped.ciphertext + wrapped.tag))\n---".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: header, using: headerKey(fileKey))
        header.append(Data(" \(base64(Data(mac)))\n".utf8))

        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let payloadKey = payloadKey(fileKey, nonce: nonce)
        var output = header + nonce
        output.reserveCapacity(output.count + plain.count + (plain.count / chunkSize + 1) * tagSize)
        var offset = plain.startIndex
        var counter: UInt64 = 0
        repeat {
            let end = min(offset + chunkSize, plain.endIndex)
            let isLast = end == plain.endIndex
            let box = try ChaChaPoly.seal(plain[offset..<end], using: payloadKey,
                                          nonce: chunkNonce(counter, last: isLast))
            output.append(box.ciphertext)
            output.append(box.tag)
            offset = end
            counter += 1
        } while offset < plain.endIndex
        return output
    }

    public static func decrypt(_ file: Data, with identity: AgeIdentity) throws -> Data {
        let file = Data(file)  // indices from zero
        let header = try parseHeader(file)
        let agreement = identity.agreement
        let ownPublic = agreement.publicKey.rawRepresentation
        var fileKey: SymmetricKey?
        for stanza in header.stanzas where stanza.arguments.first == "X25519" {
            guard stanza.arguments.count == 2, let share = unbase64(stanza.arguments[1]), share.count == 32,
                  stanza.body.count == 32 else { throw AgeError.damaged }
            guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: share),
                  let shared = try? agreement.sharedSecretFromKeyAgreement(with: publicKey), !isZero(shared) else {
                throw AgeError.damaged
            }
            let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: share + ownPublic,
                                                         sharedInfo: wrapInfo, outputByteCount: 32)
            guard let box = try? ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(count: 12)),
                                                      ciphertext: stanza.body.prefix(16), tag: stanza.body.suffix(16)),
                  let key = try? ChaChaPoly.open(box, using: wrapKey) else { continue }
            fileKey = SymmetricKey(data: key)
            break
        }
        guard let fileKey else { throw AgeError.wrongKey }
        guard HMAC<SHA256>.isValidAuthenticationCode(header.mac, authenticating: file[..<header.macedEnd],
                                                     using: headerKey(fileKey)) else { throw AgeError.damaged }

        let payload = file[header.payloadStart...]
        guard payload.count >= 16 + tagSize else { throw AgeError.damaged }
        let payloadKey = payloadKey(fileKey, nonce: Data(payload.prefix(16)))
        var offset = payload.startIndex + 16
        var counter: UInt64 = 0
        var plain = Data()
        plain.reserveCapacity(payload.count)
        while true {
            let end = min(offset + chunkSize + tagSize, payload.endIndex)
            let isLast = end == payload.endIndex
            let chunk = payload[offset..<end]
            // A final chunk without content is only right for an empty file. Anywhere else it means a cut.
            guard chunk.count >= tagSize, chunk.count > tagSize || counter == 0 else { throw AgeError.damaged }
            guard let box = try? ChaChaPoly.SealedBox(nonce: chunkNonce(counter, last: isLast),
                                                      ciphertext: chunk.dropLast(tagSize), tag: chunk.suffix(tagSize)),
                  let opened = try? ChaChaPoly.open(box, using: payloadKey) else { throw AgeError.damaged }
            plain.append(opened)
            if isLast { break }
            offset = end
            counter += 1
        }
        return plain
    }

    // MARK: Header

    private struct Stanza {
        var arguments: [String]
        var body: Data
    }

    private struct Header {
        var stanzas: [Stanza]
        var mac: Data
        /// Up to and including the `---` of the last line: what the MAC covers.
        var macedEnd: Int
        var payloadStart: Int
    }

    private static func parseHeader(_ file: Data) throws -> Header {
        var position = 0
        /// The next line without its newline. The header is ASCII; the payload after it is not read as lines.
        func line() throws -> (text: String, start: Int) {
            let start = position
            guard let newline = file[position...].firstIndex(of: 0x0A), newline - start <= 4096,
                  let text = String(data: file[start..<newline], encoding: .utf8),
                  text.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw AgeError.damaged }
            position = newline + 1
            return (text, start)
        }
        guard try line().text == versionLine else { throw AgeError.damaged }
        var stanzas: [Stanza] = []
        while true {
            let (text, start) = try line()
            if text.hasPrefix("--- ") {
                guard let mac = unbase64(String(text.dropFirst(4))), mac.count == 32, !stanzas.isEmpty else {
                    throw AgeError.damaged
                }
                return Header(stanzas: stanzas, mac: mac, macedEnd: start + 3, payloadStart: position)
            }
            guard text.hasPrefix("-> ") else { throw AgeError.damaged }
            let arguments = text.dropFirst(3).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard !arguments.isEmpty, !arguments.contains("") else { throw AgeError.damaged }
            // The body ends with the first line shorter than 64 columns, which may be empty.
            var body = Data()
            while true {
                let (bodyLine, _) = try line()
                guard bodyLine.count <= 64, let bytes = unbase64(bodyLine) else { throw AgeError.damaged }
                body.append(bytes)
                if bodyLine.count < 64 { break }
            }
            stanzas.append(Stanza(arguments: arguments, body: body))
            guard stanzas.count <= 64 else { throw AgeError.damaged }
        }
    }

    // MARK: Pieces

    private static func headerKey(_ fileKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: fileKey, salt: Data(), info: Data("header".utf8), outputByteCount: 32)
    }

    private static func payloadKey(_ fileKey: SymmetricKey, nonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: fileKey, salt: nonce, info: Data("payload".utf8), outputByteCount: 32)
    }

    /// Eleven bytes of counter, big-endian, and one byte that marks the last chunk, so a cut file cannot pass.
    private static func chunkNonce(_ counter: UInt64, last: Bool) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 3)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(last ? 1 : 0)
        return try ChaChaPoly.Nonce(data: bytes)
    }

    private static func isZero(_ secret: SharedSecret) -> Bool {
        secret.withUnsafeBytes { $0.allSatisfy { $0 == 0 } }
    }

    /// Standard alphabet without padding, as the format demands.
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Only the canonical form: no padding, no stray bits.
    static func unbase64(_ text: String) -> Data? {
        guard !text.contains("="), text.count % 4 != 1 else { return nil }
        let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), base64(data) == text else { return nil }
        return data
    }
}
