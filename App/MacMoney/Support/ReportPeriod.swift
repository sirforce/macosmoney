import Foundation

enum ReportPeriod: String, CaseIterable, Identifiable {
    case allDates = "All dates"
    case thisMonth = "This month"
    case lastMonth = "Last month"
    case thisQuarter = "This quarter"
    case lastQuarter = "Last quarter"
    case yearToDate = "Year to date"
    case thisYear = "This year"
    case lastYear = "Last year"
    case last12Months = "Last 12 months"
    case custom = "Custom…"

    var id: String { rawValue }

    /// Inclusive day range, or nil for all dates / custom.
    func range(today: Date = Day.today) -> ClosedRange<Date>? {
        let d = Day.self
        switch self {
        case .allDates, .custom: return nil
        case .thisMonth:
            let s = d.startOfMonth(today)
            return s...d.adding(.day, -1, to: d.adding(.month, 1, to: s))
        case .lastMonth:
            let s = d.adding(.month, -1, to: d.startOfMonth(today))
            return s...d.adding(.day, -1, to: d.startOfMonth(today))
        case .thisQuarter:
            let s = d.startOfQuarter(today)
            return s...d.adding(.day, -1, to: d.adding(.month, 3, to: s))
        case .lastQuarter:
            let s = d.adding(.month, -3, to: d.startOfQuarter(today))
            return s...d.adding(.day, -1, to: d.startOfQuarter(today))
        case .yearToDate:
            return d.startOfYear(today)...today
        case .thisYear:
            let s = d.startOfYear(today)
            return s...d.adding(.day, -1, to: d.adding(.year, 1, to: s))
        case .lastYear:
            let s = d.adding(.year, -1, to: d.startOfYear(today))
            return s...d.adding(.day, -1, to: d.startOfYear(today))
        case .last12Months:
            return d.adding(.day, 1, to: d.adding(.year, -1, to: today))...today
        }
    }
}

enum CSV {
    static func field(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
    }

    static func row(_ fields: [String]) -> String { fields.map(field).joined(separator: ",") }
}
