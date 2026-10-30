import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class ScheduleCTests: XCTestCase {
    func testScheduleCRollsUpAcrossAccounts() throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let biz = Business(name: "Consulting LLC")
        ctx.insert(biz)

        let bizChecking = Account(name: "Business Checking")
        bizChecking.business = biz
        let personal = Account(name: "Personal Checking")
        ctx.insert(bizChecking); ctx.insert(personal)

        func cat(_ name: String, _ line: TaxLine?, _ kind: MacMoney.CategoryKind = .expense) -> MacMoney.Category {
            let c = MacMoney.Category(name: name, kind: kind)
            c.scheduleCLine = line?.rawValue
            ctx.insert(c)
            return c
        }
        let consulting = cat("Consulting", .grossReceipts, .income)
        let office = cat("Office", .office)
        let utilities = cat("Phone", .utilities)
        let meals = cat("Meals", .meals)
        let misc = cat("Misc", nil)

        let d = Day.date(year: 2025, month: 6, day: 1)
        func entry(_ a: Account, _ cents: Int, _ c: MacMoney.Category?, configure: (Entry) -> Void = { _ in }) {
            let e = Entry(account: a, date: d, amountCents: cents)
            e.category = c
            configure(e)
            ctx.insert(e)
        }
        entry(bizChecking, 100_000, consulting)                                   // income via business account
        entry(personal, -10_000, office) { $0.business = biz }                   // commingled, tagged
        entry(personal, -5_000, office)                                           // personal, ignored
        entry(personal, -20_000, utilities) { $0.business = biz; $0.businessPercent = 50 }
        entry(bizChecking, -8_000, meals)                                         // 50% deductible
        entry(bizChecking, -3_000, office) { $0.isPersonal = true }               // personal in business account
        entry(bizChecking, -50_000, nil) { $0.transferAccount = personal }        // owner draw, not an expense
        entry(bizChecking, -1_500, misc)                                          // needs a line

        let car = Vehicle(name: "Truck")
        car.business = biz
        car.usesStandardRate = true
        ctx.insert(car)
        let trip = MileageEntry(date: d, tenthMiles: 10_000, kind: .business, purpose: "Clients") // 1,000 mi
        trip.vehicle = car
        ctx.insert(trip)
        entry(personal, -2_000, nil) { $0.vehicle = car; $0.vehicleExpense = .parkingTolls }
        entry(personal, -30_000, nil) { $0.vehicle = car; $0.vehicleExpense = .fuel }  // not used under standard rate
        try ctx.save()

        let r = ScheduleCReport(business: biz, range: Day.date(year: 2025, month: 1, day: 1)...Day.date(year: 2025, month: 12, day: 31), context: ctx)
        XCTAssertEqual(r.grossIncome, 100_000)
        XCTAssertEqual(r.cents(.office), 10_000)
        XCTAssertEqual(r.cents(.utilities), 10_000)
        XCTAssertEqual(r.cents(.meals), 4_000)
        // 1,000 business miles × 70¢ (2025) + $20 parking
        XCTAssertEqual(r.vehicles.first?.standardMileageCents, 70_000)
        XCTAssertEqual(r.cents(.carTruck), 72_000)
        XCTAssertEqual(r.needsLine.count, 1)
        XCTAssertEqual(r.totalExpenses, 10_000 + 10_000 + 4_000 + 72_000)
        XCTAssertEqual(r.netProfit, 100_000 - 96_000)

        // Switching the vehicle to actual expenses: 100% business use (only business miles logged).
        car.usesStandardRate = false
        let actual = ScheduleCReport(business: biz, range: Day.date(year: 2025, month: 1, day: 1)...Day.date(year: 2025, month: 12, day: 31), context: ctx)
        XCTAssertEqual(actual.cents(.carTruck), 32_000)
    }
}
