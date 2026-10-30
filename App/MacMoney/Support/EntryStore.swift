import Foundation
import SwiftData

/// Editable copy of a register entry, as shown in the transaction form.
struct EntryDraft {
    enum Kind: String, CaseIterable, Identifiable {
        case withdrawal = "Withdrawal", deposit = "Deposit", transfer = "Transfer"
        var id: String { rawValue }
    }

    var kind: Kind = .withdrawal
    var date: Date = Day.today
    var number = ""
    var payeeName = ""
    var categoryName = ""
    var memo = ""
    var amount = ""
    var status: ClearedStatus = .uncleared
    var isFlagged = false
    var flagNote = ""
    var flagDate: Date?
    // Business / Schedule C
    var businessID: PersistentIdentifier?
    var isPersonal = false
    var taxLine: TaxLine?
    var businessPercent = 100
    var vehicleID: PersistentIdentifier?
    var vehicleExpense: VehicleExpense?
    var transferAccountID: PersistentIdentifier?
    /// Transfers default to money leaving this account; true when the money comes in.
    var transferIncoming = false

    init() {}

    init(_ e: Entry) {
        kind = e.isTransfer ? .transfer : (e.amountCents > 0 ? .deposit : .withdrawal)
        date = e.date
        number = e.number ?? ""
        payeeName = e.payee?.name ?? ""
        categoryName = e.isSplit ? "" : (e.category?.fullName ?? "")
        memo = e.memo ?? ""
        amount = Cents.plain(e.amountCents)
        status = e.status
        isFlagged = e.isFlagged
        flagNote = e.flagNote ?? ""
        flagDate = e.flagDate
        businessID = e.business?.persistentModelID
        isPersonal = e.isPersonal
        taxLine = e.taxLine
        businessPercent = e.businessPercent
        vehicleID = e.vehicle?.persistentModelID
        vehicleExpense = e.vehicleExpense
        transferAccountID = e.transferAccount?.persistentModelID
        transferIncoming = e.isTransfer && e.amountCents > 0
    }

    /// Signed cents for the account being edited (withdrawals and outgoing transfers are negative).
    var signedCents: Int? {
        guard let c = Cents.parse(amount) else { return nil }
        switch kind {
        case .deposit: return abs(c)
        case .withdrawal: return -abs(c)
        case .transfer: return transferIncoming ? abs(c) : -abs(c)
        }
    }
}

@MainActor
struct EntryStore {
    let context: ModelContext

    @discardableResult
    func save(_ draft: EntryDraft, into account: Account, editing existing: Entry?) throws -> Entry {
        guard let cents = draft.signedCents else {
            throw CocoaError(.validationNumberTooSmall, userInfo: [NSLocalizedDescriptionKey: "Enter an amount."])
        }
        let e = existing ?? Entry(account: account, date: draft.date, amountCents: cents)
        if existing == nil { context.insert(e) }
        e.date = draft.date
        e.amountCents = cents
        e.number = draft.number.nilIfBlank
        e.memo = draft.memo.nilIfBlank
        e.payee = payee(named: draft.payeeName)
        e.status = draft.status
        e.isFlagged = draft.isFlagged && draft.status != .reconciled
        e.flagNote = draft.flagNote.nilIfBlank
        e.flagDate = draft.flagDate
        e.business = draft.businessID.flatMap { context.model(for: $0) as? Business }
        e.isPersonal = draft.isPersonal
        e.taxLine = draft.taxLine
        e.businessPercent = draft.businessPercent
        e.vehicle = draft.vehicleID.flatMap { context.model(for: $0) as? Vehicle }
        e.vehicleExpense = e.vehicle == nil ? nil : (draft.vehicleExpense ?? .other)

        let target = draft.kind == .transfer ? draft.transferAccountID.flatMap { id in lookupAccount(id) } : nil
        if let target {
            e.category = nil
            e.transferAccount = target
            let peer = peerEntry(of: e) ?? {
                let p = Entry(account: target, date: e.date, amountCents: -cents)
                context.insert(p)
                return p
            }()
            peer.account = target
            peer.date = e.date
            peer.amountCents = -cents
            peer.payee = e.payee
            peer.memo = e.memo
            peer.transferAccount = account
            peer.transferPeerUUID = e.uuid
            e.transferPeerUUID = peer.uuid
        } else {
            if let peer = peerEntry(of: e) { context.delete(peer) }
            e.transferAccount = nil
            e.transferPeerUUID = nil
            if !e.isSplit { e.category = category(named: draft.categoryName) }
        }
        try context.save()
        return e
    }

    func delete(_ e: Entry) {
        if let peer = peerEntry(of: e) { context.delete(peer) }
        context.delete(e)
        try? context.save()
    }

    func peerEntry(of e: Entry) -> Entry? {
        guard let uuid = e.transferPeerUUID else { return nil }
        let d = FetchDescriptor<Entry>(predicate: #Predicate { $0.uuid == uuid })
        return try? context.fetch(d).first
    }

    private func lookupAccount(_ id: PersistentIdentifier) -> Account? {
        context.model(for: id) as? Account
    }

    /// Finds a payee by name (case-insensitive) or creates one.
    func payee(named raw: String) -> Payee? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Payee>())) ?? []
        if let p = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return p }
        let p = Payee(name: name)
        context.insert(p)
        return p
    }

    /// Finds a category by its "Parent : Child" name. Unknown names are not created implicitly.
    func category(named raw: String) -> Category? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        return all.first { !$0.isRoot && $0.fullName.caseInsensitiveCompare(name) == .orderedSame }
            ?? all.first { !$0.isRoot && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
