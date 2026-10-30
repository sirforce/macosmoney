import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class ReconcileTests: XCTestCase {
    private var ctx: ModelContext!
    private var account: Account!

    override func setUpWithError() throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = ModelContext(container)
        account = Account(name: "Checking")
        account.openingBalanceCents = 100_00
        ctx.insert(account)
    }

    override func tearDown() { Reconciler.clearPending(for: account) }

    @discardableResult
    private func entry(_ cents: Int, _ status: ClearedStatus = .uncleared, day: Int = 5) -> Entry {
        let e = Entry(account: account, date: Day.date(year: 2027, month: 3, day: day), amountCents: cents)
        ctx.insert(e)
        e.status = status
        return e
    }

    func testBalancesAndFinishReconcilesClearedOnly() throws {
        entry(-20_00, .reconciled)                      // last statement
        let paid = entry(-30_00)
        let deposit = entry(50_00)
        let open = entry(-5_00)
        paid.isFlagged = true
        try ctx.save()
        let r = Reconciler(context: ctx, account: account)
        XCTAssertEqual(r.startingCents, 80_00)

        let s = Statement(date: Day.date(year: 2027, month: 3, day: 31), endingCents: 100_00)
        XCTAssertEqual(r.difference(s), 20_00)
        paid.status = .cleared
        deposit.status = .cleared
        XCTAssertEqual(r.difference(s), 0)

        XCTAssertEqual(try r.finish(s), 2)
        XCTAssertEqual(paid.status, .reconciled)
        XCTAssertFalse(paid.isFlagged, "reconciling clears the flag")
        XCTAssertEqual(open.status, .uncleared)
        XCTAssertEqual(account.statementDate, s.date)
        XCTAssertEqual(account.statementBalanceCents, 100_00)
        XCTAssertEqual(r.startingCents, 100_00)
    }

    func testFinishRefusesUnlessBalancedOrAdjusted() throws {
        entry(-30_00, .cleared)
        try ctx.save()
        let r = Reconciler(context: ctx, account: account)
        let s = Statement(date: Day.date(year: 2027, month: 3, day: 31), endingCents: 69_00)
        XCTAssertThrowsError(try r.finish(s))
        XCTAssertEqual(try r.finish(s, adjust: true), 2)
        XCTAssertEqual(r.startingCents, 69_00)
        XCTAssertTrue((account.entries ?? []).contains { $0.payee?.name == "Balance Adjustment" && $0.amountCents == -1_00 })
    }

    func testChargesAndInterestEnteredOnceAndCleared() throws {
        let r = Reconciler(context: ctx, account: account)
        var s = Statement(date: Day.date(year: 2027, month: 3, day: 31), endingCents: 97_50)
        s.serviceChargeCents = 3_00
        s.interestCents = 50
        let rest = try r.enterChargesAndInterest(s)
        XCTAssertEqual(rest.serviceChargeCents, 0)
        XCTAssertEqual(rest.interestCents, 0)
        XCTAssertEqual(r.difference(rest), 0)
        _ = try r.enterChargesAndInterest(rest)
        XCTAssertEqual(account.entries?.count, 2, "resuming doesn't enter them again")
    }

    func testPostponeRoundTrip() {
        let s = Statement(date: Day.date(year: 2027, month: 3, day: 31), endingCents: 12_34)
        XCTAssertNil(Reconciler.pending(for: account))
        Reconciler.postpone(s, for: account)
        XCTAssertEqual(Reconciler.pending(for: account), s)
        Reconciler.clearPending(for: account)
        XCTAssertNil(Reconciler.pending(for: account))
    }

    // MARK: Set Balance

    func testSetBalanceMovesOpeningWhenHistoryIsIncomplete() throws {
        // A savings account filled from a two-year download: more went out than came in.
        let savings = Account(name: "Savings")
        ctx.insert(savings)
        ctx.insert(Entry(account: savings, date: Day.date(year: 2025, month: 1, day: 1), amountCents: 5_000_00))
        ctx.insert(Entry(account: savings, date: Day.date(year: 2026, month: 1, day: 1), amountCents: -8_000_00))
        try ctx.save()
        XCTAssertEqual(BalanceAdjustment.method(for: savings), .openingBalance)
        let today = Day.date(year: 2026, month: 10, day: 30)
        let r = BalanceAdjustment.set(savings, to: 20_000_00, on: today, context: ctx)
        XCTAssertEqual(r.differenceCents, 23_000_00)
        XCTAssertNil(r.entry)
        XCTAssertEqual(savings.openingBalanceCents, 23_000_00, "history works backward from the known balance")
        XCTAssertEqual(BalanceAdjustment.balance(of: savings, on: today), 20_000_00)
    }

    func testSetBalanceAddsCorrectionWhenAccountHasMoneyHistory() throws {
        let card = Account(name: "Card", kind: .creditCard)
        ctx.insert(card)
        let payment = Entry(account: card, date: Day.date(year: 2024, month: 5, day: 1), amountCents: 640_000_00)
        payment.moneyId = 7
        ctx.insert(payment)
        ctx.insert(Entry(account: card, date: Day.date(year: 2026, month: 10, day: 1), amountCents: -100_00))
        try ctx.save()
        let day = Day.date(year: 2026, month: 10, day: 15)
        let r = BalanceAdjustment.set(card, to: -1_500_00, on: day, context: ctx)
        XCTAssertEqual(r.method, .correction)
        XCTAssertEqual(r.entry?.status, .reconciled)
        XCTAssertEqual(card.openingBalanceCents, 0)
        XCTAssertEqual(BalanceAdjustment.balance(of: card, on: day), -1_500_00)
        XCTAssertEqual(BalanceAdjustment.set(card, to: -1_500_00, on: day, context: ctx).differenceCents, 0, "already right: nothing added")
    }
}
