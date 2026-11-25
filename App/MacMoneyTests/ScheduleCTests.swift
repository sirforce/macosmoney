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

    func testAssetDepreciationGoesOnLine13OncePerTaxYear() throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let biz = Business(name: "Studio"), other = Business(name: "Other")
        ctx.insert(biz); ctx.insert(other)
        let camera = Asset(name: "Camera")
        camera.businessUUID = biz.uuid
        camera.costCents = 3_000_00
        camera.priorDepreciationCents = 200_00
        camera.yearAmounts = [2024: 600_00, 2025: 960_00]
        ctx.insert(camera)
        let theirs = Asset(name: "Someone else's")
        theirs.businessUUID = other.uuid
        theirs.yearAmounts = [2025: 111_00]
        ctx.insert(theirs)
        try ctx.save()

        func report(_ from: Date, _ to: Date) -> ScheduleCReport { ScheduleCReport(business: biz, range: from...to, context: ctx) }
        let y2025 = report(Day.date(year: 2025, month: 1, day: 1), Day.date(year: 2025, month: 12, day: 31))
        XCTAssertEqual(y2025.cents(.depreciation), 960_00)
        XCTAssertEqual(y2025.totalExpenses, 960_00)
        XCTAssertEqual(y2025.netProfit, -960_00)
        XCTAssertEqual(y2025.assets.map(\.name), ["Camera"])
        XCTAssertTrue(y2025.csv().contains("Depreciation (line 13)"))
        // Part of a year: not yet. Two whole years: both, once each.
        XCTAssertEqual(report(Day.date(year: 2025, month: 1, day: 1), Day.date(year: 2025, month: 6, day: 30)).cents(.depreciation), 0)
        XCTAssertEqual(report(Day.date(year: 2024, month: 1, day: 1), Day.date(year: 2025, month: 12, day: 31)).cents(.depreciation), 1_560_00)
        XCTAssertEqual(report(Day.date(year: 2026, month: 1, day: 1), Day.date(year: 2026, month: 12, day: 31)).cents(.depreciation), 0)

        XCTAssertEqual(camera.depreciatedCents(), 1_760_00)
        XCTAssertEqual(camera.depreciatedCents(through: 2024), 800_00)
        XCTAssertEqual(camera.remainingCents(), 1_240_00)
    }
}
