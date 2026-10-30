import Foundation
import SwiftData

// All models follow CloudKit-compatible rules (every attribute has a default or is optional,
// no unique constraints, all relationships optional) so iCloud sync can be switched on later.
//
// Money amounts are stored as Int cents. `moneyId` links a record back to the .mny file so that
// re-importing updates records in place instead of duplicating them; records created in the app
// have `moneyId == nil` and are never touched by an import.

enum AccountKind: String, Codable, CaseIterable {
    case bank, creditCard, loan, investment, other

    var label: String {
        switch self {
        case .bank: "Bank"
        case .creditCard: "Credit Card"
        case .loan: "Loan"
        case .investment: "Investment"
        case .other: "Other"
        }
    }
}

enum ClearedStatus: String, Codable, CaseIterable {
    case uncleared, cleared, reconciled

    /// Money's register column letter.
    var marker: String {
        switch self {
        case .uncleared: ""
        case .cleared: "C"
        case .reconciled: "R"
        }
    }
}

enum CategoryKind: String, Codable {
    case income, expense
}

@Model
final class Account {
    var uuid: UUID = UUID()
    var moneyId: Int?
    var name: String = ""
    var kindRaw: String = AccountKind.bank.rawValue
    var isClosed: Bool = false
    var openingBalanceCents: Int = 0
    var openDate: Date?
    var lastReconciledDate: Date?
    var lastReconciledBalanceCents: Int?
    /// Last statement balanced in MacMoney (app-owned; Money's own values are the two above).
    var statementDate: Date?
    var statementBalanceCents: Int?
    var accountNumber: String?
    var notes: String?
    var isBusiness: Bool = false
    /// Everything in this account belongs to this business unless a transaction says otherwise.
    var business: Business?

    @Relationship(deleteRule: .cascade, inverse: \Entry.account)
    var entries: [Entry]? = []

    init(name: String, kind: AccountKind = .bank) {
        self.name = name
        self.kindRaw = kind.rawValue
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    /// Closed accounts imported from Money are kept for history and are read-only.
    var isReadOnly: Bool { isClosed }
}

@Model
final class Category {
    var uuid: UUID = UUID()
    var moneyId: Int?
    var name: String = ""
    var kindRaw: String = CategoryKind.expense.rawValue
    var isHidden: Bool = false
    var isTaxRelated: Bool = false
    var isBusiness: Bool = false
    var notes: String?
    /// Future: Schedule C line this category rolls up to (app-owned, survives re-import).
    var scheduleCLine: String?

    var parent: Category?
    @Relationship(deleteRule: .nullify, inverse: \Category.parent)
    var children: [Category]? = []

    init(name: String, kind: CategoryKind = .expense) {
        self.name = name
        self.kindRaw = kind.rawValue
    }

