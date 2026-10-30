import Foundation
import SwiftData

/// Brings bank downloads into an account without ever adding a row twice.
///
/// Every row gets a fingerprint (`BankRow.fingerprint`) recorded in `BankRecord`. On import:
///  1. a row whose fingerprint is already recorded for the account is skipped, whatever has
///     happened to its transaction since (edited, re-categorized, tagged, or deleted);
///  2. otherwise, an existing entry in the account with the same amount within a week that no
///     bank row has claimed yet (a payment entered in checking, a transaction typed in by hand)
///     is matched instead of adding a duplicate;
///  3. anything left becomes a new cleared entry.
/// Imported entries are MacMoney data, so re-importing from Money leaves them alone.
@MainActor
struct BankImporter {
    let context: ModelContext

    static let matchWindowDays = 7

    struct FilePlan {
        let url: URL
        let statement: BankStatement
        var newRows: [(row: BankRow, fingerprint: String)] = []
        var matches: [(row: BankRow, fingerprint: String, entry: Entry)] = []
        var duplicates = 0
    }

    // MARK: Planning (dry run)

    /// What importing these files into `account` would do, file by file, in order. With no account
    /// (a new one will be created), every row is new apart from repeats across the files.
    func plan(_ files: [(url: URL, statement: BankStatement)], into account: Account?) -> [FilePlan] {
        var known = Set<String>()
        var candidates: [Int: [Entry]] = [:]
        if let account {
            let records = self.records(for: account)
            known = Set(records.map(\.fingerprint))
            let claimed = Set(records.compactMap(\.entryUUID))
            for e in account.entries ?? [] where !e.isSplitLine && !claimed.contains(e.uuid) {
                candidates[e.amountCents, default: []].append(e)
            }
        }
        return files.map { file in
            var plan = FilePlan(url: file.url, statement: file.statement)
            for (row, fp) in file.statement.fingerprinted {
                if known.contains(fp) { plan.duplicates += 1; continue }
                known.insert(fp)
                if let i = bestMatch(for: row, in: candidates[row.amountCents] ?? []) {
                    plan.matches.append((row, fp, candidates[row.amountCents]!.remove(at: i)))
                } else {
                    plan.newRows.append((row, fp))
                }
            }
            return plan
        }
    }

    private func bestMatch(for row: BankRow, in entries: [Entry]) -> Int? {
        let window = TimeInterval(Self.matchWindowDays * 86_400)
        return entries.indices
            .filter { abs(entries[$0].date.timeIntervalSince(row.date)) <= window }
            .min { abs(entries[$0].date.timeIntervalSince(row.date)) < abs(entries[$1].date.timeIntervalSince(row.date)) }
    }

