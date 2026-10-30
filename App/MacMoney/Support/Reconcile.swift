import Foundation
import SwiftData

/// What the bank statement says, as entered in the Balance Account dialog.
struct Statement: Codable, Equatable {
    var date: Date = Day.today
    var endingCents: Int = 0
    var serviceChargeCents = 0
    var serviceChargeCategory = ""
    var interestCents = 0
    var interestCategory = ""
}

/// Balancing an account against a statement, as in Money's Balance Account:
/// mark entries cleared until the cleared balance equals the statement's ending balance, then
/// finish, which turns every cleared entry into reconciled (and so clears its flag).
@MainActor
struct Reconciler {
    let context: ModelContext
    let account: Account

    private var entries: [Entry] { (account.entries ?? []).filter { !$0.isSplitLine } }

    /// Opening balance plus everything already reconciled: where this statement starts.
    var startingCents: Int {
        account.openingBalanceCents + entries.filter { $0.status == .reconciled }.reduce(0) { $0 + $1.balanceEffectCents }
    }

    /// Opening balance plus cleared and reconciled entries.
    var clearedCents: Int {
        account.openingBalanceCents + entries.filter { $0.status != .uncleared }.reduce(0) { $0 + $1.balanceEffectCents }
    }

    func difference(_ s: Statement) -> Int { s.endingCents - clearedCents }

    /// Enters the statement's service charge and interest as cleared entries on the statement date.
    /// Returns the statement with those amounts zeroed, so resuming later doesn't enter them twice.
    func enterChargesAndInterest(_ s: Statement) throws -> Statement {
        let store = EntryStore(context: context)
        func add(_ cents: Int, payee: String, category: String) {
            let e = Entry(account: account, date: s.date, amountCents: cents)
            context.insert(e)
            e.payee = store.payee(named: payee)
            e.category = store.category(named: category)
            e.status = .cleared
            e.dateCleared = Day.today
        }
        if s.serviceChargeCents != 0 { add(-abs(s.serviceChargeCents), payee: "Service Charge", category: s.serviceChargeCategory) }
        if s.interestCents != 0 { add(abs(s.interestCents), payee: "Interest Earned", category: s.interestCategory) }
        try context.save()
        var rest = s
        rest.serviceChargeCents = 0
        rest.interestCents = 0
        return rest
    }

    /// Reconciles every cleared entry. With `adjust`, a remaining difference is first entered as a
    /// "Balance Adjustment" so the account agrees with the statement.
    @discardableResult
    func finish(_ s: Statement, adjust: Bool = false) throws -> Int {
        let diff = difference(s)
        if diff != 0 {
            guard adjust else { throw CocoaError(.validationNumberTooLarge, userInfo: [NSLocalizedDescriptionKey: "The account doesn't balance yet."]) }
            let e = Entry(account: account, date: s.date, amountCents: diff)
            context.insert(e)
            e.payee = EntryStore(context: context).payee(named: "Balance Adjustment")
            e.memo = "Added when balancing to the \(Day.string(s.date)) statement"
            e.status = .cleared
            e.dateCleared = Day.today
        }
        var count = 0
        for e in entries where e.status == .cleared {
            e.status = .reconciled
            for line in e.splits ?? [] { line.status = .reconciled }
            count += 1
        }
        account.statementDate = s.date
        account.statementBalanceCents = s.endingCents
        try context.save()
        Self.clearPending(for: account)
        return count
    }

    // MARK: Postponed sessions

    private static func key(_ account: Account) -> String { "balance.pending.\(account.uuid.uuidString)" }

    static func pending(for account: Account) -> Statement? {
        UserDefaults.standard.data(forKey: key(account)).flatMap { try? JSONDecoder().decode(Statement.self, from: $0) }
    }

    static func postpone(_ s: Statement, for account: Account) {
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: key(account))
    }

    static func clearPending(for account: Account) {
        UserDefaults.standard.removeObject(forKey: key(account))
    }
}
