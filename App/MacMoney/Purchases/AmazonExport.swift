import Foundation

/// Reads Amazon's "Request Your Data" export (the "Your Orders" folder): physical orders, digital
/// orders and refunds. Addresses, gift messages and tracking numbers are never read.
struct AmazonExport {
    struct Item: Equatable {
        var name: String
        var asin: String
        var department: String
        var quantity: Int
        var amountCents: Int
    }

    /// One shipment (Amazon charges the card per shipment), or one digital order.
    struct Order: Equatable {
        var orderID: String
        var date: Date
        var shipDate: Date?
        var digital: Bool
        var cardLast4: String
        var usedGiftCard: Bool
        var items: [Item]
        var totalCents: Int { items.reduce(0) { $0 + $1.amountCents } }
        /// Stable identity across exports.
        var importKey: String { "amazon:\(orderID)|\(shipDate.map(BankRow.iso.string(from:)) ?? "")" }
    }

    struct Refund: Equatable {
        var orderID: String
        var date: Date
        var cents: Int
    }

    var orders: [Order] = []
    var refunds: [Refund] = []

    static let orderFile = "Order History.csv"
    static let digitalFile = "Digital Content Orders.csv"
    static let refundFile = "Refund Details.csv"

    /// Whether a dropped file or folder is (or is inside) an Amazon export.
    static func isExport(_ url: URL) -> Bool {
        url.pathComponents.contains("Your Orders") || [orderFile, digitalFile, refundFile].contains(url.lastPathComponent)
    }

    /// The folder to import for a file inside an export: the folder holding "Your Orders".
    static func exportRoot(_ url: URL) -> URL {
        var u = url
        while u.pathComponents.count > 1 {
            if u.lastPathComponent == "Your Orders" { return u }
            u.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent()
    }

    /// Finds the export's CSV files anywhere under `url` and reads them.
    static func read(_ url: URL) throws -> AmazonExport {
        var files: [URL] = []
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            while let f = e?.nextObject() as? URL { files.append(f) }
        } else {
            files = [url]
        }
        var export = AmazonExport()
        for f in files {
            switch f.lastPathComponent {
            case orderFile: export.orders += parseOrders(try String(contentsOf: f, encoding: .utf8))
            case digitalFile: export.orders += parseDigital(try String(contentsOf: f, encoding: .utf8))
            case refundFile: export.refunds += parseRefunds(try String(contentsOf: f, encoding: .utf8))
            default: continue
            }
        }
        return export
    }

    // MARK: Parsing

    private static func table(_ text: String) -> [[String: String]] {
        let rows = CSV.parse(text)
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { row in
            var d: [String: String] = [:]
            for (i, h) in header.enumerated() where i < row.count { d[h] = row[i] }
            return d
        }
    }

    /// "2024-08-06T11:44:22Z" → that day (UTC, which is how Amazon reports it). "Not Available" → nil.
    static func day(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Day.date(year: parts[0], month: parts[1], day: parts[2])
    }

    /// "23.31", "'-3'", "1,299.00" → cents.
    static func cents(_ s: String?) -> Int {
        let t = (s ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: ",", with: "")
        guard let d = Decimal(string: t) else { return 0 }
        return NSDecimalNumber(decimal: d * 100).rounding(accordingToBehavior: nil).intValue
    }

    /// "Gift Certificate/Card and MasterCard - 1234" → ("1234", true).
    static func payment(_ s: String?) -> (last4: String, giftCard: Bool) {
        let s = s ?? ""
        let gift = s.contains("Gift Certificate")
        guard let dash = s.range(of: " - ", options: .backwards) else { return ("", gift) }
        let tail = s[dash.upperBound...].trimmingCharacters(in: .whitespaces)
        return (tail.count == 4 && tail.allSatisfy(\.isNumber) ? tail : "", gift)
    }

    static func parseOrders(_ text: String) -> [Order] {
        var byKey: [String: Order] = [:]
        var order: [String] = []
        for r in table(text) {
            guard let id = r["Order ID"], !id.isEmpty, r["Order Status"] != "Cancelled",
                  let date = day(r["Order Date"]) else { continue }
            let ship = day(r["Ship Date"])
            let key = "\(id)|\(ship.map(BankRow.iso.string(from:)) ?? "")"
            let item = Item(name: (r["Product Name"] ?? "").trimmingCharacters(in: .whitespaces),
                            asin: r["ASIN"] ?? "",
                            department: r["Department"] == "Not Available" ? "" : (r["Department"] ?? ""),
                            quantity: max(1, Int(r["Original Quantity"] ?? "") ?? 1),
                            amountCents: cents(r["Total Amount"]))
            if byKey[key] == nil {
                let pay = payment(r["Payment Method Type"])
                byKey[key] = Order(orderID: id, date: date, shipDate: ship, digital: false,
                                   cardLast4: pay.last4, usedGiftCard: pay.giftCard, items: [])
                order.append(key)
            }
            byKey[key]!.items.append(item)
        }
        return order.compactMap { byKey[$0] }
    }

    /// Digital orders have a row per price component (price, tax). Free ones are skipped.
    static func parseDigital(_ text: String) -> [Order] {
        var byID: [String: Order] = [:]
        var ids: [String] = []
        for r in table(text) {
            guard let id = r["Order ID"], !id.isEmpty, let date = day(r["Order Date"]) else { continue }
            let amount = cents(r["Transaction Amount"])
            let name = (r["Product Name"] ?? "").trimmingCharacters(in: .whitespaces)
            let asin = r["ASIN"] ?? ""
            if byID[id] == nil {
                let pay = payment(r["Payment Information"])
                byID[id] = Order(orderID: id, date: date, shipDate: nil, digital: true,
                                 cardLast4: pay.last4, usedGiftCard: pay.giftCard, items: [])
                ids.append(id)
            }
            if let i = byID[id]!.items.firstIndex(where: { $0.asin == asin && $0.name == name }) {
                byID[id]!.items[i].amountCents += amount
            } else {
                byID[id]!.items.append(Item(name: name, asin: asin, department: "Digital", quantity: 1, amountCents: amount))
            }
        }
        return ids.compactMap { byID[$0] }.filter { $0.totalCents != 0 }
    }

    /// Refund Details repeats rows; identical ones are counted once.
    static func parseRefunds(_ text: String) -> [Refund] {
        var seen = Set<String>()
        var out: [Refund] = []
        for r in table(text) {
            guard let id = r["Order ID"], !id.isEmpty, let date = day(r["Refund Date"] ?? r["Creation Date"]) else { continue }
            let c = cents(r["Refund Amount"])
            guard c != 0, seen.insert("\(id)|\(r["Refund Date"] ?? "")|\(c)").inserted else { continue }
            out.append(Refund(orderID: id, date: date, cents: c))
        }
        return out
    }
}
