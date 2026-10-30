import Foundation
import SwiftData

/// Something bought, with its items: an Amazon shipment, a store order, a receipt typed in by hand.
/// Items carry the business/personal tags, so one charge can be part business and part personal.
/// App-only data: Money re-imports never touch it.
@Model
final class Purchase {
    var uuid: UUID = UUID()
    var vendor: String = ""
    var orderNumber: String = ""
    /// Order date (what the vendor shows).
    var date: Date = Date()
    /// When it shipped, which is when Amazon charges the card.
    var shipDate: Date?
    /// "amazon", "amazonDigital" or "manual".
    var source: String = "manual"
    /// Identity in the vendor's export, so re-importing never adds it twice.
    var importKey: String?
    /// The card or bank charge that paid for it.
    var entryUUID: UUID?
    /// Last four digits of the card the vendor says was used.
    var cardLast4: String = ""
    /// Part was paid with a gift card, so the card charge is smaller than the total.
    var usedGiftCard: Bool = false
    var refundCents: Int = 0
    var refundDate: Date?
    var notes: String = ""
    /// A web page for the order or receipt (the store's order page, an emailed receipt link).
    var link: String = ""
    var created: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \PurchaseItem.purchase)
    var items: [PurchaseItem]? = []

    init(vendor: String, date: Date) {
        self.vendor = vendor
        self.date = date
    }

    var sortedItems: [PurchaseItem] { (items ?? []).sorted { ($0.created, $0.name) < ($1.created, $1.name) } }
    var totalCents: Int { (items ?? []).reduce(0) { $0 + $1.amountCents } }
    var isAmazon: Bool { source == "amazon" || source == "amazonDigital" }

    /// The order's web page: the saved link, else Amazon's order page for an Amazon order.
    /// Opens in the default browser, where you're signed in.
    var webURL: URL? {
        let t = link.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return URL(string: t.contains("://") ? t : "https://\(t)") }
        guard isAmazon, !orderNumber.isEmpty,
              let id = orderNumber.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: source == "amazonDigital"
            ? "https://www.amazon.com/gp/digital/your-account/order-summary.html?orderID=\(id)"
            : "https://www.amazon.com/gp/your-account/order-details?orderID=\(id)")
    }

    var webLabel: String { link.isEmpty && isAmazon ? "View Order on Amazon" : "Open Order Page" }

    /// The day the charge should appear.
    var chargeDate: Date { shipDate ?? date }

    /// "Coffee pot, USB cable (+1 more)"
    var summary: String {
        let names = sortedItems.map(\.shortName)
        guard let first = names.first else { return "" }
        if names.count == 1 { return first }
        if names.count == 2 { return "\(first), \(names[1])" }
        return "\(first), \(names[1]) (+\(names.count - 2) more)"
    }

    enum Review { case needsReview, business, personal, mixed, hidden }

    /// Hidden items are left out: a purchase whose items are all hidden needs nothing.
    var review: Review {
        let shown = (items ?? []).filter { !$0.isHidden }
        if !(items ?? []).isEmpty && shown.isEmpty { return .hidden }
        let tags = Set(shown.map(\.tag))
        if tags.contains(.untagged) { return .needsReview }
        if tags == [.personal] { return .personal }
        if tags == [.business] { return .business }
        return tags.isEmpty ? .needsReview : .mixed
    }

    /// Business share of the purchase (items tagged business, times their business %).
    var businessCents: Int { (items ?? []).reduce(0) { $0 + $1.businessCents } }
}

@Model
final class PurchaseItem {
    var uuid: UUID = UUID()
    var purchase: Purchase?
    var name: String = ""
    /// Amazon's product id.
    var asin: String = ""
    /// The vendor's department ("Musical Instruments").
    var department: String = ""
    var quantity: Int = 1
    /// What it cost, tax and discounts included. Positive.
    var amountCents: Int = 0
    var importKey: String?
    /// The business it's for (by uuid); nil with `isPersonal` false means not reviewed yet.
    var businessUUID: UUID?
    var isPersonal: Bool = false
    var taxLineRaw: String?
    var businessPercent: Int = 100
    /// Why it's a business expense (the IRS wants this for meals, travel and gifts).
    var purpose: String = ""
    var returned: Bool = false
    /// Left out of the Purchases list, its search and the review count unless "Show hidden" is on.
    var isHidden: Bool = false
    var notes: String = ""
    var created: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \PurchaseFile.item)
    var files: [PurchaseFile]? = []

    init(name: String, amountCents: Int) {
        self.name = name
        self.amountCents = amountCents
    }

    enum Tag { case untagged, business, personal }

    var tag: Tag { businessUUID != nil ? .business : (isPersonal ? .personal : .untagged) }

    var taxLine: TaxLine? {
        get { taxLineRaw.flatMap(TaxLine.init(rawValue:)) }
        set { taxLineRaw = newValue?.rawValue }
    }

    var businessCents: Int {
        guard businessUUID != nil, !returned else { return 0 }
        return amountCents * businessPercent / 100
    }

    /// The product's page on Amazon.
    var productURL: URL? {
        guard purchase?.isAmazon == true, !asin.isEmpty,
              let id = asin.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://www.amazon.com/dp/\(id)")
    }

    /// The product name without Amazon's long tail of keywords.
    var shortName: String {
        let cut = name.split(whereSeparator: { ",|(–—".contains($0) }).first.map(String.init) ?? name
        let words = cut.split(separator: " ")
        let short = words.prefix(6).joined(separator: " ")
        return words.count > 6 ? short + "…" : short
    }
}

/// A receipt or other document for an item, wherever it is on the Mac. Only where it is gets
/// saved (path and bookmark), never the file itself, so backups stay small and the file stays yours.
@Model
final class PurchaseFile {
    var uuid: UUID = UUID()
    var item: PurchaseItem?
    var path: String = ""
    /// Finds the file again after it's renamed or moved on the same disk.
    var bookmark: Data?
    var added: Date = Date()

    init(url: URL) {
        path = url.path
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    var name: String { (path as NSString).lastPathComponent }

    /// Where the file is now: the bookmark first (follows moves and renames), then the saved
    /// path. Nil when it can't be found. Updates the saved path when the file has moved.
    func locate() -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                if url.path != path { path = url.path }
                if stale { self.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
                return url
            }
        }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
