import Foundation
import SwiftData

/// Settings that change your numbers, kept in the data file so backups and restores include them.
/// One record. Layout and this Mac's backup choices stay in preferences.
@Model
final class AppSettings {
    var created: Date = Date()
    /// Mileage rates entered or changed, cents per mile by year ({"2026": 72.5}).
    var mileageRatesJSON: String = ""
    /// Purchases from this day on count as needing review.
    var purchasesReviewFrom: Date?
    /// The business that B tags purchase items for.
    var purchasesBusinessUUID: UUID?

    init() {}

    /// The settings record, made on first use. Earlier versions kept these in preferences; they're
    /// moved in the first time.
    @MainActor
    static func current(in context: ModelContext, defaults: UserDefaults = .standard) -> AppSettings {
        let all = (try? context.fetch(FetchDescriptor<AppSettings>(sortBy: [SortDescriptor(\.created)]))) ?? []
        if let first = all.first { return first }
        let s = AppSettings()
        context.insert(s)
        s.adoptPreferences(defaults)
        try? context.save()
        return s
    }

    var mileageRates: [Int: Double] {
        get { (try? JSONDecoder().decode([Int: Double].self, from: Data(mileageRatesJSON.utf8))) ?? [:] }
        set { mileageRatesJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self) }
    }

    static let defaultReviewFrom = Day.date(year: 2026, month: 1, day: 1)
    var reviewFrom: Date { purchasesReviewFrom ?? Self.defaultReviewFrom }

    // MARK: Moving from preferences

    static let legacyKeys = (mileage: "mileageRates", reviewFrom: "purchases.reviewFrom", business: "purchases.business")

    private func adoptPreferences(_ defaults: UserDefaults) {
        if let data = defaults.data(forKey: Self.legacyKeys.mileage),
           let saved = try? JSONDecoder().decode([Int: Double].self, from: data) {
            mileageRates = saved
        }
        purchasesReviewFrom = defaults.object(forKey: Self.legacyKeys.reviewFrom) as? Date
        purchasesBusinessUUID = defaults.string(forKey: Self.legacyKeys.business).flatMap(UUID.init(uuidString:))
        for key in [Self.legacyKeys.mileage, Self.legacyKeys.reviewFrom, Self.legacyKeys.business] { defaults.removeObject(forKey: key) }
    }
}
