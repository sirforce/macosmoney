import Foundation

/// Register dates are calendar days, not instants. They are stored as noon UTC and all day math
/// uses a UTC calendar, so a date never shifts when the Mac's time zone changes.
enum Day {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func date(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// Parses "yyyy-MM-dd".
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return date(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Today's local calendar day, as a Day value.
    static var today: Date { normalize(Date(), from: .current) }

    /// Converts an arbitrary instant (e.g. from a DatePicker) to the Day for that local date.
    static func normalize(_ date: Date, from tz: TimeZone = .current) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = tz
        let c = local.dateComponents([.year, .month, .day], from: date)
        return Self.date(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Converts a Day value to an instant at local noon, for use with DatePicker.
    static func toLocal(_ day: Date) -> Date {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        return local.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12))!
    }

    static func adding(_ component: Calendar.Component, _ n: Int, to day: Date) -> Date {
        calendar.date(byAdding: component, value: n, to: day)!
    }

    static func year(of day: Date) -> Int { calendar.component(.year, from: day) }

    static func startOfYear(_ day: Date) -> Date { date(year: year(of: day), month: 1, day: 1) }

    static func startOfMonth(_ day: Date) -> Date {
        let c = calendar.dateComponents([.year, .month], from: day)
        return date(year: c.year!, month: c.month!, day: 1)
    }

    static func startOfQuarter(_ day: Date) -> Date {
        let c = calendar.dateComponents([.year, .month], from: day)
        return date(year: c.year!, month: ((c.month! - 1) / 3) * 3 + 1, day: 1)
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func string(_ day: Date?) -> String { day.map { formatter.string(from: $0) } ?? "" }
}

enum Cents {
    static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f
    }()

    static let plainFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func decimal(_ cents: Int) -> Decimal { Decimal(cents) / 100 }

    static func string(_ cents: Int) -> String {
        formatter.string(from: decimal(cents) as NSDecimalNumber) ?? "\(cents)"
    }

    /// Unsigned number without currency symbol, for register columns.
    static func plain(_ cents: Int) -> String {
        plainFormatter.string(from: decimal(abs(cents)) as NSDecimalNumber) ?? ""
    }

    /// Parses "1234.56", "-1,234.56", "$12" into cents. Exact: no floating point.
    static func parse(_ s: String?) -> Int? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = Int(parts[0].isEmpty ? "0" : parts[0]) else { return nil }
        var frac = 0
        if parts.count == 2 {
            let f = String(parts[1].prefix(2)).padding(toLength: 2, withPad: "0", startingAt: 0)
            guard let v = Int(f) else { return nil }
            frac = v
        }
        let cents = whole * 100 + frac
        return negative ? -cents : cents
    }
}
