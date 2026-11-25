import XCTest
import SwiftData
@testable import MacMoney

/// The sample data behind `--demo` and the documentation screenshots.
@MainActor
final class DemoDataTests: XCTestCase {
    private let today = Day.date(year: 2026, month: 11, day: 25)
    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
    }

    private func build() throws -> (ctx: ModelContext, downloads: URL) {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)", isDirectory: true)
        folders.append(downloads)
        let name = "demo-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        DemoBuilder(context: ctx, today: today, downloads: downloads, defaults: defaults).build()
        return (ctx, downloads)
    }

    private func accounts(_ ctx: ModelContext) throws -> [String: Account] {
        Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<Account>()).map { ($0.name, $0) })
    }

    func testHouseholdHasEverythingTheScreensNeed() throws {
        let ctx = try build().ctx
        let all = try accounts(ctx)
        XCTAssertEqual(all.count, 9)
        XCTAssertEqual(Set(all.values.map(\.kind)), [.bank, .creditCard, .loan, .investment])
        XCTAssertEqual(all.values.filter(\.isClosed).map(\.name), ["Credit Union Checking"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Business>()), 2)
        XCTAssertGreaterThan(try ctx.fetchCount(FetchDescriptor<Entry>()), 4_000)
        XCTAssertGreaterThan(try ctx.fetchCount(FetchDescriptor<Bill>()), 20)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Scenario>()), 3)
        XCTAssertGreaterThan(try ctx.fetchCount(FetchDescriptor<Purchase>()), 100)
        XCTAssertGreaterThan(try ctx.fetchCount(FetchDescriptor<MileageEntry>()), 100)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<BankImportBatch>()), 2)

        let entries = try ctx.fetch(FetchDescriptor<Entry>())
        let first = Day.date(year: 2022, month: 1, day: 1)
        XCTAssertEqual(entries.map(\.date).min(), first)
        XCTAssertTrue(entries.contains { $0.date > today }, "something is entered ahead")
        XCTAssertTrue(entries.contains { $0.isFlagged })
        XCTAssertTrue(entries.contains { $0.isVoid })
        XCTAssertTrue(entries.contains { $0.isSplit })
        XCTAssertTrue(entries.contains { $0.businessPercent < 100 })
    }

    func testBalancesStayBelievable() throws {
        let all = try accounts(try build().ctx)
        for name in ["Joint Checking", "Emergency Savings", "Studio Checking"] {
            let a = try XCTUnwrap(all[name])
            var running = a.openingBalanceCents
            for e in (a.entries ?? []).sorted(by: { $0.date < $1.date }) {
                running += e.balanceEffectCents
                XCTAssertGreaterThan(running, 0, "\(name) went negative on \(Day.string(e.date))")
            }
        }
        // Cards are paid off every month; loans go down.
        for name in ["Rewards Visa", "Studio Visa"] {
            let balance = try XCTUnwrap(all[name]).balance(asOf: today)
            XCTAssertLessThanOrEqual(balance, 0, name)
            XCTAssertGreaterThan(balance, -9_000_00, name)
        }
        for name in ["Auto Loan", "Mortgage"] {
            let a = try XCTUnwrap(all[name])
            XCTAssertLessThan(a.balance(asOf: today), 0, name)
            XCTAssertGreaterThan(a.balance(asOf: today), a.openingBalanceCents, name)
        }
    }

    func testTransfersHaveBothSides() throws {
        let entries = try build().ctx.fetch(FetchDescriptor<Entry>())
        let byUUID = Dictionary(uniqueKeysWithValues: entries.map { ($0.uuid, $0) })
        let transfers = entries.filter(\.isTransfer)
        XCTAssertGreaterThan(transfers.count, 500)
        for e in transfers {
            let peer = try XCTUnwrap(e.transferPeerUUID.flatMap { byUUID[$0] })
            XCTAssertEqual(peer.amountCents, -e.amountCents)
            XCTAssertEqual(peer.date, e.date)
            XCTAssertTrue(peer.account === e.transferAccount)
        }
    }

    func testSampleDownloadsShowNewMatchedAndAlreadyImported() throws {
        let (ctx, downloads) = try build()
        let visa = try XCTUnwrap(try accounts(ctx)["Rewards Visa"])
        let files = try FileManager.default.contentsOfDirectory(at: downloads.appendingPathComponent("Rewards Visa"), includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 2)
        let importer = BankImporter(context: ctx)
        let plans = importer.plan(try files.map { ($0, try BankFormats.read($0)) }, into: visa)
        // The older file was imported with the sample data; the newer one overlaps it.
        XCTAssertTrue(plans[0].newRows.isEmpty)
        XCTAssertGreaterThan(plans[0].duplicates, 20)
        XCTAssertGreaterThan(plans[1].newRows.count, 5)
        XCTAssertGreaterThan(plans[1].duplicates, 0)
        XCTAssertGreaterThanOrEqual(plans[1].matches.count, 1)
        XCTAssertEqual(BankImporter.suggestedAccount(for: plans[1].statement, in: Array(try accounts(ctx).values))?.name, "Rewards Visa")
    }

    func testScheduleCHasIncomeExpensesAndMileage() throws {
        let ctx = try build().ctx
        let studio = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Business>()).first { $0.name == "Juniper Lane Studio" })
        let year = Day.date(year: 2025, month: 1, day: 1)...Day.date(year: 2025, month: 12, day: 31)
        let report = ScheduleCReport(business: studio, range: year, context: ctx)
        XCTAssertGreaterThan(report.grossReceipts, 30_000_00)
        XCTAssertGreaterThan(report.totalExpenses, 5_000_00)
        XCTAssertGreaterThan(report.netProfit, 0)
        XCTAssertGreaterThan(report.cents(.carTruck), 0)
        XCTAssertGreaterThan(report.cents(.meals), 0)
        XCTAssertGreaterThan(report.cents(.utilities), 0, "the business share of the home internet and phone")
        XCTAssertTrue(report.needsLine.isEmpty)
    }

    func testSameHouseholdEveryTime() throws {
        let a = try build().ctx, b = try build().ctx
        XCTAssertEqual(try a.fetchCount(FetchDescriptor<Entry>()), try b.fetchCount(FetchDescriptor<Entry>()))
        XCTAssertEqual(try accounts(a)["Joint Checking"]?.currentBalanceCents, try accounts(b)["Joint Checking"]?.currentBalanceCents)
    }
}
