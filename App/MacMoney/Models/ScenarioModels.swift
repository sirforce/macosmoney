import Foundation
import SwiftData

/// A named what-if laid over the forecast: "new car", "lose a client", "move in June".
/// App-only data; the importer never touches it.
@Model
final class Scenario {
    var uuid: UUID = UUID()
    var name: String = ""
    var notes: String = ""
    var created: Date = Date()
    var modified: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ScenarioItem.scenario)
    var items: [ScenarioItem]? = []

    init(name: String) { self.name = name }

    var sortedItems: [ScenarioItem] { (items ?? []).sorted { ($0.startDate, $0.created) < ($1.startDate, $1.created) } }

    /// Changes whenever the scenario or any of its items do, for recomputing the forecast.
    var signature: String {
        "\(uuid)|\(modified.timeIntervalSince1970)|" + sortedItems.map(\.signature).joined(separator: ",")
    }
}

enum ScenarioKind: String, Codable, CaseIterable, Identifiable {
    /// One amount on one date (a purchase, a bonus, a tax refund).
    case oneTime
    /// A new repeating amount (a car payment, a raise, a new client).
    case recurring
    /// An existing bill or deposit changes amount from a date (rent goes up).
    case changeBill
    /// An existing bill or deposit stops from a date (cancel a subscription, lose a client).
    case stopBill

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneTime: "One-time amount"
        case .recurring: "New recurring amount"
        case .changeBill: "Change a bill or deposit"
        case .stopBill: "Stop a bill or deposit"
        }
    }

    var symbol: String {
        switch self {
        case .oneTime: "1.circle"
        case .recurring: "repeat"
        case .changeBill: "slider.horizontal.3"
        case .stopBill: "stop.circle"
        }
    }
}

@Model
final class ScenarioItem {
    var uuid: UUID = UUID()
    var scenario: Scenario?
    var kindRaw: String = ScenarioKind.oneTime.rawValue
    var name: String = ""
    /// Signed: negative is money out. For `changeBill`, the bill's new amount.
    var amountCents: Int = 0
    /// Account for one-time and recurring amounts (by uuid, so it survives re-import).
    var accountUUID: UUID?
    /// The bill a change or stop applies to.
    var billUUID: UUID?
    var startDate: Date = Date()
    var endDate: Date?
    var unitRaw: String = RecurrenceUnit.month.rawValue
    var every: Int = 1
    var created: Date = Date()

    init(kind: ScenarioKind, startDate: Date) {
        self.kindRaw = kind.rawValue
        self.startDate = startDate
    }

    var kind: ScenarioKind {
        get { ScenarioKind(rawValue: kindRaw) ?? .oneTime }
        set { kindRaw = newValue.rawValue }
    }

    var unit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: unitRaw) ?? .month }
        set { unitRaw = newValue.rawValue }
    }

    var adjustment: ScenarioAdjustment {
        ScenarioAdjustment(kind: kind, name: name, amountCents: amountCents, accountUUID: accountUUID, billUUID: billUUID,
                           startDate: startDate, endDate: endDate, unit: unit, every: every)
    }

    var signature: String {
        "\(kindRaw);\(amountCents);\(accountUUID?.uuidString ?? "");\(billUUID?.uuidString ?? "");\(startDate.timeIntervalSince1970);"
            + "\(endDate?.timeIntervalSince1970 ?? 0);\(unitRaw);\(every);\(name)"
    }
}

/// Plain-value copy of a scenario item, which is what the forecast works from.
struct ScenarioAdjustment: Equatable {
    var kind: ScenarioKind
    var name = ""
    var amountCents = 0
    var accountUUID: UUID?
    var billUUID: UUID?
    var startDate: Date
    var endDate: Date?
    var unit: RecurrenceUnit = .month
    var every = 1

    /// Dates of a one-time or recurring amount from its start through `horizon` (and its end date).
    func occurrences(through horizon: Date) -> [Date] {
        switch kind {
        case .oneTime:
            return startDate <= horizon ? [startDate] : []
        case .recurring:
            let last = min(horizon, endDate ?? horizon)
            let anchor = Day.calendar.component(.day, from: startDate)
            var out: [Date] = []
            var d: Date? = startDate
            while let day = d, day <= last, out.count < 2000 {
                out.append(day)
                d = Recurrence.next(after: day, unit: unit, every: every, anchorDay: anchor)
            }
            return out
        case .changeBill, .stopBill:
            return []
        }
    }
}
