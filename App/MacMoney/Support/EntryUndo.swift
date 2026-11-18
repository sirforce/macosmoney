import Foundation
import SwiftData

/// Everything stored on a register entry (and its split lines), so a change can be put back exactly.
struct EntrySnapshot: Equatable {
    var uuid: UUID
    var moneyId: Int?
    var account: PersistentIdentifier?
    var date: Date
    var amountCents: Int
    var number: String?
    var payee: PersistentIdentifier?
    var category: PersistentIdentifier?
    var memo: String?
    var statusRaw: String
    var dateCleared: Date?
    var isVoid: Bool
    var isFlagged: Bool
    var flagNote: String?
    var flagDate: Date?
    var splitOrder: Int
    var transferAccount: PersistentIdentifier?
    var transferPeerUUID: UUID?
    var billSeriesMoneyId: Int?
    var business: PersistentIdentifier?
    var isPersonal: Bool
    var taxLineRaw: String?
    var businessPercent: Int
    var vehicle: PersistentIdentifier?
    var vehicleExpenseRaw: String?
    var billUUID: UUID?
    var bankDescription: String?
    var splits: [EntrySnapshot]

    init(_ e: Entry) {
        uuid = e.uuid
        moneyId = e.moneyId
        account = e.account?.persistentModelID
        date = e.date
        amountCents = e.amountCents
        number = e.number
        payee = e.payee?.persistentModelID
        category = e.category?.persistentModelID
        memo = e.memo
        statusRaw = e.statusRaw
        dateCleared = e.dateCleared
        isVoid = e.isVoid
        isFlagged = e.isFlagged
        flagNote = e.flagNote
        flagDate = e.flagDate
        splitOrder = e.splitOrder
        transferAccount = e.transferAccount?.persistentModelID
        transferPeerUUID = e.transferPeerUUID
        billSeriesMoneyId = e.billSeriesMoneyId
        business = e.business?.persistentModelID
        isPersonal = e.isPersonal
        taxLineRaw = e.taxLineRaw
        businessPercent = e.businessPercent
        vehicle = e.vehicle?.persistentModelID
        vehicleExpenseRaw = e.vehicleExpenseRaw
        billUUID = e.billUUID
        bankDescription = e.bankDescription
        splits = e.sortedSplits.map(EntrySnapshot.init)
    }

    func write(to e: Entry, context: ModelContext) {
        func model<T: PersistentModel>(_ id: PersistentIdentifier?) -> T? { id.flatMap { context.model(for: $0) as? T } }
        e.moneyId = moneyId
        e.account = model(account)
        e.date = date
        e.amountCents = amountCents
        e.number = number
        e.payee = model(payee)
        e.category = model(category)
        e.memo = memo
        e.statusRaw = statusRaw
        e.dateCleared = dateCleared
        e.isVoid = isVoid
        e.isFlagged = isFlagged
        e.flagNote = flagNote
        e.flagDate = flagDate
        e.splitOrder = splitOrder
        e.transferAccount = model(transferAccount)
        e.transferPeerUUID = transferPeerUUID
        e.billSeriesMoneyId = billSeriesMoneyId
        e.business = model(business)
        e.isPersonal = isPersonal
        e.taxLineRaw = taxLineRaw
        e.businessPercent = businessPercent
        e.vehicle = model(vehicle)
        e.vehicleExpenseRaw = vehicleExpenseRaw
        e.billUUID = billUUID
        e.bankDescription = bankDescription

        let wanted = Set(splits.map(\.uuid))
        for s in e.splits ?? [] where !wanted.contains(s.uuid) { context.delete(s) }
        for snap in splits {
            let line = (e.splits ?? []).first { $0.uuid == snap.uuid } ?? {
                let line = Entry(account: nil, date: snap.date, amountCents: snap.amountCents)
                line.uuid = snap.uuid
                context.insert(line)
                line.splitParent = e
                return line
            }()
            snap.write(to: line, context: context)
        }
    }
}

/// Undo and redo (⌘Z / ⇧⌘Z) for register changes. Each change records how the entries it touched
/// looked before and after, including a transfer's matching entry, and either side can be put back.
@MainActor
enum EntryUndo {
    /// Posted after an undo or redo changes entries, so open forms can reload.
    static let didApply = Notification.Name("EntryUndo.didApply")

    /// How a set of entries looked at one moment; a uuid with no snapshot means it didn't exist.
    struct State: Equatable {
        var uuids: Set<UUID> = []
        var snapshots: [UUID: EntrySnapshot] = [:]
    }

    /// Runs `change` on the entries in `touching` and registers its undo. `result` lists the entries
    /// that exist afterwards (for example a newly created one); their transfer peers are included.
    @discardableResult
    static func record<T>(_ actionName: String, context: ModelContext, undoManager: UndoManager?,
                          touching: [Entry], change: () throws -> T, result: (T) -> [Entry]) rethrows -> T {
        guard let undoManager else { return try change() }
        let store = EntryStore(context: context)
        var before = State()
        for e in touching.flatMap(store.withPeer) {
            before.uuids.insert(e.uuid)
            before.snapshots[e.uuid] = EntrySnapshot(e)
        }
        let value = try change()
        var after = State()
        for e in result(value).flatMap(store.withPeer) where !e.isDeleted {
            after.uuids.insert(e.uuid)
            after.snapshots[e.uuid] = EntrySnapshot(e)
        }
        before.uuids.formUnion(after.uuids)
        after.uuids = before.uuids
        guard before != after else { return value }
        register(actionName, restoring: before, other: after, context: context, undoManager: undoManager)
        return value
    }

    /// A single-entry change (status, flag, business…) with undo.
    static func change(_ actionName: String, _ e: Entry, context: ModelContext, undoManager: UndoManager?,
                       _ body: (Entry) -> Void) {
        record(actionName, context: context, undoManager: undoManager, touching: [e], change: {
            body(e)
            try? context.save()
        }, result: { [e] })
    }

    private static func register(_ actionName: String, restoring state: State, other: State,
                                 context: ModelContext, undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: context) { context in
            MainActor.assumeIsolated {
                apply(state, context: context)
                register(actionName, restoring: other, other: state, context: context, undoManager: undoManager)
                NotificationCenter.default.post(name: didApply, object: nil)
            }
        }
        undoManager.setActionName(actionName)
    }

    static func apply(_ state: State, context: ModelContext) {
        for uuid in state.uuids {
            let existing = try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.uuid == uuid })).first
            if let snap = state.snapshots[uuid] {
                let e = existing ?? {
                    let e = Entry(account: nil, date: snap.date, amountCents: snap.amountCents)
                    e.uuid = uuid
                    context.insert(e)
                    return e
                }()
                snap.write(to: e, context: context)
            } else if let existing {
                context.delete(existing)
            }
        }
        try? context.save()
    }
}
