import Foundation
import SwiftData

/// Builds Schedule C figures for one business over a date range, from every account.
///
/// Amounts are reported as positive numbers for both income and expenses (refunds to an expense
/// line reduce it). Transfers between accounts are never income or expense and are skipped unless
/// a tax line was set on them explicitly.
struct ScheduleCReport {
    struct Item: Identifiable {
        let id: PersistentIdentifier
        let date: Date
        let account: String
        let payee: String
        let category: String
        let memo: String
        /// Business portion, positive = income for income lines / expense for expense lines.
        let cents: Int
        let percent: Int
        let vehicle: String?
    }

    struct LineTotal: Identifiable {
        let line: TaxLine
        var cents: Int
        var items: [Item]
        var id: String { line.rawValue }
        /// After the meals 50% limit.
        var deductibleCents: Int { cents * line.deductiblePercent / 100 }
    }

    struct VehicleSummary: Identifiable {
        let id: PersistentIdentifier
        let name: String
        let usesStandardRate: Bool
        let placedInService: Date?
        var businessTenths = 0
        var commutingTenths = 0
        var personalTenths = 0
        var odometerTotalMiles: Int?
        var expenses: [VehicleExpense: Int] = [:]
        var items: [Item] = []
        var standardMileageCents = 0
        var missingRateYears: [Int] = []

        var loggedTotalTenths: Int { businessTenths + commutingTenths + personalTenths }
        var totalTenths: Int { odometerTotalMiles.map { $0 * 10 } ?? loggedTotalTenths }
        var businessPercent: Double { totalTenths > 0 ? Double(businessTenths) / Double(totalTenths) : 0 }
        var totalExpenseCents: Int { expenses.values.reduce(0, +) }

        /// The amount that goes on line 9 (car and truck expenses).
        var line9Cents: Int {
            let parking = expenses[.parkingTolls] ?? 0
            if usesStandardRate { return standardMileageCents + parking }
            let other = totalExpenseCents - parking - (expenses[.lease] ?? 0)
            return Int((Double(other) * businessPercent).rounded()) + parking
        }

        /// Lease payments belong on line 20a (business share) under the actual-expense method.
        var line20aCents: Int {
            usesStandardRate ? 0 : Int((Double(expenses[.lease] ?? 0) * businessPercent).rounded())
        }
    }

    let business: String
    let range: ClosedRange<Date>
    var lines: [TaxLine: LineTotal] = [:]
    var vehicles: [VehicleSummary] = []
    /// Business transactions whose category has no Schedule C line yet.
    var needsLine: [Item] = []

    func cents(_ line: TaxLine) -> Int {
        let base = lines[line]?.deductibleCents ?? 0
        switch line {
        case .carTruck: return base + vehicles.reduce(0) { $0 + $1.line9Cents }
        case .rentVehicles: return base + vehicles.reduce(0) { $0 + $1.line20aCents }
        default: return base
        }
    }

    var grossReceipts: Int { cents(.grossReceipts) - cents(.returnsAllowances) }
    var costOfGoodsSold: Int { [TaxLine.cogsPurchases, .cogsLabor, .cogsMaterials, .cogsOther].reduce(0) { $0 + cents($1) } }
    var grossProfit: Int { grossReceipts - costOfGoodsSold }
    var grossIncome: Int { grossProfit + cents(.otherIncome) }
    var totalExpenses: Int { TaxLine.allCases.filter { $0.part == .expenses }.reduce(0) { $0 + cents($1) } }
    var netProfit: Int { grossIncome - totalExpenses }

