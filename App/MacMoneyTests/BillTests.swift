import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class BillTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testMonthlyKeepsAnchorDay() {
        let jan31 = Day.date(year: 2027, month: 1, day: 31)
        let feb = Recurrence.next(after: jan31, unit: .month, every: 1, anchorDay: 31)!
        XCTAssertEqual(feb, Day.date(year: 2027, month: 2, day: 28))
        let mar = Recurrence.next(after: feb, unit: .month, every: 1, anchorDay: 31)!
        XCTAssertEqual(mar, Day.date(year: 2027, month: 3, day: 31))
        XCTAssertEqual(Recurrence.next(after: jan31, unit: .month, every: 3, anchorDay: 31), Day.date(year: 2027, month: 4, day: 30))
        XCTAssertEqual(Recurrence.next(after: jan31, unit: .week, every: 4, anchorDay: 0), Day.date(year: 2027, month: 2, day: 28))
    }

    func testOccurrencesRespectEnd() {
        let bill = Bill(amountCents: -5000, nextDue: Day.date(year: 2027, month: 1, day: 15))
        bill.anchorDay = 15
        bill.remainingOccurrences = 3
        XCTAssertEqual(bill.occurrences(through: Day.date(year: 2028, month: 1, day: 1)).count, 3)
        bill.remainingOccurrences = nil
        bill.endDate = Day.date(year: 2027, month: 4, day: 1)
        XCTAssertEqual(bill.occurrences(through: Day.date(year: 2028, month: 1, day: 1)).count, 3)
    }

    func testEnterBillPostsEntryAndAdvances() throws {
        let ctx = try makeContext()
        let checking = Account(name: "Checking")
        ctx.insert(checking)
        let bill = Bill(amountCents: -12345, nextDue: Day.date(year: 2027, month: 1, day: 26))
        bill.anchorDay = 26
        bill.account = checking
        bill.payee = Payee(name: "Mortgage Co")
        ctx.insert(bill)

        let store = BillStore(context: ctx)
        let e = try store.enter(bill, as: store.draft(for: bill))
        XCTAssertEqual(e.amountCents, -12345)
        XCTAssertEqual(e.date, Day.date(year: 2027, month: 1, day: 26))
        XCTAssertEqual(e.account, checking)
        XCTAssertEqual(e.billUUID, bill.uuid)
        XCTAssertEqual(bill.nextDue, Day.date(year: 2027, month: 2, day: 26))
    }

    func testFlagClearsOnReconcileAndBillsCanFlag() throws {
        let ctx = try makeContext()
        let checking = Account(name: "Checking")
        ctx.insert(checking)
        let bill = Bill(amountCents: -5000, nextDue: Day.date(year: 2027, month: 1, day: 5))
        bill.account = checking
        bill.flagOnEnter = true
        ctx.insert(bill)
        let store = BillStore(context: ctx)
        let e = try store.enter(bill, as: store.draft(for: bill))
        XCTAssertTrue(e.isFlagged, "Auto-pay bills enter flagged")
        e.status = .cleared
        XCTAssertTrue(e.isFlagged)
        e.status = .reconciled
        XCTAssertFalse(e.isFlagged, "Reconciling clears the flag")
    }

    func testForecastDoesNotDoubleCountEnteredBills() throws {
        let ctx = try makeContext()
        let today = Day.date(year: 2027, month: 1, day: 1)
        let checking = Account(name: "Checking")
        checking.openingBalanceCents = 100_000
        ctx.insert(checking)
        let bill = Bill(amountCents: -10_000, nextDue: Day.date(year: 2027, month: 1, day: 10))
        bill.anchorDay = 10
        bill.account = checking
        ctx.insert(bill)

        // Enter January ahead of time; the bill moves to February.
        let store = BillStore(context: ctx)
        try store.enter(bill, as: store.draft(for: bill))

        let f = Forecast(accounts: [checking], bills: [bill], today: today, horizon: Day.date(year: 2027, month: 3, day: 31))
        XCTAssertEqual(f.startBalanceCents, 100_000)
        XCTAssertEqual(f.events.count, 3, "Jan (entered) + Feb + Mar (projected)")
        XCTAssertEqual(f.events.filter { $0.source == .register }.count, 1)
        XCTAssertEqual(f.endBalanceCents, 70_000)
    }

    func testTransferBillAffectsBothAccounts() throws {
        let ctx = try makeContext()
        let today = Day.date(year: 2027, month: 1, day: 1)
        let checking = Account(name: "Checking"); checking.openingBalanceCents = 50_000
        let card = Account(name: "Card", kind: .creditCard)
        ctx.insert(checking); ctx.insert(card)
        let bill = Bill(amountCents: -20_000, nextDue: Day.date(year: 2027, month: 1, day: 10))
        bill.account = checking
        bill.transferAccount = card
        ctx.insert(bill)
        let horizon = Day.date(year: 2027, month: 1, day: 31)
        XCTAssertEqual(Forecast(accounts: [checking], bills: [bill], today: today, horizon: horizon).endBalanceCents, 30_000)
        XCTAssertEqual(Forecast(accounts: [card], bills: [bill], today: today, horizon: horizon).endBalanceCents, 20_000)
        XCTAssertEqual(Forecast(accounts: [checking, card], bills: [bill], today: today, horizon: horizon).endBalanceCents, 50_000)
    }
}
