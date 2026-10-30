import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class AccountOrderTests: XCTestCase {
    func testDragOrderSticksAndNewAccountsGoLast() throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let names = ["Checking", "Brokerage", "Savings", "Card"]
        let accounts = names.map { n -> Account in let a = Account(name: n, kind: .bank); ctx.insert(a); return a }
        XCTAssertEqual(accounts.inSidebarOrder.map(\.name), ["Brokerage", "Card", "Checking", "Savings"], "by name until arranged")

        // Drag Savings to the top.
        let shown = accounts.inSidebarOrder
        shown.arrange(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(accounts.inSidebarOrder.map(\.name), ["Savings", "Brokerage", "Card", "Checking"])

        let added = Account(name: "Another", kind: .bank)
        ctx.insert(added)
        XCTAssertEqual((accounts + [added]).inSidebarOrder.map(\.name), ["Savings", "Brokerage", "Card", "Checking", "Another"],
                       "accounts never arranged follow the arranged ones")
    }
}