    /// Part V detail: what makes up "Other expenses".
    var otherExpenseBreakdown: [(label: String, cents: Int)] {
        Dictionary(grouping: lines[.otherExpenses]?.items ?? [], by: { $0.category.isEmpty ? $0.payee : $0.category })
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.cents }) }
            .sorted { $0.cents > $1.cents }
    }

    @MainActor
    init(business: Business, range: ClosedRange<Date>, context: ModelContext) {
        self.business = business.name
        self.range = range
        let lower = range.lowerBound, upper = range.upperBound
        let entries = (try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.date >= lower && $0.date <= upper }))) ?? []
        let bid = business.persistentModelID

        var vehicles: [PersistentIdentifier: VehicleSummary] = [:]
        for v in business.vehicles ?? [] {
            var s = VehicleSummary(id: v.persistentModelID, name: v.name, usesStandardRate: v.usesStandardRate, placedInService: v.placedInService)
            var missing = Set<Int>()
            for t in v.trips ?? [] where range.contains(t.date) {
                switch t.kind {
                case .business:
                    s.businessTenths += t.tenthMiles
                    let year = Day.year(of: t.date)
                    if let rate = MileageRates.centsPerMile(year) {
                        s.standardMileageCents += Int((Double(t.tenthMiles) / 10 * rate).rounded())
                    } else {
                        missing.insert(year)
                    }
                case .commuting: s.commutingTenths += t.tenthMiles
                case .personal: s.personalTenths += t.tenthMiles
                }
            }
            s.missingRateYears = missing.sorted()
            let years = Set([Day.year(of: lower), Day.year(of: upper)])
            if years.count == 1, let y = years.first, let total = v.yearTotals[String(y)] { s.odometerTotalMiles = total }
            vehicles[v.persistentModelID] = s
        }

        for e in entries {
            guard !e.isVoid, !e.isSplit, e.effectiveBusiness?.persistentModelID == bid else { continue }
            let explicitLine = e.taxLine
            if e.isTransfer && explicitLine == nil { continue }
            let pct = max(0, min(100, e.businessPercent))
            let portion = Int((Double(e.amountCents) * Double(pct) / 100).rounded())
            let root = e.splitParent ?? e

            func item(_ cents: Int) -> Item {
                Item(id: e.persistentModelID, date: e.date, account: root.account?.name ?? "", payee: root.payee?.name ?? "",
                     category: e.category?.fullName ?? "", memo: e.memo ?? root.memo ?? "", cents: cents, percent: pct, vehicle: e.vehicle?.name)
            }

            // Vehicle costs feed the vehicle worksheet (line 9 / 20a) instead of a category line.
            if let v = e.vehicle, var s = vehicles[v.persistentModelID] {
                let kind = e.vehicleExpense ?? .other
                s.expenses[kind, default: 0] += -e.amountCents
                s.items.append(item(-e.amountCents))
                vehicles[v.persistentModelID] = s
                continue
            }

            guard let line = e.effectiveTaxLine else {
                needsLine.append(item(-portion))
                continue
            }
            let signed = line.part == .income ? portion : -portion
            // Returns are entered as money going out; show them positive on line 2.
            let cents = line == .returnsAllowances ? abs(portion) : signed
            lines[line, default: LineTotal(line: line, cents: 0, items: [])].cents += cents
            lines[line]?.items.append(item(cents))
        }
        self.vehicles = vehicles.values.sorted { $0.name < $1.name }
        needsLine.sort { $0.date < $1.date }
    }

    func csv() -> String {
        var out = [CSV.row(["Schedule C", business, "\(Day.string(range.lowerBound)) – \(Day.string(range.upperBound))"]), ""]
        out.append(CSV.row(["Line", "Description", "Amount"]))
        for line in TaxLine.allCases where cents(line) != 0 {
            out.append(CSV.row([line.rawValue, line.title, "\(Cents.decimal(cents(line)))"]))
        }
        out.append(CSV.row(["7", "Gross income", "\(Cents.decimal(grossIncome))"]))
        out.append(CSV.row(["28", "Total expenses", "\(Cents.decimal(totalExpenses))"]))
        out.append(CSV.row(["31", "Net profit (loss)", "\(Cents.decimal(netProfit))"]))
        for v in vehicles {
            out.append("")
            out.append(CSV.row(["Vehicle", v.name, v.usesStandardRate ? "Standard mileage rate" : "Actual expenses"]))
            out.append(CSV.row(["", "Business miles", String(format: "%.1f", Double(v.businessTenths) / 10)]))
            out.append(CSV.row(["", "Commuting miles", String(format: "%.1f", Double(v.commutingTenths) / 10)]))
            out.append(CSV.row(["", "Other miles", String(format: "%.1f", Double(v.totalTenths - v.businessTenths - v.commutingTenths) / 10)]))
            for (k, c) in v.expenses.sorted(by: { $0.key.title < $1.key.title }) {
                out.append(CSV.row(["", k.title, "\(Cents.decimal(c))"]))
            }
            out.append(CSV.row(["", "Line 9 amount", "\(Cents.decimal(v.line9Cents))"]))
        }
        out.append("")
        out.append(CSV.row(["Detail: Line", "Date", "Account", "Payee", "Category", "Memo", "Business %", "Amount"]))
        for line in TaxLine.allCases {
            for i in lines[line]?.items ?? [] {
                out.append(CSV.row([line.rawValue, Day.string(i.date), i.account, i.payee, i.category, i.memo, "\(i.percent)", "\(Cents.decimal(i.cents))"]))
            }
        }
        for v in vehicles {
            for i in v.items {
                out.append(CSV.row(["9 (\(v.name))", Day.string(i.date), i.account, i.payee, i.category, i.memo, "\(i.percent)", "\(Cents.decimal(i.cents))"]))
            }
        }
        for i in needsLine {
            out.append(CSV.row(["NEEDS LINE", Day.string(i.date), i.account, i.payee, i.category, i.memo, "\(i.percent)", "\(Cents.decimal(i.cents))"]))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
