import Foundation
import SwiftData

/// Makes an account agree with the bank: "the balance at the end of this date was X".
///
/// When nothing in the account came from Money (for example an account filled from bank downloads
/// that only reach back two years), the opening balance is changed, so the history works backward
/// from the known balance. When there is Money history to keep intact, one reconciled
/// "Balance Correction" entry is added on that date instead.
@MainActor
enum BalanceAdjustment {
    enum Method { case openingBalance, correction }

    struct Result {
        var method: Method
        var differenceCents: Int
        var entry: Entry?
    }

    /// The account's balance at the end of `date`.
    static func balance(of account: Account, on date: Date) -> Int {
        account.openingBalanceCents
            + (account.entries ?? []).filter { !$0.isSplitLine && $0.date <= date }.reduce(0) { $0 + $1.balanceEffectCents }
    }

    /// How `set` would adjust this account.
    static func method(for account: Account) -> Method {
        (account.entries ?? []).contains { $0.moneyId != nil } ? .correction : .openingBalance
    }

    /// Adjusts the account so its balance at the end of `date` is `cents`. Doesn't save.
    @discardableResult
    static func set(_ account: Account, to cents: Int, on date: Date, method: Method? = nil, context: ModelContext) -> Result {
        let diff = cents - balance(of: account, on: date)
        let how = method ?? self.method(for: account)
        guard diff != 0 else { return Result(method: how, differenceCents: 0) }
        switch how {
        case .openingBalance:
            account.openingBalanceCents += diff
            return Result(method: how, differenceCents: diff)
        case .correction:
            let e = Entry(account: account, date: date, amountCents: diff)
            context.insert(e)
            e.payee = EntryStore(context: context).payee(named: "Balance Correction")
            e.memo = "Brings the balance in line with the bank on \(Day.string(date))"
            e.status = .reconciled
            e.dateCleared = date
            return Result(method: how, differenceCents: diff, entry: e)
        }
    }
}
