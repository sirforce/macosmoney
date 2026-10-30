import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class ScenarioTests: XCTestCase {
    private var ctx: ModelContext!
    private var checking: Account!
    private var rent: Bill!
    private let today = Day.date(year: 2027, month: 1, day: 10)
    private let horizon = Day.date(year: 2027, month: 6, day: 30)

    override func setUpWithError() throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = ModelContext(container)
        checking = Account(name: "Checking")
        checking.openingBalanceCents = 5_000_00
        ctx.insert(checking)
        rent = Bill(amountCents: -1_000_00, nextDue: Day.date(year: 2027, month: 2, day: 1))   // Feb–Jun: 5 payments
        rent.account = checking
        rent.anchorDay = 1
        ctx.insert(rent)
        try ctx.save()
    }

    private func forecast(_ adjustments: [ScenarioAdjustment] = []) -> Forecast {
        Forecast(accounts: [checking], bills: [rent], today: today, horizon: horizon, adjustments: adjustments)
    }

    func testBaselineUnchangedWithoutAdjustments() {
        XCTAssertEqual(forecast().endBalanceCents, 0)
        XCTAssertFalse(forecast().events.contains { $0.source == .scenario })
    }

    func testOneTimeAndRecurringAmounts() {
        let laptop = ScenarioAdjustment(kind: .oneTime, name: "Laptop", amountCents: -2_000_00, accountUUID: checking.uuid,
                                        startDate: Day.date(year: 2027, month: 3, day: 15))
        var car = ScenarioAdjustment(kind: .recurring, name: "Car", amountCents: -400_00, accountUUID: checking.uuid,
                                     startDate: Day.date(year: 2027, month: 4, day: 5))
        car.endDate = Day.date(year: 2027, month: 5, day: 31)                      // Apr 5, May 5
        let past = ScenarioAdjustment(kind: .oneTime, amountCents: 999_00, accountUUID: checking.uuid,
                                      startDate: Day.date(year: 2026, month: 12, day: 1))   // before today: ignored
        let f = forecast([laptop, car, past])
        XCTAssertEqual(f.events.filter { $0.source == .scenario }.count, 3)
        XCTAssertEqual(f.endBalanceCents, -2_800_00)
        XCTAssertEqual(forecast([laptop]).lowPoint?.balanceCents, -2_000_00)
    }

    func testChangeAndStopBill() {
        let raise = ScenarioAdjustment(kind: .changeBill, amountCents: -1_200_00, billUUID: rent.uuid,
                                       startDate: Day.date(year: 2027, month: 4, day: 1))   // Apr, May, Jun at 1,200
        let f = forecast([raise])
        XCTAssertEqual(f.endBalanceCents, -600_00)
        XCTAssertEqual(f.events.filter { $0.source == .scenario }.count, 3)

        let stop = ScenarioAdjustment(kind: .stopBill, billUUID: rent.uuid, startDate: Day.date(year: 2027, month: 5, day: 1))
        XCTAssertEqual(forecast([stop]).endBalanceCents, 2_000_00)                 // only Feb–Apr paid
        XCTAssertEqual(forecast([raise, stop]).endBalanceCents, 1_800_00)           // Feb, Mar 1,000 + Apr 1,200
    }

    func testAmountsForAccountsOutsideTheForecastAreLeftOut() {
        let other = ScenarioAdjustment(kind: .oneTime, amountCents: -50_00, accountUUID: UUID(), startDate: horizon)
        XCTAssertEqual(forecast([other]).endBalanceCents, 0)
    }

    func testScenarioItemsPersistAndCascade() throws {
        let s = Scenario(name: "Move")
        ctx.insert(s)
        let item = ScenarioItem(kind: .stopBill, startDate: horizon)
        item.billUUID = rent.uuid
        item.scenario = s
        ctx.insert(item)
        try ctx.save()
        XCTAssertEqual(s.sortedItems.first?.adjustment.billUUID, rent.uuid)
        ctx.delete(s)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<ScenarioItem>()), 0)
    }
}
