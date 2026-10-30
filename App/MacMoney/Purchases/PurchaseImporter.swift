import Foundation
import SwiftData

/// Brings an Amazon export into Purchases and links shipments to the card charges that paid for them.
///
/// Re-importing a newer export adds only what's new: purchases and items are keyed by Amazon's
/// order id, ship date and product, and anything already there (with its business tags, purpose
/// and link) is left exactly as it is.
@MainActor
struct PurchaseImporter {
    let context: ModelContext

    /// Amazon charges when a shipment leaves, which can be a little before or after the ship date
    /// in the export.
    static let linkDaysBefore = 2
    static let linkDaysAfter = 5

    struct Result: Equatable {
        var added = 0
        var itemsAdded = 0
        var unchanged = 0
        var refunds = 0
        var linked = 0
    }

    @discardableResult
    func importAmazon(_ export: AmazonExport) throws -> Result {
        var result = Result()
        let existing = (try? context.fetch(FetchDescriptor<Purchase>(predicate: #Predicate { $0.importKey != nil }))) ?? []
        var byKey: [String: Purchase] = [:]
        for p in existing { if let k = p.importKey { byKey[k] = p } }

        for order in export.orders {
            let purchase: Purchase
            let isNew = byKey[order.importKey] == nil
            if let p = byKey[order.importKey] {
                purchase = p
            } else {
                purchase = Purchase(vendor: "Amazon", date: order.date)
                purchase.shipDate = order.shipDate
                purchase.orderNumber = order.orderID
                purchase.source = order.digital ? "amazonDigital" : "amazon"
                purchase.importKey = order.importKey
                purchase.cardLast4 = order.cardLast4
                purchase.usedGiftCard = order.usedGiftCard
                context.insert(purchase)
                byKey[order.importKey] = purchase
                result.added += 1
            }
            let known = Set((purchase.items ?? []).compactMap(\.importKey))
            var seen: [String: Int] = [:]
            var addedAny = false
            for item in order.items {
                let base = "\(order.importKey)|\(item.asin)|\(item.amountCents)"
                let n = seen[base, default: 0]
                seen[base] = n + 1
                let key = n == 0 ? base : "\(base)#\(n)"
                guard !known.contains(key) else { continue }
                let i = PurchaseItem(name: item.name, amountCents: item.amountCents)
                i.asin = item.asin
                i.department = item.department
                i.quantity = item.quantity
                i.importKey = key
                context.insert(i)
                i.purchase = purchase
                result.itemsAdded += 1
                addedAny = true
            }
            if !isNew && !addedAny { result.unchanged += 1 }
        }

        // Refunds belong to the order; they go on its first shipment. Set, not added, so a
        // re-import doesn't count them twice.
        let byOrder = Dictionary(grouping: byKey.values, by: \.orderNumber)
        for (id, refunds) in Dictionary(grouping: export.refunds, by: \.orderID) {
            guard let p = byOrder[id]?.min(by: { $0.chargeDate < $1.chargeDate }) else { continue }
            let total = refunds.reduce(0) { $0 + $1.cents }
            if p.refundCents != total {
                p.refundCents = total
                p.refundDate = refunds.map(\.date).max()
                result.refunds += 1
            }
        }

        result.linked = autoLink(Array(byKey.values))
        try context.save()
        return result
    }

    // MARK: Linking to charges

    /// Links unlinked purchases to an Amazon charge of exactly the same amount near the ship date
    /// that no other purchase has claimed. Prefers the card Amazon says was used. Returns how many
    /// were linked.
    @discardableResult
    func autoLink(_ purchases: [Purchase]) -> Int {
        let open = purchases.filter { $0.entryUUID == nil && !$0.usedGiftCard && $0.totalCents > 0 }
        guard let earliest = open.map(\.chargeDate).min() else { return 0 }
        let claimed = Set(((try? context.fetch(FetchDescriptor<Purchase>())) ?? []).compactMap(\.entryUUID))
        let from = Day.adding(.day, -Self.linkDaysAfter, to: earliest)
        var candidates: [Int: [Entry]] = [:]
        let entries = (try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.amountCents < 0 && $0.date >= from }))) ?? []
        for e in entries where !e.isSplitLine && !e.isVoid && !claimed.contains(e.uuid) && Self.looksLikeAmazon(e) {
            candidates[-e.amountCents, default: []].append(e)
        }
        var linked = 0
        for p in open.sorted(by: { $0.chargeDate < $1.chargeDate }) {
            guard var list = candidates[p.totalCents], let i = bestCharge(for: p, in: list) else { continue }
            p.entryUUID = list.remove(at: i).uuid
            candidates[p.totalCents] = list
            linked += 1
        }
        return linked
    }