    var kind: CategoryKind {
        get { CategoryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    /// True for Money's two synthetic roots ("INCOME" / "EXPENSE").
    var isRoot: Bool { parent == nil }

    /// "Parent : Child" like Money, skipping the synthetic root.
    var fullName: String {
        guard let parent, !parent.isRoot else { return name }
        return "\(parent.fullName) : \(name)"
    }
}

@Model
final class Payee {
    var uuid: UUID = UUID()
    var moneyId: Int?
    var name: String = ""
    var isHidden: Bool = false
    /// Hidden/unhidden in MacMoney; wins over Money's setting on re-import. Nil follows Money.
    var hiddenOverride: Bool?
    var accountNumber: String?
    var website: String?
    var notes: String?

    init(name: String) {
        self.name = name
    }
}

@Model
final class Entry {
    var uuid: UUID = UUID()
    var moneyId: Int?
    var account: Account?
    var date: Date = Date()
    var amountCents: Int = 0
    var number: String?
    var payee: Payee?
    var category: Category?
    var memo: String?
    var statusRaw: String = ClearedStatus.uncleared.rawValue
    var dateCleared: Date?
    var isVoid: Bool = false
    /// Money's register flag — e.g. "auto bill pay is scheduled". Cleared when the entry is reconciled.
    var isFlagged: Bool = false
    /// Optional comment and action (follow-up) date on the flag, as in Money.
    var flagNote: String?
    var flagDate: Date?

    /// Split lines point at their parent; the parent carries the full amount.
    var splitParent: Entry?
    @Relationship(deleteRule: .cascade, inverse: \Entry.splitParent)
    var splits: [Entry]? = []
    var splitOrder: Int = 0

    /// Transfers: the account on the other side and the matching entry there.
    var transferAccount: Account?
    var transferPeerUUID: UUID?

    var billSeriesMoneyId: Int?

    // Business / Schedule C (app-owned; a re-import never changes these).
    /// Business this transaction belongs to. When nil, the account's business (if any) applies.
    var business: Business?
    /// Marks a transaction as personal even inside a business account.
    var isPersonal: Bool = false
    /// Overrides the category's Schedule C line.
    var taxLineRaw: String?
    /// Business share of the amount (e.g. 60 for a phone bill used 60% for business).
    var businessPercent: Int = 100
    var vehicle: Vehicle?
    var vehicleExpenseRaw: String?
    /// The bill this entry was entered from (app-side link; survives re-import).
    var billUUID: UUID?

    init(account: Account?, date: Date, amountCents: Int) {
        self.account = account
        self.date = date
        self.amountCents = amountCents
    }

    var status: ClearedStatus {
        get { ClearedStatus(rawValue: statusRaw) ?? .uncleared }
        set {
            statusRaw = newValue.rawValue
            if newValue == .reconciled { isFlagged = false }
        }
    }

    var isSplitLine: Bool { splitParent != nil }
    var isSplit: Bool { !(splits ?? []).isEmpty }
    var isTransfer: Bool { transferAccount != nil }

    /// Amount that counts toward the account balance.
    var balanceEffectCents: Int { isVoid || isSplitLine ? 0 : amountCents }

    var sortedSplits: [Entry] { (splits ?? []).sorted { $0.splitOrder < $1.splitOrder } }

    /// What to show in the register's Category column.
    var taxLine: TaxLine? {
        get { taxLineRaw.flatMap(TaxLine.init) }
        set { taxLineRaw = newValue?.rawValue }
    }

    var vehicleExpense: VehicleExpense? {
        get { vehicleExpenseRaw.flatMap(VehicleExpense.init) }
        set { vehicleExpenseRaw = newValue?.rawValue }
    }

    /// The business this transaction counts toward: its own tag, its vehicle's business, its
    /// split parent's, or its account's — unless marked personal.
    var effectiveBusiness: Business? {
        if isPersonal { return nil }
        if let business { return business }
        if let b = vehicle?.business { return b }
        if let parent = splitParent { return parent.effectiveBusiness }
        return account?.business
    }

    /// Schedule C line: explicit override, else the category's mapping.
    var effectiveTaxLine: TaxLine? {
        taxLine ?? category?.scheduleCLine.flatMap(TaxLine.init) ?? splitParent?.taxLine
    }

    var categoryDisplay: String {
        if isTransfer, let other = transferAccount { return "Transfer \(amountCents < 0 ? "to" : "from") \(other.name)" }
        if isSplit { return "Split (\(splits?.count ?? 0))" }
        return category?.fullName ?? ""
    }
}

enum RecurrenceUnit: String, Codable, CaseIterable {
    case once, week, semimonth, month, year
}

@Model
final class Bill {
    var uuid: UUID = UUID()
    var moneySeriesId: Int?
    var account: Account?
    var payee: Payee?
    var category: Category?
    var transferAccount: Account?
    var amountCents: Int = 0
    var memo: String?
    var number: String?
    var unitRaw: String = RecurrenceUnit.month.rawValue
    var every: Int = 1
    var startDate: Date?
    var nextDue: Date = Date()
    var endDate: Date?
    var remainingOccurrences: Int?
    var isActive: Bool = true
    /// Day of month monthly/yearly bills fall on (0 = use nextDue's day).
    var anchorDay: Int = 0
    /// Flag entries made from this bill (e.g. the payment is scheduled through auto bill pay).
    var flagOnEnter: Bool = false

    init(amountCents: Int, nextDue: Date) {
        self.amountCents = amountCents
        self.nextDue = nextDue
    }

    var unit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: unitRaw) ?? .month }
        set { unitRaw = newValue.rawValue }
    }

    /// Money-style frequency label ("Monthly", "Every three months", "Twice a year").
    var frequencyLabel: String {
        switch (unit, every) {
        case (.once, _): "Only once"
        case (.week, 1): "Weekly"
        case (.week, 2): "Every other week"
        case (.week, let n): "Every \(n) weeks"
        case (.semimonth, _): "Twice a month"
        case (.month, 1): "Monthly"
        case (.month, 2): "Every other month"
        case (.month, 3): "Every three months"
        case (.month, 6): "Twice a year"
        case (.month, 12): "Yearly"
        case (.month, let n): "Every \(n) months"
        case (.year, 1): "Yearly"
        case (.year, let n): "Every \(n) years"
        }
    }
}

@Model
final class ImportRecord {
    var date: Date = Date()
    var fileName: String = ""
    var sha256: String = ""
    var summary: String = ""

    init(fileName: String, sha256: String, summary: String) {
        self.fileName = fileName
        self.sha256 = sha256
        self.summary = summary
    }
}

enum Schema1 {
    static let models: [any PersistentModel.Type] = [
        Account.self, Category.self, Payee.self, Entry.self, Bill.self, ImportRecord.self,
        Business.self, Vehicle.self, MileageEntry.self, ReportPreset.self,
        Scenario.self, ScenarioItem.self,
    ]
}

/// A saved selection + filters for a list report (Payees, Deposit Sources), recalled from a menu.
@Model
final class ReportPreset {
    var uuid: UUID = UUID()
    var name: String = ""
    /// Which page it belongs to: "payees" or "depositSources".
    var kind: String = ""
    /// Selected payees by uuid (stable across re-imports), newline-separated.
    var payeeUUIDs: String = ""
    var periodRaw: String = ""
    var customFrom: Date?
    var customTo: Date?
    var search: String = ""
    var showHidden: Bool = false
    var created: Date = Date()
    var modified: Date = Date()

    init(name: String, kind: String) {
        self.name = name
        self.kind = kind
    }

    var payees: Set<UUID> {
        get { Set(payeeUUIDs.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }) }
        set { payeeUUIDs = newValue.map(\.uuidString).sorted().joined(separator: "\n") }
    }
}
