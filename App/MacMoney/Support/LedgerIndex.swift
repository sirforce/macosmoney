import Foundation
import SwiftData
import Observation

/// Display-ready snapshot of every register entry. Views read plain value rows (no SwiftData
/// faulting, no re-sorting on redraw), which keeps scrolling, selecting and typing responsive with
/// decades of history.
///
/// Built in full at launch and after imports; ordinary edits update only the rows that changed.
struct EntryRow: Identifiable {
    let id: PersistentIdentifier
    let uuid: UUID
    let accountID: PersistentIdentifier?
    let accountName: String
    let payeeID: PersistentIdentifier?
    let date: Date
    let number: String
    let payee: String
    let category: String
    let memo: String
    let amount: Int
    /// Amount that counts toward the balance (0 when void).
    let effect: Int
    let status: ClearedStatus
    let isVoid: Bool
    let isFlagged: Bool
    let flagNote: String
    let flagDate: Date?
    let isReadOnly: Bool
    /// Business this entry counts toward ("" = personal), and whether it comes from the account.
    let business: String
    let businessFromAccount: Bool
    let isPersonal: Bool
    /// Effective Schedule C line code ("" = none) and whether it was set on the entry itself.
    let taxLine: String
    let taxLineExplicit: Bool
    let businessPercent: Int
    let vehicle: String
    let isTransfer: Bool
    /// The bank's own description, for entries imported from a bank download.
    let bankDescription: String
    /// Lowercased payee/memo/number/category/amount for substring search.
    let haystack: String
    /// Stable tie-break for entries on the same day (Money's entry order, then creation).
    let order: Int

    func matches(_ query: String) -> Bool { query.isEmpty || haystack.contains(query) }
}

typealias AccountInfo = (name: String, readOnly: Bool, business: String)

struct AccountTotals {
    var current = 0
    var today = 0
    var cleared = 0
}

@MainActor
@Observable
final class LedgerIndex {
    private(set) var version = 0
    /// All register entries (split lines excluded), sorted by date then entry order.
    private(set) var rows: [EntryRow] = []
    private(set) var rowsByAccount: [PersistentIdentifier: [EntryRow]] = [:]
    private(set) var totals: [PersistentIdentifier: AccountTotals] = [:]
    private(set) var payeeNames: [String] = []
    private(set) var categoryNames: [String] = []
    private(set) var payeeUsage: [PersistentIdentifier: (count: Int, last: Date)] = [:]

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var categoryName: [PersistentIdentifier: String] = [:]
    @ObservationIgnored private var payeeName: [PersistentIdentifier: String] = [:]
    @ObservationIgnored private var hiddenPayees = Set<PersistentIdentifier>()
    @ObservationIgnored private var nextOrder = Int.max / 2

