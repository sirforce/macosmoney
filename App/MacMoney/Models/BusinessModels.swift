import Foundation
import SwiftData

// Business bookkeeping for Schedule C (Profit or Loss From Business, sole proprietorship).
// Everything here is app-owned: a Money re-import never touches it.

/// Schedule C lines a transaction can roll up to.
enum TaxLine: String, CaseIterable, Codable, Identifiable {
    // Part I — Income
    case grossReceipts = "1"
    case returnsAllowances = "2"
    case otherIncome = "6"
    // Part III — Cost of goods sold
    case cogsPurchases = "36"
    case cogsLabor = "37"
    case cogsMaterials = "38"
    case cogsOther = "39"
    // Part II — Expenses
    case advertising = "8"
    case carTruck = "9"
    case commissions = "10"
    case contractLabor = "11"
    case depletion = "12"
    case depreciation = "13"
    case employeeBenefits = "14"
    case insurance = "15"
    case mortgageInterest = "16a"
    case otherInterest = "16b"
    case legalProfessional = "17"
    case office = "18"
    case pension = "19"
    case rentVehicles = "20a"
    case rentProperty = "20b"
    case repairs = "21"
    case supplies = "22"
    case taxesLicenses = "23"
    case travel = "24a"
    case meals = "24b"
    case utilities = "25"
    case wages = "26"
    case otherExpenses = "27a"
    case homeOffice = "30"
    // Not deducted on a line, but tracked for the accountant.
    case capitalPurchase = "asset"
    case notDeductible = "none"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grossReceipts: "Gross receipts or sales"
        case .returnsAllowances: "Returns and allowances"
        case .otherIncome: "Other income"
        case .cogsPurchases: "Purchases (COGS)"
        case .cogsLabor: "Cost of labor (COGS)"
        case .cogsMaterials: "Materials and supplies (COGS)"
        case .cogsOther: "Other costs (COGS)"
        case .advertising: "Advertising"
        case .carTruck: "Car and truck expenses"
        case .commissions: "Commissions and fees"
        case .contractLabor: "Contract labor"
        case .depletion: "Depletion"
        case .depreciation: "Depreciation and section 179"
        case .employeeBenefits: "Employee benefit programs"
        case .insurance: "Insurance (other than health)"
        case .mortgageInterest: "Interest: mortgage"
        case .otherInterest: "Interest: other"
        case .legalProfessional: "Legal and professional services"
        case .office: "Office expense"
        case .pension: "Pension and profit-sharing plans"
        case .rentVehicles: "Rent or lease: vehicles, machinery, equipment"
        case .rentProperty: "Rent or lease: other business property"
        case .repairs: "Repairs and maintenance"
        case .supplies: "Supplies"
        case .taxesLicenses: "Taxes and licenses"
        case .travel: "Travel"
        case .meals: "Deductible meals"
        case .utilities: "Utilities"
        case .wages: "Wages"
        case .otherExpenses: "Other expenses (Part V)"
        case .homeOffice: "Business use of home"
        case .capitalPurchase: "Equipment / asset purchase (for depreciation)"
        case .notDeductible: "Business, not deductible"
        }
    }

    var label: String {
        switch self {
        case .capitalPurchase, .notDeductible: title
        default: "Line \(rawValue) · \(title)"
        }
    }

    enum Part: String { case income = "Part I · Income", cogs = "Part III · Cost of Goods Sold", expenses = "Part II · Expenses", other = "Tracked, not deducted" }

    var part: Part {
        switch self {
        case .grossReceipts, .returnsAllowances, .otherIncome: .income
        case .cogsPurchases, .cogsLabor, .cogsMaterials, .cogsOther: .cogs
        case .capitalPurchase, .notDeductible: .other
        default: .expenses
        }
    }

    /// Share of the amount that is deductible (meals are 50%).
    var deductiblePercent: Int { self == .meals ? 50 : 100 }
}

enum VehicleExpense: String, CaseIterable, Codable, Identifiable {
    case fuel, repairs, tires, insurance, registration, parkingTolls, loanInterest, lease, washing, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fuel: "Gas & fuel"
        case .repairs: "Oil, repairs & maintenance"
        case .tires: "Tires"
        case .insurance: "Insurance"
        case .registration: "Registration & license"
        case .parkingTolls: "Parking & tolls"
        case .loanInterest: "Loan interest"
        case .lease: "Lease payments"
        case .washing: "Washing"
        case .other: "Other"
        }
    }
}

enum MileageKind: String, CaseIterable, Codable, Identifiable {
    case business, commuting, personal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@Model
final class Business {
    var uuid: UUID = UUID()
    var name: String = ""
    var ein: String?
    var notes: String?

    @Relationship(deleteRule: .nullify, inverse: \Account.business)
    var accounts: [Account]? = []
    @Relationship(deleteRule: .nullify, inverse: \Entry.business)
    var entries: [Entry]? = []
    @Relationship(deleteRule: .nullify, inverse: \Vehicle.business)
    var vehicles: [Vehicle]? = []

    init(name: String) { self.name = name }
}

@Model
final class Vehicle {
    var uuid: UUID = UUID()
    var name: String = ""
    var business: Business?
    var placedInService: Date?
    /// "standard" (IRS mileage rate) or "actual" (expenses × business-use %).
    var methodRaw: String = "standard"
    var isActive: Bool = true
    /// Total miles driven per year from the odometer ("2026": 14250). Falls back to the log total.
    var yearTotalsJSON: String = ""

    @Relationship(deleteRule: .cascade, inverse: \MileageEntry.vehicle)
    var trips: [MileageEntry]? = []
    @Relationship(deleteRule: .nullify, inverse: \Entry.vehicle)
    var entries: [Entry]? = []

    init(name: String) { self.name = name }

    var usesStandardRate: Bool {
        get { methodRaw == "standard" }
        set { methodRaw = newValue ? "standard" : "actual" }
    }

    var yearTotals: [String: Int] {
        get { (try? JSONDecoder().decode([String: Int].self, from: Data(yearTotalsJSON.utf8))) ?? [:] }
        set { yearTotalsJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self) }
    }
}

@Model
final class MileageEntry {
    var uuid: UUID = UUID()
    var vehicle: Vehicle?
    var date: Date = Date()
    /// Miles in tenths (123.4 mi = 1234), exact like cents.
    var tenthMiles: Int = 0
    var kindRaw: String = MileageKind.business.rawValue
    var purpose: String = ""

    init(date: Date, tenthMiles: Int, kind: MileageKind, purpose: String) {
        self.date = date
        self.tenthMiles = tenthMiles
        self.kindRaw = kind.rawValue
        self.purpose = purpose
    }

    var kind: MileageKind { MileageKind(rawValue: kindRaw) ?? .business }
}

/// IRS standard mileage rates in cents per mile, editable in the app (the IRS sets a new rate
/// each year; check irs.gov and update when it's announced).
enum MileageRates {
    static let defaultsKey = "mileageRates"
    // 2022 had two rates (58.5¢ Jan–Jun, 62.5¢ Jul–Dec), so it is left for the user to enter.
    static let builtIn: [Int: Double] = [2021: 56, 2023: 65.5, 2024: 67, 2025: 70]

    static var all: [Int: Double] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let saved = try? JSONDecoder().decode([Int: Double].self, from: data) else { return builtIn }
            return builtIn.merging(saved) { _, new in new }
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) }
    }

    static func centsPerMile(_ year: Int) -> Double? { all[year] }
}
