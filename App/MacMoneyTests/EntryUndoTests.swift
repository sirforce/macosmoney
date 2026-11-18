import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class EntryUndoTests: XCTestCase {
    private var context: ModelContext!
    private var undo: UndoManager!
    private var checking: Account!
    private var savings: Account!

    override func setUp() async throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        undo = UndoManager()
        undo.groupsByEvent = false
        checking = Account(name: "Checking")
        savings = Account(name: "Savings")
        context.insert(checking)
        context.insert(savings)
        try context.save()
    }

    private func entries() throws -> [Entry] {
        try context.fetch(FetchDescriptor<Entry>()).filter { !$0.isDeleted }
    }

    /// Saves a draft the way the transaction form does, as one undo step.
    @discardableResult
    private func save(_ draft: EntryDraft, editing: Entry? = nil) throws -> Entry {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return try EntryUndo.record(editing == nil ? "New Transaction" : "Edit Transaction", context: context, undoManager: undo,
                                    touching: editing.map { [$0] } ?? [],
                                    change: { try EntryStore(context: context).save(draft, into: checking, editing: editing) },
                                    result: { [$0] })
    }

    private func draft(_ payee: String, _ amount: String) -> EntryDraft {
        var d = EntryDraft()
        d.payeeName = payee
        d.amount = amount
        d.date = Day.date(year: 2026, month: 11, day: 1)
        return d
    }

    func testUndoAndRedoAnAmountChange() throws {
        let e = try save(draft("Grocer", "42.10"))
        var d = EntryDraft(e)
        d.amount = "24.10"
        try save(d, editing: e)
        XCTAssertEqual(e.amountCents, -2410)
        XCTAssertEqual(undo.undoActionName, "Edit Transaction")

        undo.undo()
        XCTAssertEqual(e.amountCents, -4210)
        undo.redo()
        XCTAssertEqual(e.amountCents, -2410)
    }

    func testSavingWithNoChangeAddsNoUndoStep() throws {
        let e = try save(draft("Grocer", "42.10"))
        // No undo group is open, so registering anything here would raise.
        try EntryUndo.record("Edit Transaction", context: context, undoManager: undo, touching: [e],
                             change: { try EntryStore(context: context).save(EntryDraft(e), into: checking, editing: e) },
                             result: { [$0] })
        XCTAssertEqual(undo.undoActionName, "New Transaction")
        undo.undo()
        XCTAssertTrue(try entries().isEmpty)
    }

    func testUndoNewTransferRemovesBothSidesAndRedoRestoresThem() throws {
        var d = draft("", "100")
        d.kind = .transfer
        d.transferAccountID = savings.persistentModelID
        let e = try save(d)
        let uuids = Set(try entries().map(\.uuid))
        XCTAssertEqual(uuids.count, 2)

        undo.undo()
        XCTAssertTrue(try entries().isEmpty)
        undo.redo()
        let back = try entries()
        XCTAssertEqual(Set(back.map(\.uuid)), uuids)
        let restored = try XCTUnwrap(back.first { $0.uuid == e.uuid })
        XCTAssertEqual(restored.transferAccount, savings)
        XCTAssertEqual(EntryStore(context: context).peerEntry(of: restored)?.account, savings)
    }

    func testUndoDeleteRestoresSplitsAndPeer() throws {
        let e = try save(draft("Store", "30"))
        let food = Category(name: "Food")
        context.insert(food)
        for (i, cents) in [-1000, -2000].enumerated() {
            let line = Entry(account: checking, date: e.date, amountCents: cents)
            line.splitOrder = i
            line.category = food
            context.insert(line)
            line.splitParent = e
        }
        e.status = .cleared
        try context.save()

        undo.beginUndoGrouping()
        EntryUndo.record("Delete Transaction", context: context, undoManager: undo, touching: [e],
                         change: { EntryStore(context: context).delete(e) }, result: { [] })
        undo.endUndoGrouping()
        XCTAssertTrue(try entries().isEmpty)

        undo.undo()
        let parent = try XCTUnwrap(try entries().first { $0.splitParent == nil })
        XCTAssertEqual(parent.uuid, e.uuid)
        XCTAssertEqual(parent.status, .cleared)
        XCTAssertEqual(parent.payee?.name, "Store")
        XCTAssertEqual(parent.sortedSplits.map(\.amountCents), [-1000, -2000])
        XCTAssertEqual(parent.sortedSplits.first?.category, food)
    }

    func testRegisterChangeUndo() throws {
        let e = try save(draft("Grocer", "5"))
        undo.beginUndoGrouping()
        EntryUndo.change("Mark Cleared", e, context: context, undoManager: undo) { $0.status = .cleared }
        undo.endUndoGrouping()
        XCTAssertEqual(e.status, .cleared)
        undo.undo()
        XCTAssertEqual(e.status, .uncleared)
    }
}
