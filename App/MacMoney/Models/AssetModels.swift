import Foundation
import SwiftData

/// Something a business owns and depreciates over several years: a computer, a camera, furniture.
///
/// MacMoney keeps the list and each year's depreciation as your accountant worked it out (from the
/// depreciation schedule that goes with Form 4562). It does not calculate depreciation: the method,
/// Section 179 and bonus choices are tax decisions, and the figures here should match what was filed.
/// Each year's amount goes on Schedule C line 13. App-only data: Money re-imports never touch it.
@Model
final class Asset {
    var uuid: UUID = UUID()
    /// The business it belongs to (by uuid, like purchase items).
    var businessUUID: UUID?
    var name: String = ""
    var placedInService: Date?
    /// Cost or other basis.
    var costCents: Int = 0
    /// How it's depreciated, in the schedule's own words ("5-yr MACRS 200DB HY", "Section 179").
    var method: String = ""
    /// Depreciation taken in years before the first one listed here.
    var priorDepreciationCents: Int = 0
    /// Depreciation per tax year in cents ({"2025": 53000}).
    var yearAmountsJSON: String = ""
    /// Sold, scrapped or taken out of business use.
    var disposedDate: Date?
    var notes: String = ""
    /// The purchase item it came from, if it was made from one.
    var purchaseItemUUID: UUID?
    var created: Date = Date()

    init(name: String) { self.name = name }

    var yearAmounts: [Int: Int] {
        get { (try? JSONDecoder().decode([Int: Int].self, from: Data(yearAmountsJSON.utf8))) ?? [:] }
        set { yearAmountsJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self) }
    }

    /// Everything depreciated so far, through `year` when given.
    func depreciatedCents(through year: Int? = nil) -> Int {
        priorDepreciationCents + yearAmounts.filter { year == nil || $0.key <= year! }.values.reduce(0, +)
    }

    /// What's left of the cost.
    func remainingCents(through year: Int? = nil) -> Int { costCents - depreciatedCents(through: year) }

    /// A year's depreciation counts in a report that includes that year's last day, so it appears
    /// once in a tax-year report and never twice in a longer range.
    func depreciationCents(in range: ClosedRange<Date>) -> Int {
        yearAmounts.filter { range.contains(Day.date(year: $0.key, month: 12, day: 31)) }.values.reduce(0, +)
    }

    @MainActor
    static func all(for business: Business, in context: ModelContext) -> [Asset] {
        let id: UUID? = business.uuid
        let found = (try? context.fetch(FetchDescriptor<Asset>(predicate: #Predicate { $0.businessUUID == id }))) ?? []
        return found.sorted { ($0.placedInService ?? .distantPast, $0.name) < ($1.placedInService ?? .distantPast, $1.name) }
    }
}
