import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class ImportTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: config)
        return ModelContext(container)
    }

    /// Path to a real export JSON, passed as TEST_RUNNER_MACMONEY_EXPORT. Personal data is never checked in.
    private func loadExport() throws -> MoneyExportFile {
        guard let path = ProcessInfo.processInfo.environment["MACMONEY_EXPORT"] else {
            throw XCTSkip("Set TEST_RUNNER_MACMONEY_EXPORT to an export JSON to run import tests")
        }
        return try JSONDecoder().decode(MoneyExportFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func testImportMatchesMoneyReconciledBalances() throws {
        let file = try loadExport()
        let ctx = try makeContext()
        let summary = try MoneyImporter(context: ctx).run(file)

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Entry>()), file.transactions.count)
        // Every account where Money recorded a last-reconciled balance must match ours to the cent,
        // except accounts with known Money-side discrepancies, named (comma-separated) in
        // TEST_RUNNER_MACMONEY_KNOWN_MISMATCHES.
        let knownMismatches = Set((ProcessInfo.processInfo.environment["MACMONEY_KNOWN_MISMATCHES"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        for a in summary.accountBalances where !knownMismatches.contains(a.name) {
            if let money = a.moneyReconciledCents {
                XCTAssertEqual(a.reconciledCents, money, "Reconciled balance mismatch for \(a.name)")
            }
        }
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Bill>()).filter(\.isActive).count, file.bills.filter { !$0.finished }.count)
        let flagged = try ctx.fetch(FetchDescriptor<Entry>()).filter(\.isFlagged)
        XCTAssertFalse(flagged.contains { $0.status == .reconciled }, "Reconciled entries never show a flag")
        XCTAssertEqual(flagged.count, file.transactions.filter { $0.flagged == true && $0.status != "reconciled" }.count)
    }

    func testReimportIsIdempotentAndKeepsAppData() throws {
        let file = try loadExport()
        let ctx = try makeContext()
        _ = try MoneyImporter(context: ctx).run(file)

        let account = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Account>()).first { !$0.isClosed })
        var draft = EntryDraft()
        draft.payeeName = "Entered in MacMoney"
        draft.amount = "12.34"
        let mine = try EntryStore(context: ctx).save(draft, into: account, editing: nil)
        let category = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MacMoney.Category>()).first { !$0.isRoot })
        category.scheduleCLine = "Line 18 Office expense"
        try ctx.save()

        let second = try MoneyImporter(context: ctx).run(file)
        XCTAssertEqual(second.inserted, 0, "Re-import must not duplicate anything")
        XCTAssertEqual(second.removed, 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Entry>()), file.transactions.count + 1)
        XCTAssertNotNil(try ctx.fetch(FetchDescriptor<Entry>()).first { $0.uuid == mine.uuid }, "App-entered entry must survive")
        XCTAssertEqual(category.scheduleCLine, "Line 18 Office expense", "App-owned fields must survive")
    }
}

final class CentsTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(Cents.parse("1,234.56"), 123456)
        XCTAssertEqual(Cents.parse("-0.07"), -7)
        XCTAssertEqual(Cents.parse("$12"), 1200)
        XCTAssertEqual(Cents.parse("(5.5)"), -550)
        XCTAssertEqual(Cents.parse("3500.00"), 350000)
        XCTAssertNil(Cents.parse(""))
        XCTAssertNil(Cents.parse("abc"))
    }

    func testDayRoundTrip() {
        let d = Day.parse("2026-10-29")!
        XCTAssertEqual(Day.string(d), Day.formatter.string(from: Day.date(year: 2026, month: 10, day: 29)))
        XCTAssertEqual(Day.normalize(Day.toLocal(d)), d)
    }
}

@MainActor
final class LedgerIndexTests: XCTestCase {
    func testIndexMatchesModelAndIsFast() throws {
        guard let path = ProcessInfo.processInfo.environment["MACMONEY_EXPORT"] else { throw XCTSkip("needs export") }
        let file = try JSONDecoder().decode(MoneyExportFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        _ = try MoneyImporter(context: ctx).run(file)

        let index = LedgerIndex()
        var start = Date()
        index.rebuild(ctx)
        let full = Date().timeIntervalSince(start)

        // Includes Money's few orphaned entries (no account) so they remain findable.
        XCTAssertEqual(index.rows.count, file.transactions.filter { $0.splitParentId == nil }.count)
        for a in try ctx.fetch(FetchDescriptor<Account>()) {
            XCTAssertEqual(index.totals[a.persistentModelID]?.current, a.currentBalanceCents, a.name)
        }

        // Toggle one entry's cleared status, as clicking the C column does.
        let entry = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Entry>()).first { $0.status == .uncleared && $0.splitParent == nil && $0.account != nil })
        entry.status = .cleared
        try ctx.save()
        start = Date()
        XCTAssertTrue(index.applyIncremental(ctx, changed: [entry.persistentModelID], deleted: []))
        let incremental = Date().timeIntervalSince(start)
        let aid = try XCTUnwrap(entry.account?.persistentModelID)
        let clearedAfterIncremental = index.totals[aid]?.cleared
        index.rebuild(ctx)
        XCTAssertEqual(clearedAfterIncremental, index.totals[aid]?.cleared)
        XCTAssertEqual(index.rows.first { $0.id == entry.persistentModelID }?.status, .cleared)

        print("LedgerIndex: full rebuild \(Int(full * 1000)) ms, incremental \(Int(incremental * 1000)) ms, rows \(index.rows.count)")
        XCTAssertLessThan(incremental, 0.25, "A single edit should update the index quickly")
    }
}
