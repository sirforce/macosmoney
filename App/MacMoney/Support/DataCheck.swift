import Foundation
import SwiftData

/// "Check Data File": SQLite's own integrity check plus bookkeeping consistency checks
/// (the equivalent of Money's repair tool, minus the guesswork — it reports, it doesn't rewrite).
struct DataCheck {
    struct Issue: Identifiable {
        enum Severity: Int, Comparable {
            case info, warning, problem
            static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }
        let id = UUID()
        let severity: Severity
        let title: String
        let detail: String
        var examples: [String] = []
    }

    var issues: [Issue] = []
    var counts: [(String, Int)] = []
    var healthy: Bool { !issues.contains { $0.severity == .problem } }

    @MainActor
    static func run(context: ModelContext, store: URL = Backup.storeURL) -> DataCheck {
        var r = DataCheck()

        // 1. File-level integrity.
        do {
            let result = try Backup.integrityCheck(store)
            if result != ["ok"] {
                r.issues.append(Issue(severity: .problem, title: "Database file is damaged",
                                      detail: "SQLite reported problems. Restore from a recent backup.",
                                      examples: Array(result.prefix(5))))
            }
        } catch {
            r.issues.append(Issue(severity: .problem, title: "Couldn't read the database file", detail: error.localizedDescription))
        }

        // 2. Bookkeeping consistency.
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let entries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let payees = (try? context.fetch(FetchDescriptor<Payee>())) ?? []
        r.counts = [("Accounts", accounts.count), ("Transactions", entries.count), ("Payees", payees.count),
                    ("Categories", categories.count), ("Bills & deposits", bills.count)]

        func describe(_ e: Entry) -> String {
            "\(Day.string(e.date))  \(e.account?.name ?? "no account")  \(e.payee?.name ?? "")  \(Cents.string(e.amountCents))"
        }

        let orphans = entries.filter { $0.account == nil && $0.splitParent == nil }
        if !orphans.isEmpty {
            r.issues.append(Issue(severity: .warning, title: "\(orphans.count) transaction(s) not in any account",
                                  detail: "They don't affect any balance. Usually left over from Money; a re-import normally cleans them up.",
                                  examples: orphans.prefix(5).map(describe)))
        }

        let byUUID = Dictionary(entries.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let brokenTransfers = entries.filter { e in
            guard e.transferAccount != nil, let peer = e.transferPeerUUID else { return false }
            return byUUID[peer] == nil
        }
        if !brokenTransfers.isEmpty {
            r.issues.append(Issue(severity: .warning, title: "\(brokenTransfers.count) transfer(s) missing the other side",
                                  detail: "The matching entry in the other account no longer exists, so the two balances may disagree.",
                                  examples: brokenTransfers.prefix(5).map(describe)))
        }
        let mismatched = entries.filter { e in
            guard let peerID = e.transferPeerUUID, let peer = byUUID[peerID], !e.isVoid, !peer.isVoid else { return false }
            return peer.amountCents != -e.amountCents
        }
        if !mismatched.isEmpty {
            r.issues.append(Issue(severity: .warning, title: "\(mismatched.count / 2 + mismatched.count % 2) transfer pair(s) with different amounts",
                                  detail: "Each side of a transfer should be the same amount with opposite signs.",
                                  examples: mismatched.prefix(5).map(describe)))
        }

        let badSplits = entries.filter { e in
            guard let kids = e.splits, !kids.isEmpty, !e.isVoid else { return false }
            return kids.reduce(0) { $0 + $1.amountCents } != e.amountCents
        }
        if !badSplits.isEmpty {
            r.issues.append(Issue(severity: .warning, title: "\(badSplits.count) split transaction(s) don't add up",
                                  detail: "The split lines don't total the transaction amount.",
                                  examples: badSplits.prefix(5).map(describe)))
        }

        let dupes = Dictionary(grouping: entries.compactMap { e in e.moneyId.map { ($0, e) } }, by: \.0).filter { $0.value.count > 1 }
        if !dupes.isEmpty {
            r.issues.append(Issue(severity: .problem, title: "\(dupes.count) Money transaction(s) imported more than once",
                                  detail: "Balances will be overstated. Restore a backup from before the import, or re-import.",
                                  examples: dupes.values.prefix(5).compactMap { $0.first.map { describe($0.1) } }))
        }

        let homeless = bills.filter { $0.account == nil && $0.isActive }
        if !homeless.isEmpty {
            r.issues.append(Issue(severity: .warning, title: "\(homeless.count) active bill(s) with no account",
                                  detail: "They can't be entered or forecast until an account is chosen.",
                                  examples: homeless.prefix(5).map(\.displayName)))
        }

        let future = entries.filter { $0.date > Day.adding(.year, 5, to: Day.today) }
        if !future.isEmpty {
            r.issues.append(Issue(severity: .info, title: "\(future.count) transaction(s) dated more than 5 years ahead",
                                  detail: "Probably typos in the date.", examples: future.prefix(5).map(describe)))
        }
        r.issues.sort { $0.severity > $1.severity }
        return r
    }
}
