import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Password-based encryption for backup files.
///
/// File layout (all integers big-endian):
///
///     header  "MMBK" | version u8 (1) | kdf u8 (1 = PBKDF2-HMAC-SHA256) | iterations u32 | salt 16 | chunk size u32
///     chunk*  final u8 | length u32 | AES-256-GCM combined box (nonce 12 + ciphertext + tag 16)
///
/// Each chunk authenticates the header, its index and its final flag, so reordering, truncation,
/// or editing the header (e.g. lowering the iteration count) is detected.
enum BackupCrypto {
    static let magic = Data("MMBK".utf8)
    static let version: UInt8 = 1
    static let kdfPBKDF2: UInt8 = 1
    static let defaultIterations: UInt32 = 600_000
    static let maxIterations: UInt32 = 10_000_000
    static let chunkSize = 1 << 20
    private static let headerLength = 4 + 1 + 1 + 4 + 16 + 4

    enum Failure: LocalizedError, Equatable {
        case wrongPassword, passwordNeeded, damaged, unsupported, keyDerivation
        var errorDescription: String? {
            switch self {
            case .wrongPassword: "The password is wrong, or the backup is damaged."
            case .passwordNeeded: "This backup is encrypted. Enter its password."
            case .damaged: "The encrypted backup is damaged or incomplete."
            case .unsupported: "This backup was made by a newer version of MacMoney."
            case .keyDerivation: "Couldn't derive the encryption key."
            }
        }
    }

    static func isEncrypted(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == magic
    }

    static func encrypt(_ source: URL, to dest: URL, password: String, iterations: UInt32 = defaultIterations) throws {
        var salt = Data(count: 16)
        let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw Failure.keyDerivation }
        let key = try deriveKey(password, salt: salt, iterations: iterations)

        var header = magic
        header.append(version)
        header.append(kdfPBKDF2)
        header.append(bigEndian: iterations)
        header.append(salt)
        header.append(bigEndian: UInt32(chunkSize))

        FileManager.default.createFile(atPath: dest.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: dest)
        defer { try? input.close(); try? output.close() }
        try output.write(contentsOf: header)

        var index: UInt64 = 0
        var current = try input.read(upToCount: chunkSize) ?? Data()
        while true {
            let next = try input.read(upToCount: chunkSize) ?? Data()
            let final = next.isEmpty
            let box = try AES.GCM.seal(current, using: key, authenticating: aad(header, index, final))
            guard let combined = box.combined else { throw Failure.damaged }
            var record = Data([final ? 1 : 0])
            record.append(bigEndian: UInt32(combined.count))
            record.append(combined)
            try output.write(contentsOf: record)
            if final { break }
            current = next
            index += 1
        }
        try output.synchronize()
    }

    static func decrypt(_ source: URL, to dest: URL, password: String) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard let header = try input.read(upToCount: headerLength), header.count == headerLength,
              header.prefix(4) == magic else { throw Failure.damaged }
        guard header[4] == version, header[5] == kdfPBKDF2 else { throw Failure.unsupported }
        let iterations = header.readBigEndianUInt32(at: 6)
        let salt = header.subdata(in: 10..<26)
        // Bound the work factor: a damaged or hostile header must not make key derivation run forever.
        guard (100_000...maxIterations).contains(iterations) else { throw Failure.damaged }
        let key = try deriveKey(password, salt: salt, iterations: iterations)

        FileManager.default.createFile(atPath: dest.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }

        var index: UInt64 = 0
        while true {
            guard let meta = try input.read(upToCount: 5), meta.count == 5 else { throw Failure.damaged }
            let final = meta[meta.startIndex] == 1
            let length = Int(meta.readBigEndianUInt32(at: 1))
            guard length >= 28, length <= chunkSize + 64,
                  let combined = try input.read(upToCount: length), combined.count == length else { throw Failure.damaged }
            do {
                let box = try AES.GCM.SealedBox(combined: combined)
                try output.write(contentsOf: try AES.GCM.open(box, using: key, authenticating: aad(header, index, final)))
            } catch {
                throw index == 0 ? Failure.wrongPassword : Failure.damaged
            }
            if final { break }
            index += 1
        }
        // Nothing may follow the final chunk.
        if let extra = try input.read(upToCount: 1), !extra.isEmpty { throw Failure.damaged }
    }

    private static func aad(_ header: Data, _ index: UInt64, _ final: Bool) -> Data {
        var d = header
        d.append(bigEndian: index)
        d.append(final ? 1 : 0)
        return d
    }

    static func deriveKey(_ password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        let status = salt.withUnsafeBytes { s in
            pw.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) { pwPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, pw.count,
                                         s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &key, key.count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.keyDerivation }
        return SymmetricKey(data: key)
    }
}

/// The backup password, kept in the login keychain so automatic backups never prompt.
enum BackupKeychain {
    private static let service = "io.github.macmoney.backup"
    private static let account = "backup-password"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func password() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?) throws {
        SecItemDelete(query as CFDictionary)
        guard let password else { return }
        var q = query
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "MacMoney backup password"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Backup.Failure(message: "Couldn't save the password to the keychain (\(status)).")
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