    private func bestCharge(for p: Purchase, in entries: [Entry]) -> Int? {
        let lo = Day.adding(.day, -Self.linkDaysBefore, to: p.chargeDate)
        let hi = Day.adding(.day, Self.linkDaysAfter, to: p.chargeDate)
        let card = p.cardLast4.isEmpty ? nil : "last4:\(p.cardLast4)"
        func onCard(_ e: Entry) -> Bool { card.map { c in e.account?.importHints.split(separator: "\n").contains { $0 == c } ?? false } ?? false }
        return entries.indices
            .filter { entries[$0].date >= lo && entries[$0].date <= hi }
            .min { a, b in
                let (ea, eb) = (entries[a], entries[b])
                if onCard(ea) != onCard(eb) { return onCard(ea) }
                return abs(ea.date.timeIntervalSince(p.chargeDate)) < abs(eb.date.timeIntervalSince(p.chargeDate))
            }
    }

    /// Charges whose payee or bank text says Amazon (AMZN Mktp, Amazon.com, Kindle, Audible, Prime Video).
    static func looksLikeAmazon(_ e: Entry) -> Bool {
        let text = "\(e.payee?.name ?? "") \(e.bankDescription ?? "")".uppercased()
        return ["AMAZON", "AMZN", "KINDLE", "AUDIBLE", "PRIME VIDEO"].contains { text.contains($0) }
    }

    /// Charges that could pay for `purchase`, for linking by hand: unclaimed, near the date, any amount.
    func chargeCandidates(for purchase: Purchase, days: Int = 14) -> [Entry] {
        chargeCandidates(near: purchase.chargeDate, totalCents: purchase.totalCents, keeping: purchase.entryUUID, days: days)
    }

    /// Unclaimed charges within `days` of `date`, closest amount first. `keeping` is the charge
    /// already linked to the purchase being edited, which stays in the list.
    func chargeCandidates(near date: Date, totalCents: Int, keeping: UUID? = nil, days: Int = 14) -> [Entry] {
        let lo = Day.adding(.day, -days, to: date)
        let hi = Day.adding(.day, days, to: date)
        let claimed = Set(((try? context.fetch(FetchDescriptor<Purchase>())) ?? []).compactMap(\.entryUUID))
        let entries = (try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.date >= lo && $0.date <= hi && $0.amountCents < 0 }))) ?? []
        return entries
            .filter { !$0.isSplitLine && !$0.isVoid && (!claimed.contains($0.uuid) || $0.uuid == keeping) }
            .sorted { a, b in
                let da = abs(a.amountCents + totalCents), db = abs(b.amountCents + totalCents)
                return da != db ? da < db : abs(a.date.timeIntervalSince(date)) < abs(b.date.timeIntervalSince(date))
            }
    }
}

/// Shared lookups for Purchases. The choices themselves are kept in `AppSettings`.
enum PurchaseSettings {
    /// The business that "Business" tags go to: the one chosen in Purchases, else the first.
    static func defaultBusiness(in businesses: [Business], settings: AppSettings?) -> Business? {
        businesses.first { $0.uuid == settings?.purchasesBusinessUUID } ?? businesses.sorted { $0.name < $1.name }.first
    }

    /// Not yet marked business or personal, and on or after the review date (older history is
    /// kept for searching, not queued).
    static func needsReview(_ p: Purchase, from: Date) -> Bool { p.chargeDate >= from && p.review == .needsReview }
}