    func start(_ context: ModelContext) {
        guard observer == nil else { return }
        rebuild(context)
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let inserted = info[ModelContext.NotificationKey.insertedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
            let updated = info[ModelContext.NotificationKey.updatedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
            let deleted = info[ModelContext.NotificationKey.deletedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.applyIncremental(context, changed: inserted + updated, deleted: deleted) { self.rebuild(context) }
            }
        }
    }

    // MARK: - Full rebuild

    func rebuild(_ context: ModelContext) {
        loadNames(context)
        // One query for everything — far faster than walking each account's relationship array.
        let entries = (try? context.fetch(FetchDescriptor<Entry>(sortBy: [SortDescriptor(\.date)]))) ?? []
        var splitCount: [PersistentIdentifier: Int] = [:]
        for e in entries { if let p = e.splitParent { splitCount[p.persistentModelID, default: 0] += 1 } }
        var accountInfo: [PersistentIdentifier: AccountInfo] = [:]
        var all: [EntryRow] = []
        all.reserveCapacity(entries.count)
        for e in entries where e.splitParent == nil {
            all.append(makeRow(e, splitCount: splitCount[e.persistentModelID], accountInfo: &accountInfo))
        }
        finish(all, context: context)
    }

    // MARK: - Incremental

    /// Updates just the changed entries. Returns false when a full rebuild is needed instead.
    func applyIncremental(_ context: ModelContext, changed: [PersistentIdentifier], deleted: [PersistentIdentifier]) -> Bool {
        let all = changed + deleted
        guard !all.isEmpty else { return true }
        guard all.count < 500 else { return false }
        var entryIDs = Set<PersistentIdentifier>()
        var accountsChanged = false
        for id in all {
            switch id.entityName {
            case "Entry": entryIDs.insert(id)
            case "Payee":
                guard !deleted.contains(id), let p = context.model(for: id) as? Payee else { return false }
                payeeName[id] = p.name
                if p.isHidden { hiddenPayees.insert(id) } else { hiddenPayees.remove(id) }
            case "Account": accountsChanged = true
            case "Bill", "ImportRecord", "MileageEntry", "ReportPreset", "Scenario", "ScenarioItem", "BankRecord", "BankImportBatch", "Purchase", "PurchaseItem", "PurchaseFile", "AppSettings": continue
            default: return false
            }
        }
        // Account renames / closing change every row's display; rebuild in that case.
        if accountsChanged { return false }

        var kept = rows.filter { !entryIDs.contains($0.id) }
        var accountInfo: [PersistentIdentifier: AccountInfo] = [:]
        for id in changed where id.entityName == "Entry" {
            guard let e = context.model(for: id) as? Entry else { continue }
            // Split structure changes need parent rows recomputed; fall back to a full rebuild.
            if e.splitParent != nil { return false }
            kept.append(makeRow(e, splitCount: nil, accountInfo: &accountInfo))
        }
        payeeNames = payeeName.filter { !hiddenPayees.contains($0.key) }.values
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        finish(kept, context: context)
        return true
    }

    // MARK: - Helpers

    private func loadNames(_ context: ModelContext) {
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let payees = (try? context.fetch(FetchDescriptor<Payee>())) ?? []
        categoryName = [:]
        for c in categories where !c.isRoot { categoryName[c.persistentModelID] = c.fullName }
        categoryNames = categoryName.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        payeeName = [:]
        hiddenPayees = []
        for p in payees {
            payeeName[p.persistentModelID] = p.name
            if p.isHidden { hiddenPayees.insert(p.persistentModelID) }
        }
        payeeNames = payees.filter { !$0.isHidden }.map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func makeRow(_ e: Entry, splitCount: Int?, accountInfo: inout [PersistentIdentifier: AccountInfo]) -> EntryRow {
        let account = e.account
        let aid = account?.persistentModelID
        var info: AccountInfo = ("", false, "")
        if let aid, let account {
            if let cached = accountInfo[aid] { info = cached } else {
                info = (account.name, account.isReadOnly, account.business?.name ?? "")
                accountInfo[aid] = info
            }
        }
        let vehicle = e.vehicle
        let ownBusiness = e.business?.name ?? vehicle?.business?.name
        let business = e.isPersonal ? "" : (ownBusiness ?? info.business)
        let line = e.taxLine ?? e.category?.scheduleCLine.flatMap(TaxLine.init)
        let category: String
        if let other = e.transferAccount {
            category = "Transfer \(e.amountCents < 0 ? "to" : "from") \(other.name)"
        } else if let n = splitCount ?? (e.splits?.isEmpty == false ? e.splits?.count : nil) {
            category = "Split (\(n))"
        } else {
            category = e.category.flatMap { categoryName[$0.persistentModelID] } ?? ""
        }
        let pid = e.payee?.persistentModelID
        let payee = pid.flatMap { payeeName[$0] } ?? ""
        let memo = e.memo ?? ""
        let number = e.number ?? ""
        let order: Int
        if let m = e.moneyId { order = m } else { nextOrder += 1; order = nextOrder }
        return EntryRow(
            id: e.persistentModelID, uuid: e.uuid, accountID: aid, accountName: info.name, payeeID: pid, date: e.date,
            number: number, payee: payee, category: category, memo: memo,
            amount: e.amountCents, effect: e.isVoid ? 0 : e.amountCents, status: e.status, isVoid: e.isVoid,
            isFlagged: e.isFlagged, flagNote: e.flagNote ?? "", flagDate: e.flagDate, isReadOnly: info.readOnly,
            business: business, businessFromAccount: ownBusiness == nil && !business.isEmpty, isPersonal: e.isPersonal,
            taxLine: vehicle != nil ? "9" : (line?.rawValue ?? ""), taxLineExplicit: e.taxLine != nil,
            businessPercent: e.businessPercent, vehicle: vehicle?.name ?? "", isTransfer: e.transferAccount != nil,
            bankDescription: e.bankDescription ?? "",
            haystack: "\(payee)\u{1}\(memo)\u{1}\(number)\u{1}\(category)\u{1}\(Cents.plain(e.amountCents))\u{1}\(e.flagNote ?? "")\u{1}\(e.bankDescription ?? "")".lowercased(),
            order: order)
    }

    /// Sorts, groups by account, and recomputes totals and payee usage from plain rows.
    private func finish(_ unsorted: [EntryRow], context: ModelContext) {
        let today = Day.today
        // Sort small keys, then permute — avoids moving large structs around during the sort.
        let keys = unsorted.indices
            .map { (unsorted[$0].date.timeIntervalSinceReferenceDate, unsorted[$0].order, $0) }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        let sorted = keys.map { unsorted[$0.2] }

        var byAccount: [PersistentIdentifier: [EntryRow]] = [:]
        var usage: [PersistentIdentifier: (count: Int, last: Date)] = [:]
        for r in sorted {
            if let a = r.accountID { byAccount[a, default: []].append(r) }
            if let p = r.payeeID, !r.isVoid {
                let u = usage[p] ?? (0, .distantPast)
                usage[p] = (u.count + 1, max(u.last, r.date))
            }
        }
        var totals: [PersistentIdentifier: AccountTotals] = [:]
        for a in (try? context.fetch(FetchDescriptor<Account>())) ?? [] {
            var t = AccountTotals(current: a.openingBalanceCents, today: a.openingBalanceCents, cleared: a.openingBalanceCents)
            for r in byAccount[a.persistentModelID] ?? [] {
                t.current += r.effect
                if r.date <= today { t.today += r.effect }
                if r.status != .uncleared { t.cleared += r.effect }
            }
            totals[a.persistentModelID] = t
        }
        rows = sorted
        rowsByAccount = byAccount
        self.totals = totals
        payeeUsage = usage
        version += 1
    }
}
