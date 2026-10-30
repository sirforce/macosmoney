import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class BackupCryptoTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacMoneyCryptoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        for k in [Backup.Key.pendingRestore, Backup.Key.pendingRestoreName, Backup.Key.pendingRestoreIsStaged, Backup.Key.lastRestoreResult] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    /// 2.5 chunks of random bytes, so chunking and the final-chunk flag are exercised.
    private func randomFile() throws -> (URL, Data) {
        var bytes = [UInt8](repeating: 0, count: BackupCrypto.chunkSize * 5 / 2)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let url = dir.appendingPathComponent("plain.bin")
        let data = Data(bytes)
        try data.write(to: url)
        return (url, data)
    }

    func testRoundTripAndWrongPassword() throws {
        let (plain, data) = try randomFile()
        let enc = dir.appendingPathComponent("enc.bin")
        try BackupCrypto.encrypt(plain, to: enc, password: "correct horse battery", iterations: 100_000)
        XCTAssertTrue(BackupCrypto.isEncrypted(enc))
        XCTAssertFalse(BackupCrypto.isEncrypted(plain))
        let attrs = try FileManager.default.attributesOfItem(atPath: enc.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let out = dir.appendingPathComponent("out.bin")
        try BackupCrypto.decrypt(enc, to: out, password: "correct horse battery")
        XCTAssertEqual(try Data(contentsOf: out), data)

        XCTAssertThrowsError(try BackupCrypto.decrypt(enc, to: out, password: "wrong")) {
            XCTAssertEqual($0 as? BackupCrypto.Failure, .wrongPassword)
        }
    }

    func testTamperingAndTruncationAreDetected() throws {
        let (plain, _) = try randomFile()
        let enc = dir.appendingPathComponent("enc.bin")
        try BackupCrypto.encrypt(plain, to: enc, password: "pw-12345678", iterations: 100_000)
        let good = try Data(contentsOf: enc)
        let out = dir.appendingPathComponent("out.bin")

        func expectFailure(_ bad: Data, _ label: String) throws {
            let f = dir.appendingPathComponent("bad.bin")
            try bad.write(to: f)
            XCTAssertThrowsError(try BackupCrypto.decrypt(f, to: out, password: "pw-12345678"), label)
        }
        var flipped = good; flipped[good.count / 2] ^= 0x01
        try expectFailure(flipped, "flipped byte in the middle")
        try expectFailure(good.prefix(good.count - 100), "truncated")
        try expectFailure(good + Data([0]), "trailing data")
        var header = good; header[6] ^= 0xFF          // iteration count
        try expectFailure(header, "edited header")
    }

    func testEncryptedBackupRestoresWithPassword() throws {
        let store = dir.appendingPathComponent("MacMoney.store")
        let folder = dir.appendingPathComponent("Backups")
        do {
            let config = ModelConfiguration("T", schema: Schema(Schema1.models), url: store, cloudKitDatabase: .none)
            let container = try ModelContainer(for: Schema(Schema1.models), configurations: config)
            let ctx = ModelContext(container)
            let a = Account(name: "Checking"); ctx.insert(a)
            ctx.insert(Entry(account: a, date: Day.today, amountCents: -4200))
            try ctx.save()
        }
        let backup = try Backup.make(.manual, store: store, folder: folder, encryption: .password("s3cret-passphrase"))
        XCTAssertTrue(BackupCrypto.isEncrypted(backup))
        XCTAssertTrue(Backup.list(in: folder).first?.encrypted ?? false)
        // The raw file must not contain SQLite's header or any readable table names.
        let raw = try Data(contentsOf: backup)
        XCTAssertNil(raw.range(of: Data("SQLite format 3".utf8)))
        XCTAssertNil(raw.range(of: Data("ZENTRY".utf8)))

        XCTAssertThrowsError(try Backup.scheduleRestore(from: backup, password: "nope", stagingFolder: dir))
        XCTAssertNil(UserDefaults.standard.string(forKey: Backup.Key.pendingRestore))

        try Backup.scheduleRestore(from: backup, password: "s3cret-passphrase", stagingFolder: dir)
        let staged = try XCTUnwrap(UserDefaults.standard.string(forKey: Backup.Key.pendingRestore))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged))
        let msg = Backup.applyPendingRestore(store: store, folder: folder, encryption: .none)
        XCTAssertTrue(msg?.hasPrefix("Restored \(backup.lastPathComponent)") ?? false, msg ?? "nil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged), "Decrypted staging copy must be removed")
        XCTAssertEqual(try Backup.scalar(store, "SELECT count(*) FROM ZENTRY"), 1)
    }

    func testEncryptExistingConvertsPlainBackups() throws {
        let store = dir.appendingPathComponent("MacMoney.store")
        let folder = dir.appendingPathComponent("Backups")
        do {
            let config = ModelConfiguration("T", schema: Schema(Schema1.models), url: store, cloudKitDatabase: .none)
            let container = try ModelContainer(for: Schema(Schema1.models), configurations: config)
            let ctx = ModelContext(container)
            ctx.insert(Account(name: "A"))
            try ctx.save()
        }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try Backup.make(.manual, store: store, folder: folder, now: base, encryption: .none)
        try Backup.make(.automatic, store: store, folder: folder, now: base.addingTimeInterval(60), encryption: .none)
        XCTAssertEqual(try Backup.encryptExisting(in: folder, password: "pw-abcdefgh"), 2)
        XCTAssertTrue(Backup.list(in: folder).allSatisfy(\.encrypted))
        XCTAssertEqual(try Backup.encryptExisting(in: folder, password: "pw-abcdefgh"), 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "No temp files left behind")
    }
}
