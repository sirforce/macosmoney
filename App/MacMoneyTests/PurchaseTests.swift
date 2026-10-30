import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class PurchaseTests: XCTestCase {
    private var ctx: ModelContext!

    override func setUpWithError() throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = ModelContext(container)
    }

    // Fake orders: one with two items in one shipment, one split into two shipments, a gift-card
    // order and a cancelled one.
    private let orders = """
    ASIN,"Billing Address","Carrier Name & Tracking Number",Currency,Department,"Gift Message","Gift Recipient Contact","Gift Sender Name","Item Serial Number","Order Date","Order ID","Order Status","Original Quantity","Payment Method Type","Product Condition","Product Name","Purchase Order Number","Ship Date","Shipment Item Subtotal","Shipment Item Subtotal Tax","Shipment Status","Shipping Address","Shipping Charge","Shipping Option","Total Amount","Total Discounts","Unit Price","Unit Price Tax",Website
    B000000001,"x","x",USD,"Musical Instruments","","","","","2026-10-01T10:00:00Z","111-0000001-0000001","Closed","1","MasterCard - 1234","New","Guitar Strings, Light Gauge, 3 Pack","Not Available","2026-10-02T08:00:00Z","20","1.2","Shipped","x","0","std","21.20","0","20","1.2",Amazon.com
    B000000002,"x","x",USD,"Office Products","","","","","2026-10-01T10:00:00Z","111-0000001-0000001","Closed","2","MasterCard - 1234","New","Printer Paper (Pack of 2)","Not Available","2026-10-02T08:00:00Z","10","0.6","Shipped","x","0","std","10.60","0","5","0.3",Amazon.com
    B000000003,"x","x",USD,"Kitchen","","","","","2026-10-05T10:00:00Z","111-0000002-0000002","Closed","1","Visa - 9876","New","Coffee Mug","Not Available","2026-10-06T08:00:00Z","8","0.48","Shipped","x","0","std","8.48","0","8","0.48",Amazon.com
    B000000004,"x","x",USD,"Electronics","","","","","2026-10-05T10:00:00Z","111-0000002-0000002","Closed","1","Visa - 9876","New","USB-C Cable","Not Available","2026-10-09T08:00:00Z","12","0.72","Shipped","x","0","std","'12.72'","'-0'","12","0.72",Amazon.com
    B000000005,"x","x",USD,"Books","","","","","2026-10-07T10:00:00Z","111-0000003-0000003","Closed","1","Gift Certificate/Card and Visa - 9876","New","A Book","Not Available","2026-10-08T08:00:00Z","15","0","Shipped","x","0","std","15","0","15","0",Amazon.com
    B000000006,"x","x",USD,"Toys","","","","","2026-10-07T10:00:00Z","111-0000004-0000004","Cancelled","1","Visa - 9876","New","Cancelled Thing","Not Available","Not Available","15","0","Not Available","x","0","std","15","0","15","0",Amazon.com
    """

    private let digital = """
    ASIN,"Component Type","Order Date","Order ID","Product Name","Transaction Amount",Marketplace,"Payment Information"
    D1,"Price Amount","2026-10-03T12:00:00Z","D01-0000001-0000001","Sample App","1.99",www.amazon.com,""
    D1,"Tax","2026-10-03T12:00:00Z","D01-0000001-0000001","Sample App","0.12",www.amazon.com,""
    D2,"Price Amount","2026-10-04T12:00:00Z","D01-0000002-0000002","Free Thing","0.0",www.amazon.com,""
    """

    private let refunds = """
    "Creation Date",Currency,"Direct Debit Refund Amount","Disbursement Type","Order ID","Payment Status",Quantity,"Refund Amount","Refund Date","Reversal Amount State","Reversal Reason","Reversal Status",Website
    "2026-10-20T00:00:00Z",USD,"","Refund","111-0000002-0000002","","1","8.48","2026-10-20T01:00:00.000Z","","","",Amazon.com
    "2026-10-20T00:00:00Z",USD,"","Refund","111-0000002-0000002","","1","8.48","2026-10-20T01:00:00.000Z","","","",Amazon.com
    """

    private func export() -> AmazonExport {
        var e = AmazonExport()
        e.orders = AmazonExport.parseOrders(orders) + AmazonExport.parseDigital(digital)
        e.refunds = AmazonExport.parseRefunds(refunds)
        return e
    }

    private func purchases() throws -> [Purchase] {
        try ctx.fetch(FetchDescriptor<Purchase>()).sorted { ($0.chargeDate, $0.orderNumber) < ($1.chargeDate, $1.orderNumber) }
    }

    private func charge(_ account: Account, _ day: Int, _ cents: Int, payee: String = "Amazon") -> Entry {
        let e = Entry(account: account, date: Day.date(year: 2026, month: 10, day: day), amountCents: -cents)
        ctx.insert(e)
        let p = Payee(name: payee)
        ctx.insert(p)
        e.payee = p
        return e
    }

    func testParsesShipmentsDigitalAndRefunds() {
        let e = export()
        XCTAssertEqual(e.orders.count, 5, "4 shipments (cancelled skipped) + 1 paid digital order")
        let first = e.orders[0]
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(first.totalCents, 3180)
        XCTAssertEqual(first.cardLast4, "1234")
        XCTAssertEqual(first.shipDate, Day.date(year: 2026, month: 10, day: 2))
        XCTAssertEqual(first.items[1].quantity, 2)
        XCTAssertEqual(e.orders[2].totalCents, 1272, "quoted amounts are read")
        XCTAssertTrue(e.orders[3].usedGiftCard)
        XCTAssertEqual(e.orders[4].totalCents, 211, "price + tax")
        XCTAssertTrue(e.orders[4].digital)
        XCTAssertEqual(e.refunds.count, 1, "repeated refund rows count once")
    }

    func testImportLinksChargesAndReimportKeepsTags() throws {
        let card = Account(name: "Card A", kind: .creditCard)
        card.importHints = "last4:1234"
        let other = Account(name: "Card B", kind: .creditCard)
        ctx.insert(card); ctx.insert(other)
        let decoy = charge(other, 3, 3180)                 // same amount, wrong card
        let right = charge(card, 4, 3180)                  // the card Amazon names, 2 days after shipping
        _ = charge(card, 7, 848)                           // mug shipment
        _ = charge(card, 30, 1272)                         // too late for the cable shipment
        _ = charge(card, 3, 1500, payee: "Hardware Store") // not Amazon

        let r = try PurchaseImporter(context: ctx).importAmazon(export())
        XCTAssertEqual(r.added, 5)
        XCTAssertEqual(r.itemsAdded, 6)
        XCTAssertEqual(r.refunds, 1)
        XCTAssertEqual(r.linked, 2)

        let ps = try purchases()
        let strings = ps.first { $0.orderNumber == "111-0000001-0000001" }!
        XCTAssertEqual(strings.entryUUID, right.uuid, "prefers the card Amazon says was used")
        XCTAssertNotEqual(strings.entryUUID, decoy.uuid)
        XCTAssertNil(ps.first { $0.usedGiftCard }!.entryUUID, "gift-card orders aren't auto-linked")
        let mug = ps.first { $0.orderNumber == "111-0000002-0000002" && $0.shipDate == Day.date(year: 2026, month: 10, day: 6) }!
        XCTAssertEqual(mug.refundCents, 848)

        // Tag, then import the same export again.
        let item = strings.sortedItems[0]
        let b = Business(name: "Studio")
        ctx.insert(b)
        item.businessUUID = b.uuid
        item.purpose = "Client sessions"
        strings.notes = "kept"
        let again = try PurchaseImporter(context: ctx).importAmazon(export())
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.itemsAdded, 0)
        XCTAssertEqual(again.refunds, 0)
        XCTAssertEqual(again.unchanged, 5)
        XCTAssertEqual(try purchases().count, 5)
        XCTAssertEqual(item.businessUUID, b.uuid)
        XCTAssertEqual(item.purpose, "Client sessions")
        XCTAssertEqual(strings.notes, "kept")
        XCTAssertEqual(strings.entryUUID, right.uuid)
        XCTAssertEqual(strings.businessCents, 2120)
        XCTAssertEqual(strings.review, .needsReview, "one item still untagged")
    }

    func testReviewStatusAndSuggestedLines() {
        let p = Purchase(vendor: "Amazon", date: Day.date(year: 2026, month: 3, day: 1))
        ctx.insert(p)
        let a = PurchaseItem(name: "Camera Body", amountCents: 300_000)
        let b = PurchaseItem(name: "Notebook", amountCents: 500)
        b.department = "Office Products"
        for i in [a, b] { ctx.insert(i); i.purchase = p }
        let from = AppSettings.defaultReviewFrom
        XCTAssertTrue(PurchaseSettings.needsReview(p, from: from))
        XCTAssertEqual(PurchaseRules.suggestedLine(for: a), .capitalPurchase)
        XCTAssertEqual(PurchaseRules.suggestedLine(for: b), .office)
        a.businessUUID = UUID(); b.isPersonal = true
        XCTAssertEqual(p.review, .mixed)
        XCTAssertFalse(PurchaseSettings.needsReview(p, from: from))
        a.businessPercent = 50
        XCTAssertEqual(p.businessCents, 150_000)

        let old = Purchase(vendor: "Amazon", date: Day.date(year: 2020, month: 1, day: 1))
        ctx.insert(old)
        let i = PurchaseItem(name: "Old Thing", amountCents: 100)
        ctx.insert(i); i.purchase = old
        XCTAssertFalse(PurchaseSettings.needsReview(old, from: from), "history before the review date isn't queued")
    }

    func testHiddenItemsDontNeedReview() {
        let p = Purchase(vendor: "Amazon", date: Day.date(year: 2026, month: 5, day: 1))
        let a = PurchaseItem(name: "Gift for a friend", amountCents: 2000)
        let b = PurchaseItem(name: "Batteries", amountCents: 900)
        ctx.insert(p)
        for i in [a, b] { ctx.insert(i); i.purchase = p }
        let from = AppSettings.defaultReviewFrom
        XCTAssertTrue(PurchaseSettings.needsReview(p, from: from))
        a.isHidden = true
        XCTAssertTrue(PurchaseSettings.needsReview(p, from: from), "the other item still needs a decision")
        b.isPersonal = true
        XCTAssertEqual(p.review, .personal, "hidden items are left out")
        XCTAssertFalse(PurchaseSettings.needsReview(p, from: from))
        b.isPersonal = false
        b.isHidden = true
        XCTAssertEqual(p.review, .hidden)
        XCTAssertFalse(PurchaseSettings.needsReview(p, from: from), "all hidden: nothing to review")
    }

    func testWebLinks() {
        let amazon = Purchase(vendor: "Amazon", date: Day.today)
        amazon.source = "amazon"
        amazon.orderNumber = "111-0000001-0000001"
        ctx.insert(amazon)
        XCTAssertEqual(amazon.webURL?.absoluteString, "https://www.amazon.com/gp/your-account/order-details?orderID=111-0000001-0000001")
        XCTAssertEqual(amazon.webLabel, "View Order on Amazon")
        let item = PurchaseItem(name: "Strings", amountCents: 100)
        item.asin = "B000000001"
        ctx.insert(item); item.purchase = amazon
        XCTAssertEqual(item.productURL?.absoluteString, "https://www.amazon.com/dp/B000000001")

        let digital = Purchase(vendor: "Amazon", date: Day.today)
        digital.source = "amazonDigital"
        digital.orderNumber = "D01-0000001-0000001"
        XCTAssertTrue(digital.webURL!.absoluteString.contains("digital/your-account/order-summary.html?orderID=D01-0000001-0000001"))

        let store = Purchase(vendor: "Music Store", date: Day.today)
        XCTAssertNil(store.webURL, "no link, no page")
        store.link = "example.com/orders/42"
        XCTAssertEqual(store.webURL?.absoluteString, "https://example.com/orders/42", "https:// added when missing")
        XCTAssertEqual(store.webLabel, "Open Order Page")
    }

    func testReceiptFilesFollowRenamesAndAreRemovedWithTheItem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Receipts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let receipt = dir.appendingPathComponent("receipt.pdf")
        try Data("receipt".utf8).write(to: receipt)

        let p = Purchase(vendor: "Music Store", date: Day.today)
        let item = PurchaseItem(name: "Cable", amountCents: 1999)
        ctx.insert(p); ctx.insert(item); item.purchase = p
        ReceiptFiles.attach([receipt, receipt], to: [item], context: ctx)
        ReceiptFiles.attach([receipt], to: [item], context: ctx)
        XCTAssertEqual(item.files?.count, 1, "the same file is attached once")
        let file = try XCTUnwrap(item.files?.first)
        XCTAssertEqual(file.name, "receipt.pdf")
        XCTAssertNotNil(file.bookmark)

        let renamed = dir.appendingPathComponent("2026 cable receipt.pdf")
        try FileManager.default.moveItem(at: receipt, to: renamed)
        XCTAssertEqual(file.locate()?.lastPathComponent, renamed.lastPathComponent, "found after a rename")
        XCTAssertEqual(file.name, renamed.lastPathComponent, "saved path updated")

        try FileManager.default.removeItem(at: renamed)
        XCTAssertNil(file.locate(), "deleted files are reported missing")

        ctx.delete(item)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<PurchaseFile>()), 0)
    }

    /// Optional: dry-run a real Amazon export (set TEST_RUNNER_MACMONEY_AMAZON_FOLDER).
    func testRealAmazonExport() throws {
        guard let path = ProcessInfo.processInfo.environment["MACMONEY_AMAZON_FOLDER"] else { throw XCTSkip("No Amazon folder set") }
        let e = try AmazonExport.read(URL(fileURLWithPath: path))
        let r = try PurchaseImporter(context: ctx).importAmazon(e)
        print("Amazon export: \(e.orders.count) orders, \(e.refunds.count) refunds → \(r)")
        XCTAssertGreaterThan(e.orders.count, 0)
        XCTAssertEqual(try PurchaseImporter(context: ctx).importAmazon(e).added, 0)
    }
}
