import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class PresetAndCurveTests: XCTestCase {
    func testPresetRoundTripsPayeesAndFilters() throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let a = Payee(name: "Acme Staffing"), b = Payee(name: "Venmo")
        ctx.insert(a); ctx.insert(b)
        let p = ReportPreset(name: "Clients", kind: "depositSources")
        p.payees = [a.uuid, b.uuid]
        p.periodRaw = ReportPeriod.lastYear.rawValue
        ctx.insert(p)
        try ctx.save()
        let fetched = try XCTUnwrap(ctx.fetch(FetchDescriptor<ReportPreset>()).first)
        XCTAssertEqual(fetched.payees, [a.uuid, b.uuid])
        XCTAssertEqual(ReportPeriod(rawValue: fetched.periodRaw), .lastYear)
        XCTAssertEqual(fetched.kind, "depositSources")
    }

    func testCurveSnapsToNearestDayAndReportsBalance() throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let today = Day.date(year: 2026, month: 10, day: 29)
        let acct = Account(name: "Checking")
        acct.openingBalanceCents = 100_000
        ctx.insert(acct)
        ctx.insert(Entry(account: acct, date: Day.date(year: 2026, month: 10, day: 1), amountCents: -20_000))  // actual
        ctx.insert(Entry(account: acct, date: Day.date(year: 2026, month: 11, day: 15), amountCents: -30_000)) // entered ahead
        try ctx.save()
        let f = Forecast(accounts: [acct], bills: [], today: today, horizon: Day.date(year: 2027, month: 1, day: 31),
                         historyFrom: Day.date(year: 2026, month: 9, day: 1))
        let curve = BalanceCurve(f)
        let range = Day.date(year: 2026, month: 9, day: 1)...Day.date(year: 2027, month: 1, day: 31)
        XCTAssertEqual(curve.nearestDay(to: Day.date(year: 2026, month: 11, day: 12), in: range), Day.date(year: 2026, month: 11, day: 15))
        XCTAssertEqual(curve.nearestDay(to: Day.date(year: 2026, month: 10, day: 3), in: range), Day.date(year: 2026, month: 10, day: 1))
        XCTAssertEqual(curve.balance(at: Day.date(year: 2026, month: 9, day: 15)), 100_000)
        XCTAssertEqual(curve.balance(at: Day.date(year: 2026, month: 10, day: 20)), 80_000)
        XCTAssertEqual(curve.balance(at: Day.date(year: 2026, month: 12, day: 1)), 50_000)
        XCTAssertEqual(f.pastEvents.first?.entryID != nil, true)
        XCTAssertEqual(f.events.first?.source, .register)
    }
}
