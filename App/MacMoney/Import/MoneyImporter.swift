import Foundation
import SwiftData

/// Applies a Money export to the store. Safe to run repeatedly (dual-entry period):
///  - records are matched by `moneyId` and updated in place, so nothing duplicates;
///  - Money-imported records that no longer exist in the .mny are removed;
///  - anything created in the app (`moneyId == nil`) and app-owned fields such as a category's
///    Schedule C line are left untouched.
@MainActor
struct MoneyImporter {
    let context: ModelContext

    struct Summary {
        var accounts = 0, categories = 0, payees = 0, entries = 0, bills = 0
        var inserted = 0, updated = 0, removed = 0
        var accountBalances: [(name: String, balanceCents: Int, reconciledCents: Int, moneyReconciledCents: Int?)] = []

        var text: String {
            "\(accounts) accounts, \(categories) categories, \(payees) payees, \(entries) transactions, \(bills) bills — \(inserted) new, \(updated) updated, \(removed) removed"
        }
    }

    func run(_ file: MoneyExportFile) throws -> Summary {
        guard file.format == "macmoney-export", file.version == 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unsupported export format \(file.format) v\(file.version)"])
        }
        var s = Summary()

        // ---- Accounts
        var accounts = existing(Account.self) { $0.moneyId }
        for a in file.accounts {
            let acct = upsert(&accounts, a.moneyId, &s) { Account(name: a.name ?? "") }
            acct.name = a.name ?? "Account \(a.moneyId)"
            acct.kind = AccountKind(rawValue: a.kind) ?? .other
            acct.isClosed = acct.closedOverride ?? a.closed
            acct.openingBalanceCents = Cents.parse(a.openingBalance) ?? 0
            acct.openDate = Day.parse(a.openDate)
            acct.lastReconciledDate = Day.parse(a.lastReconciledDate)
            acct.lastReconciledBalanceCents = Cents.parse(a.lastReconciledBalance)
            acct.accountNumber = a.accountNumber
            acct.notes = a.comment
            acct.isBusiness = a.isBusiness
        }
        s.removed += removeMissing(accounts, keep: Set(file.accounts.map(\.moneyId)))
        s.accounts = file.accounts.count

        // ---- Categories (two passes so parents resolve regardless of order)
        var categories = existing(Category.self) { $0.moneyId }
        for c in file.categories {
            let cat = upsert(&categories, c.moneyId, &s) { Category(name: c.name ?? "") }
            cat.name = c.name ?? ""
            cat.kind = CategoryKind(rawValue: c.kind) ?? .expense
            cat.isTaxRelated = c.isTaxRelated
            cat.isBusiness = c.isBusiness
            cat.isHidden = c.hidden
            cat.notes = c.comment
        }
        for c in file.categories { categories[c.moneyId]?.parent = c.parentId.flatMap { categories[$0] } }
        s.removed += removeMissing(categories, keep: Set(file.categories.map(\.moneyId)))
        s.categories = file.categories.count

        // ---- Payees
        var payees = existing(Payee.self) { $0.moneyId }
        for p in file.payees {
            let payee = upsert(&payees, p.moneyId, &s) { Payee(name: p.name ?? "") }
            payee.name = p.name ?? ""
            payee.isHidden = payee.hiddenOverride ?? p.hidden
            payee.accountNumber = p.accountNumber
            payee.website = p.website
            payee.notes = p.comment
        }
        s.removed += removeMissing(payees, keep: Set(file.payees.map(\.moneyId)))
        s.payees = file.payees.count

        // ---- Transactions
        var entries = existing(Entry.self) { $0.moneyId }
        for t in file.transactions {
            let date = Day.parse(t.date) ?? Day.today
            let e = upsert(&entries, t.moneyId, &s) { Entry(account: nil, date: date, amountCents: 0) }
            e.account = t.accountId.flatMap { accounts[$0] }
            e.date = date
            e.amountCents = Cents.parse(t.amount) ?? 0
            e.number = t.number
            e.payee = t.payeeId.flatMap { payees[$0] }
            e.category = t.categoryId.flatMap { categories[$0] }
            e.memo = t.memo
            // Balancing in MacMoney is kept: a reconciled entry stays reconciled until Money catches up.
            let moneyStatus = ClearedStatus(rawValue: t.status) ?? .uncleared
            if e.status != .reconciled || moneyStatus == .reconciled {
                e.status = moneyStatus
                e.dateCleared = Day.parse(t.dateCleared)
            }
            e.isVoid = t.isVoid
            // Money keeps flags after reconciling; here a flag lives only until the entry is reconciled.
            e.isFlagged = (t.flagged ?? false) && e.status != .reconciled
            e.flagNote = t.flagNote
            e.flagDate = Day.parse(t.flagDate)
            e.transferAccount = t.transferAccountId.flatMap { accounts[$0] }
            e.billSeriesMoneyId = t.billSeriesId
        }
        for t in file.transactions {
            guard let e = entries[t.moneyId] else { continue }
            e.splitParent = t.splitParentId.flatMap { entries[$0] }
            e.splitOrder = t.splitOrder ?? 0
            e.transferPeerUUID = t.transferPeerId.flatMap { entries[$0]?.uuid }
        }
        s.removed += removeMissing(entries, keep: Set(file.transactions.map(\.moneyId)))
        s.entries = file.transactions.count