    func records(for account: Account) -> [BankRecord] {
        let id = account.uuid
        return (try? context.fetch(FetchDescriptor<BankRecord>(predicate: #Predicate { $0.accountUUID == id }))) ?? []
    }

    // MARK: Applying

    /// Bank balance on a date, for making the account agree with the bank.
    struct BalanceCheck {
        var date: Date
        var cents: Int
    }

    /// Imports the planned files into `account` (reopening it if it was closed) and records an
    /// undoable batch. With `balance`, adds a single correction so the account matches the bank on
    /// that date; for an account that had nothing in it yet, the opening balance is set instead.
    @discardableResult
    func apply(_ plans: [FilePlan], to account: Account, balance: BalanceCheck? = nil) throws -> BankImportBatch {
        let batch = BankImportBatch()
        batch.accountUUID = account.uuid
        batch.accountName = account.name
        batch.fileNames = plans.map(\.url.lastPathComponent).joined(separator: "\n")
        context.insert(batch)
        let wasEmpty = (account.entries ?? []).isEmpty

        if account.isClosed {
            account.isClosed = false
            if account.moneyId != nil { account.closedOverride = false }
            batch.reopenedAccount = true
        }

        var payees: [String: Payee] = [:]
        for p in (try? context.fetch(FetchDescriptor<Payee>())) ?? [] { payees[p.name.lowercased()] = payees[p.name.lowercased()] ?? p }
        func payee(_ name: String) -> Payee {
            if let p = payees[name.lowercased()] { return p }
            let p = Payee(name: name)
            context.insert(p)
            payees[name.lowercased()] = p
            return p
        }
        func record(_ row: BankRow, _ fp: String, entry: Entry, matched: Bool) {
            let r = BankRecord(fingerprint: fp)
            r.accountUUID = account.uuid
            r.entryUUID = entry.uuid
            r.matched = matched
            r.batchUUID = batch.uuid
            r.date = row.date
            r.amountCents = row.amountCents
            r.rawDescription = row.description
            r.bankCategory = row.category ?? ""
            context.insert(r)
        }

        var dates: [Date] = []
        for plan in plans {
            for (row, fp) in plan.newRows {
                let e = Entry(account: account, date: row.date, amountCents: row.amountCents)
                context.insert(e)
                e.payee = payee(PayeeCleaner.clean(row.description))
                e.memo = row.memo
                e.bankDescription = row.description
                e.status = .cleared
                e.dateCleared = row.date
                record(row, fp, entry: e, matched: false)
                dates.append(row.date)
            }
            for (row, fp, entry) in plan.matches {
                if entry.status == .uncleared { entry.status = .cleared; entry.dateCleared = row.date }
                if entry.bankDescription == nil { entry.bankDescription = row.description }
                record(row, fp, entry: entry, matched: true)
                dates.append(row.date)
            }
            batch.added += plan.newRows.count
            batch.matched += plan.matches.count
            batch.skipped += plan.duplicates
            remember(plan.statement.hints, on: account)
        }
        batch.firstDate = dates.min()
        batch.lastDate = dates.max()

        if let balance {
            let current = account.openingBalanceCents
                + (account.entries ?? []).filter { $0.date <= balance.date }.reduce(0) { $0 + $1.balanceEffectCents }
            let diff = balance.cents - current
            if diff != 0 {
                if wasEmpty {
                    account.openingBalanceCents += diff
                    batch.openingChangeCents = diff
                } else {
                    let e = Entry(account: account, date: balance.date, amountCents: diff)
                    context.insert(e)
                    e.payee = payee("Balance Correction")
                    e.memo = "Brings the balance in line with the bank on \(Day.string(balance.date))"
                    e.status = .reconciled
                    e.dateCleared = balance.date
                    batch.correctionEntryUUID = e.uuid
                }
            }
        }
        try context.save()
        return batch
    }

    /// Adds a file's hints to the account so the next download goes there automatically.
    func remember(_ hints: [String], on account: Account) {
        var lines = account.importHints.split(separator: "\n").map(String.init)
        for h in hints where !lines.contains(h) { lines.append(h) }
        account.importHints = lines.joined(separator: "\n")
    }

    // MARK: Undo

    /// Removes what an import added: its new entries, its correction, its opening-balance change
    /// and its record of rows (so the files can be imported again). Matched entries stay.
    func undo(_ batch: BankImportBatch) throws {
        let id = batch.uuid
        let records = (try? context.fetch(FetchDescriptor<BankRecord>(predicate: #Predicate { $0.batchUUID == id }))) ?? []
        var remove = records.filter { !$0.matched }.compactMap(\.entryUUID)
        if let c = batch.correctionEntryUUID { remove.append(c) }
        if !remove.isEmpty {
            for e in (try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { remove.contains($0.uuid) }))) ?? [] {
                context.delete(e)
            }
        }
        records.forEach(context.delete)
        if let accountID = batch.accountUUID,
           let account = try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.uuid == accountID })).first {
            account.openingBalanceCents -= batch.openingChangeCents
            if batch.reopenedAccount {
                account.isClosed = true
                if account.moneyId != nil { account.closedOverride = nil }
            }
        }
        context.delete(batch)
        try context.save()
    }

    // MARK: Choosing the account

    /// The account a download most likely belongs to: one that has taken files with the same
    /// clues before, then one whose name matches the folder (open accounts first).
    static func suggestedAccount(for statement: BankStatement, in accounts: [Account]) -> Account? {
        let specific = statement.hints.filter { !$0.hasPrefix("folder:") }
        let folder = statement.hints.first { $0.hasPrefix("folder:") }
        func has(_ a: Account, _ h: String) -> Bool { a.importHints.split(separator: "\n").contains { $0 == h } }
        if let a = accounts.first(where: { a in specific.contains { has(a, $0) } }) { return a }
        if let folder, let a = accounts.first(where: { has($0, folder) }) { return a }
        guard let name = folder?.dropFirst("folder:".count).lowercased(), !name.isEmpty else { return nil }
        let open = accounts.filter { !$0.isClosed }, closed = accounts.filter(\.isClosed)
        return open.first { $0.name.lowercased() == name }
            ?? open.first { name.contains($0.name.lowercased()) || $0.name.lowercased().contains(name) }
            ?? closed.first { $0.name.lowercased() == name }
    }
}
