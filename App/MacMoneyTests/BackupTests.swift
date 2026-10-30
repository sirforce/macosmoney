import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class BackupTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacMoneyBackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removeObject(forKey: Backup.Key.pendingRestore)
        UserDefaults.standard.removeObject(forKey: Backup.Key.lastRestoreResult)
    }

    /// Opens a store at `url`, runs `body`, saves, and lets the container go before returning.
    private func withStore(_ url: URL, _ body: (ModelContext) throws -> Void) throws {
        let config = ModelConfiguration("Test", schema: Schema(Schema1.models), url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: config)
        let ctx = ModelContext(container)
        try body(ctx)
        try ctx.save()
    }

    private func entryCount(_ url: URL) throws -> Int {
        var n = 0
        try withStore(url) { n = try $0.fetchCount(FetchDescriptor<Entry>()) }
        return n
    }

    func testBackupAndRestoreRoundTrip() throws {
        let store = dir.appendingPathComponent("MacMoney.store")
        let folder = dir.appendingPathComponent("Backups")
        try withStore(store) { ctx in
            let a = Account(name: "Checking"); ctx.insert(a)
            for i in 0..<3 { ctx.insert(Entry(account: a, date: Day.today, amountCents: -100 * (i + 1))) }
        }

        let backup = try Backup.make(.manual, store: store, folder: folder)
        XCTAssertEqual(try Backup.integrityCheck(backup), ["ok"])
        XCTAssertEqual(try entryCount(backup), 3)

        // Change the live data after the backup…
        try withStore(store) { ctx in
            for e in try ctx.fetch(FetchDescriptor<Entry>()) { ctx.delete(e) }
        }
        XCTAssertEqual(try entryCount(store), 0)

        // …then restore the way the app does on relaunch.
        try Backup.scheduleRestore(from: backup)
        let msg = Backup.applyPendingRestore(store: store, folder: folder)
        XCTAssertTrue(msg?.hasPrefix("Restored") ?? false, msg ?? "nil")
        XCTAssertEqual(try entryCount(store), 3)

        // The pre-restore state was kept, so the restore can be undone.
        let safety = Backup.list(in: folder).first { $0.reason == .beforeRestore }
        XCTAssertNotNil(safety)
        XCTAssertEqual(try entryCount(safety!.url), 0)
        XCTAssertNil(UserDefaults.standard.string(forKey: Backup.Key.pendingRestore))
    }

    func testPruneKeepsNewestAutomaticAndAllManual() throws {
        let store = dir.appendingPathComponent("MacMoney.store")
        let folder = dir.appendingPathComponent("Backups")
        try withStore(store) { $0.insert(Account(name: "A")) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try Backup.make(.manual, store: store, folder: folder, keep: 3, now: base)
        for i in 1...6 {
            try Backup.make(i % 2 == 0 ? .automatic : .beforeImport, store: store, folder: folder, keep: 3,
                            now: base.addingTimeInterval(Double(i) * 3600))
        }
        let list = Backup.list(in: folder)
        XCTAssertEqual(list.filter { $0.reason == .manual }.count, 1)
        XCTAssertEqual(list.filter { $0.reason.isPruned }.count, 3)
        XCTAssertEqual(list.first?.date, base.addingTimeInterval(6 * 3600), "newest first")
    }

    func testRestoreRejectsNonBackupFiles() throws {
        let junk = dir.appendingPathComponent("junk.macmoneybackup")
        try Data("not a database".utf8).write(to: junk)
        XCTAssertThrowsError(try Backup.scheduleRestore(from: junk))
        XCTAssertNil(UserDefaults.standard.string(forKey: Backup.Key.pendingRestore))
    }

    func testDataCheckFindsBrokenTransfer() throws {
        let store = dir.appendingPathComponent("MacMoney.store")
        let config = ModelConfiguration("Test", schema: Schema(Schema1.models), url: store, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: config)
        let ctx = ModelContext(container)
        let a = Account(name: "Checking"), b = Account(name: "Savings")
        ctx.insert(a); ctx.insert(b)
        let e = Entry(account: a, date: Day.today, amountCents: -5000)
        e.transferAccount = b
        e.transferPeerUUID = UUID()      // peer doesn't exist
        ctx.insert(e)
        try ctx.save()
        let r = DataCheck.run(context: ctx, store: store)
        XCTAssertTrue(r.healthy)
        XCTAssertTrue(r.issues.contains { $0.title.contains("missing the other side") })
    }
}