        // ---- Bills
        var bills = existing(Bill.self) { $0.moneySeriesId }
        for b in file.bills {
            let bill = upsert(&bills, b.seriesId, &s) { Bill(amountCents: 0, nextDue: Day.today) }
            bill.account = b.accountId.flatMap { accounts[$0] }
            bill.payee = b.payeeId.flatMap { payees[$0] }
            bill.category = b.categoryId.flatMap { categories[$0] }
            bill.transferAccount = b.transferAccountId.flatMap { accounts[$0] }
            bill.amountCents = Cents.parse(b.amount) ?? 0
            bill.memo = b.memo
            bill.number = b.number
            bill.unit = RecurrenceUnit(rawValue: b.frequency.unit) ?? .month
            bill.every = max(1, b.frequency.every)
            bill.startDate = Day.parse(b.startDate)
            bill.nextDue = Day.parse(b.nextDue) ?? Day.today
            bill.anchorDay = Day.calendar.component(.day, from: bill.nextDue)
            bill.endDate = Day.parse(b.endDate)
            bill.remainingOccurrences = b.maxOccurrences.map { max(0, $0 - b.nextOccurrence) }
            bill.isActive = !b.finished
        }
        s.removed += removeMissing(bills, keep: Set(file.bills.map(\.seriesId)))
        s.bills = file.bills.count

        context.insert(ImportRecord(fileName: file.source.fileName, sha256: file.source.sha256, summary: s.text))
        try context.save()

        s.accountBalances = accounts.values.sorted { $0.name < $1.name }.map { a in
            let live = (a.entries ?? []).filter { !$0.isVoid && !$0.isSplitLine }
            return (a.name,
                    a.openingBalanceCents + live.reduce(0) { $0 + $1.amountCents },
                    a.openingBalanceCents + live.filter { $0.status == .reconciled }.reduce(0) { $0 + $1.amountCents },
                    a.lastReconciledBalanceCents)
        }
        return s
    }

    // MARK: - helpers

    private func existing<T: PersistentModel>(_ type: T.Type, key: (T) -> Int?) -> [Int: T] {
        let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
        var map: [Int: T] = [:]
        for item in all { if let k = key(item) { map[k] = item } }
        return map
    }

    private func upsert<T: PersistentModel>(_ map: inout [Int: T], _ id: Int, _ s: inout Summary, make: () -> T) -> T {
        if let found = map[id] { s.updated += 1; return found }
        let new = make()
        setMoneyId(new, id)
        context.insert(new)
        map[id] = new
        s.inserted += 1
        return new
    }

    private func setMoneyId(_ model: some PersistentModel, _ id: Int) {
        switch model {
        case let m as Account: m.moneyId = id
        case let m as Category: m.moneyId = id
        case let m as Payee: m.moneyId = id
        case let m as Entry: m.moneyId = id
        case let m as Bill: m.moneySeriesId = id
        default: break
        }
    }

    private func removeMissing<T: PersistentModel>(_ map: [Int: T], keep: Set<Int>) -> Int {
        var n = 0
        for (id, item) in map where !keep.contains(id) {
            context.delete(item)
            n += 1
        }
        return n
    }
}

extension MoneyImporter {
    /// Full pipeline: .mny -> JSON (bundled Java converter) -> store.
    func importMny(at url: URL) async throws -> Summary {
        let json = try await Task.detached { try MoneyExportRunner.export(mnyURL: url) }.value
        defer { try? FileManager.default.removeItem(at: json.deletingLastPathComponent()) }
        let data = try Data(contentsOf: json)
        let file = try JSONDecoder().decode(MoneyExportFile.self, from: data)
        return try run(file)
    }
}
