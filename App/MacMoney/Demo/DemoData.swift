import Foundation
import SwiftData

/// Sample data for `--demo`: an invented household with about five years of history, ending today.
///
/// Nothing here comes from a real person. People, employers, clients and shops are made up, and
/// the amounts come from a seeded random generator, so every run produces the same household
/// (shifted so that it always ends today). It covers what a typical home sees: paychecks, a
/// mortgage, a car loan, two credit cards, savings, a freelance business with its own accounts,
/// and a small side business run out of the personal accounts, so that every screen has
/// something to show.
@MainActor
enum DemoData {
    static func seedIfEmpty(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Account>())) ?? 0
        guard count == 0 else { return }
        DemoBuilder(context: context, today: Day.today, downloads: DemoMode.downloadsFolder).build()
    }
}

struct DemoRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
final class DemoBuilder {
    let ctx: ModelContext
    let today: Date
    /// Where the sample bank downloads are written.
    let downloads: URL
    private let defaults: UserDefaults
    let firstYear: Int
    var rng = DemoRandom(state: 20_260_101)

    private var payees: [String: Payee] = [:]
    private var cats: [String: Category] = [:]
    /// Running balance per account (by uuid) as entries are added.
    private var bal: [UUID: Int] = [:]
    private var checkNumber = 1041
    private var businessCheckNumber = 2001
    private var sequence = 0

    private var checking: Account!, savings: Account!, visa: Account!, bizChecking: Account!, bizVisa: Account!
    private var autoLoan: Account!, mortgage: Account!, brokerage: Account!, oldChecking: Account!
    private var studio: Business!, prints: Business!
    private var car: Vehicle!
    private var printsStart: Date!

    /// A card transaction as the bank reports it.
    private struct Charge {
        var date: Date
        var raw: String
        var cents: Int
        var seq: Int
        /// Already in the register (a payment entered from checking, a charge typed in by hand),
        /// so it only appears in the downloads.
        var fileOnly = false
    }

    private struct Rule {
        var category: String
        var business: Business?
        var parking = false
    }

    private final class Card {
        let account: Account
        let last4: String
        var charges: [Charge] = []
        var monthTotal: [Int: Int] = [:]
        var paid = 0
        init(_ account: Account, last4: String) { self.account = account; self.last4 = last4 }
    }

    private var personalCard: Card!, businessCard: Card!
    private var rules: [String: Rule] = [:]
    private var pendingPurchases: [(purchase: Purchase, account: Account)] = []

    init(context: ModelContext, today: Date, downloads: URL, defaults: UserDefaults = .standard) {
        ctx = context
        self.defaults = defaults
        self.today = today
        self.downloads = downloads
        firstYear = Day.year(of: today) - 4
    }

    // MARK: - Small helpers

    private func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &rng) }
    private func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    private func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }

    /// A dollar amount between `lo` and `hi`, in cents.
    private func money(_ lo: Double, _ hi: Double, scale: Double = 1) -> Int {
        Int((Double.random(in: lo...hi, using: &rng) * scale * 100).rounded())
    }

    /// How many times something that happens `rate` times a month happens this month.
    private func times(_ rate: Double) -> Int {
        let base = Int(rate)
        var n = base + (chance(rate - Double(base)) ? 1 : 0)
        if rate >= 2 { n += int(-1...1) }
        return max(0, n)
    }

    private func daysIn(_ y: Int, _ m: Int) -> Int {
        Day.calendar.range(of: .day, in: .month, for: Day.date(year: y, month: m, day: 1))!.count
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { Day.date(year: y, month: m, day: min(max(1, d), daysIn(y, m))) }
    private func randomDay(_ y: Int, _ m: Int) -> Date { day(y, m, int(1...daysIn(y, m))) }
    private func ago(_ days: Int) -> Date { Day.adding(.day, -days, to: today) }
    private func parts(_ d: Date) -> (y: Int, m: Int, d: Int) {
        let c = Day.calendar.dateComponents([.year, .month, .day], from: d)
        return (c.year!, c.month!, c.day!)
    }

    private func payee(_ name: String) -> Payee {
        if let p = payees[name.lowercased()] { return p }
        let p = Payee(name: name)
        ctx.insert(p)
        payees[name.lowercased()] = p
        return p
    }

    private func category(_ name: String) -> Category {
        guard let c = cats[name] else { fatalError("Demo data: no category named \(name)") }
        return c
    }

    @discardableResult
    private func add(_ account: Account, _ date: Date, _ cents: Int, _ payeeName: String?, _ categoryName: String? = nil,
                     memo: String? = nil, num: String? = nil, future: Bool = false) -> Entry? {
        guard date <= today || future else { return nil }
        let e = Entry(account: account, date: date, amountCents: cents)
        ctx.insert(e)
        e.payee = payeeName.map(payee)
        e.category = categoryName.map(category)
        e.memo = memo
        e.number = num
        bal[account.uuid, default: 0] += cents
        return e
    }

    /// Moves `cents` (positive) from one account to another, as the two matching entries.
    @discardableResult
    private func transfer(from: Account, to: Account, _ date: Date, _ cents: Int, _ payeeName: String?,
                          memo: String? = nil, future: Bool = false) -> Entry? {
        guard cents > 0, let out = add(from, date, -cents, payeeName, memo: memo, future: future),
              let into = add(to, date, cents, payeeName, memo: memo, future: future) else { return nil }
        out.transferAccount = to
        into.transferAccount = from
        out.transferPeerUUID = into.uuid
        into.transferPeerUUID = out.uuid
        return out
    }

    private func charge(_ card: Card, _ date: Date, _ raw: String, _ cents: Int) {
        guard date < today else { return }
        sequence += 1
        card.charges.append(Charge(date: date, raw: raw, cents: cents, seq: sequence))
        let p = parts(date)
        card.monthTotal[p.y * 12 + p.m, default: 0] += cents
    }

    // MARK: - Build

    func build() {
        makeCategories()
        makeAccountsAndBusinesses()
        makeRules()
        addHandEntered()

        let end = parts(today)
        let paydays = makePaydays()
        var y = firstYear, m = 1
        while (y, m) <= (end.y, end.m) {
            month(y, m, paydays: paydays)
            m += 1
            if m > 12 { m = 1; y += 1 }
        }

        closeOldChecking()
        postCards()
        enterAhead()
        setStatuses()
        flagAFew()
        makeMileage()
        makeAssets()
        makeBills(paydays: paydays)
        makeScenarios()
        makePresets()
        linkPurchases()

        // Start each account high enough that it never ran dry along the way.
        settleOpeningBalance(checking, floor: 1_400_00)
        settleOpeningBalance(bizChecking, floor: 1_000_00)
        settleOpeningBalance(savings, floor: 2_500_00)
        for a in [checking!, savings!, visa!, bizChecking!, bizVisa!, autoLoan!, mortgage!, brokerage!] { setStatement(a) }

        let settings = AppSettings.current(in: ctx, defaults: defaults)
        settings.mileageRates = [firstYear: 58.5, Day.year(of: today): 72.5]
        settings.purchasesReviewFrom = Day.startOfYear(today)
        settings.purchasesBusinessUUID = studio.uuid
        try? ctx.save()
    }

    // MARK: - Categories

    private func makeCategories() {
        let income = Category(name: "INCOME", kind: .income)
        let expense = Category(name: "EXPENSE", kind: .expense)
        ctx.insert(income)
        ctx.insert(expense)

        func group(_ root: Category, _ name: String, _ children: [(String, TaxLine?)] = [], line: TaxLine? = nil, business: Bool = false) {
            let g = Category(name: name, kind: root.kind)
            ctx.insert(g)
            g.parent = root
            g.isBusiness = business
            g.scheduleCLine = line?.rawValue
            cats[name] = g
            for (child, childLine) in children {
                let c = Category(name: child, kind: root.kind)
                ctx.insert(c)
                c.parent = g
                c.isBusiness = business
                c.isTaxRelated = business || childLine != nil
                c.scheduleCLine = childLine?.rawValue
                cats["\(name) : \(child)"] = c
            }
        }

        group(income, "Wages & Salary", [("Net Pay", nil), ("Bonus", nil)])
        group(income, "Business Income", [("Design Services", .grossReceipts), ("Product Sales", .grossReceipts)], business: true)
        group(income, "Interest Income")
        group(income, "Investment Income", [("Dividends", nil)])
        group(income, "Other Income", [("Tax Refund", nil), ("Gifts Received", nil), ("Rebates", nil)])

        group(expense, "Housing", [("Property Tax", nil), ("HOA Dues", nil), ("Home Insurance", nil), ("Repairs & Maintenance", nil), ("Furnishings", nil)])
        group(expense, "Utilities", [("Electric", nil), ("Water & Sewer", nil), ("Internet", .utilities), ("Mobile Phone", .utilities)])
        group(expense, "Groceries")
        group(expense, "Dining Out", [("Restaurants", nil), ("Coffee", nil)])
        group(expense, "Auto", [("Fuel", nil), ("Insurance", nil), ("Maintenance", nil), ("Registration", nil), ("Purchase", nil)])
        group(expense, "Healthcare", [("Doctor", nil), ("Dental", nil), ("Pharmacy", nil)])
        group(expense, "Insurance", [("Life", nil)])
        group(expense, "Childcare & Education", [("Preschool", nil), ("After-School", nil), ("Activities", nil)])
        group(expense, "Entertainment", [("Streaming", nil), ("Movies & Events", nil), ("Toys & Games", nil)])
        group(expense, "Shopping", [("Online", nil), ("Clothing", nil), ("Household", nil)])
        group(expense, "Travel", [("Airfare", nil), ("Lodging", nil), ("Rental Car", nil)])
        group(expense, "Pets", [("Vet", nil), ("Food & Supplies", nil)])
        group(expense, "Personal Care")
        group(expense, "Fitness")
        group(expense, "Charity")
        group(expense, "Taxes", [("Federal Estimated", nil), ("State Estimated", nil)])
        group(expense, "Interest Expense", [("Mortgage", nil), ("Auto Loan", nil)])
        group(expense, "Cash & Miscellaneous")
        group(expense, "Business", [
            ("Advertising", .advertising), ("Software & Subscriptions", .office), ("Office Supplies", .supplies),
            ("Contract Labor", .contractLabor), ("Professional Fees", .legalProfessional), ("Insurance", .insurance),
            ("Licenses & Fees", .taxesLicenses), ("Travel", .travel), ("Meals", .meals), ("Equipment", .capitalPurchase),
            ("Materials", .cogsMaterials), ("Shipping", .otherExpenses), ("Education", .otherExpenses),
        ], business: true)
    }

    // MARK: - Accounts and businesses

    private func makeAccountsAndBusinesses() {
        let opened = Day.date(year: firstYear, month: 1, day: 1)

        func account(_ name: String, _ kind: AccountKind, opening: Int = 0, number: String? = nil, open: Date? = nil) -> Account {
            let a = Account(name: name, kind: kind)
            ctx.insert(a)
            a.openingBalanceCents = opening
            a.openDate = open ?? opened
            a.accountNumber = number
            bal[a.uuid] = opening
            return a
        }

        checking = account("Joint Checking", .bank, opening: 4_200_00, number: "2075")
        savings = account("Emergency Savings", .bank, opening: 26_000_00, number: "9310")
        visa = account("Rewards Visa", .creditCard, number: "4417")
        bizChecking = account("Studio Checking", .bank, opening: 3_800_00, number: "6628")
        bizVisa = account("Studio Visa", .creditCard, number: "8842")
        autoLoan = account("Auto Loan", .loan, opening: -27_400_00, open: Day.date(year: firstYear + 1, month: 6, day: 10))
        mortgage = account("Mortgage", .loan, opening: -298_500_00)
        brokerage = account("Index Fund", .investment, opening: 11_250_00)
        oldChecking = account("Credit Union Checking", .bank, opening: 1_846_17)
        autoLoan.notes = "60 months at 5.9%, the family crossover."
        mortgage.notes = "30-year fixed at 3.25%."
        for (i, a) in [checking!, savings!, visa!, bizChecking!, bizVisa!, autoLoan!, mortgage!, brokerage!].enumerated() { a.sidebarOrder = i }

        studio = Business(name: "Juniper Lane Studio")
        studio.notes = "Freelance brand and web design. Sole proprietor."
        ctx.insert(studio)
        prints = Business(name: "Tidepool Prints")
        prints.notes = "Art prints sold online. Runs through the personal accounts."
        ctx.insert(prints)
        printsStart = Day.date(year: Day.year(of: today) - 1, month: 3, day: 1)
        bizChecking.business = studio
        bizVisa.business = studio
        bizChecking.isBusiness = true
        bizVisa.isBusiness = true

        car = Vehicle(name: "Family Crossover")
        ctx.insert(car)
        car.business = studio
        car.placedInService = Day.date(year: firstYear + 1, month: 6, day: 10)
        car.usesStandardRate = true

        personalCard = Card(visa, last4: "4417")
        businessCard = Card(bizVisa, last4: "8842")
    }

    // MARK: - Card merchants

    private struct Merchant {
        let raw: String
        let category: String
        let rate: Double
        let lo: Double
        let hi: Double
    }

    private let personalMerchants: [Merchant] = [
        Merchant(raw: "GREENFIELD MARKET #0412", category: "Groceries", rate: 6, lo: 38, hi: 165),
        Merchant(raw: "HARVEST CO-OP", category: "Groceries", rate: 2, lo: 22, hi: 80),
        Merchant(raw: "BULKBARN WHOLESALE #218", category: "Groceries", rate: 1.4, lo: 140, hi: 380),
        Merchant(raw: "TST* THE COPPER KETTLE", category: "Dining Out : Restaurants", rate: 1.2, lo: 38, hi: 96),
        Merchant(raw: "SQ *JUNIPER COFFEE", category: "Dining Out : Coffee", rate: 5, lo: 4.25, hi: 13.5),
        Merchant(raw: "LUNA TAQUERIA", category: "Dining Out : Restaurants", rate: 2, lo: 14, hi: 48),
        Merchant(raw: "GOLDEN BOWL NOODLES", category: "Dining Out : Restaurants", rate: 1.2, lo: 18, hi: 55),
        Merchant(raw: "SLICE HOUSE PIZZA", category: "Dining Out : Restaurants", rate: 1.5, lo: 22, hi: 46),
        Merchant(raw: "SUMMIT FUEL #2291", category: "Auto : Fuel", rate: 3.5, lo: 31, hi: 64),
        Merchant(raw: "WELLSPRING PHARMACY #77", category: "Healthcare : Pharmacy", rate: 1.2, lo: 8, hi: 62),
        Merchant(raw: "TIMBERLINE HARDWARE", category: "Housing : Repairs & Maintenance", rate: 1.2, lo: 12, hi: 190),
        Merchant(raw: "NORTHTRAIL OUTFITTERS", category: "Shopping : Clothing", rate: 0.5, lo: 35, hi: 180),
        Merchant(raw: "BRIGHTSIDE TOYS", category: "Entertainment : Toys & Games", rate: 0.4, lo: 12, hi: 70),
        Merchant(raw: "PAWS & CLAWS VET", category: "Pets : Vet", rate: 0.25, lo: 85, hi: 340),
        Merchant(raw: "PETPANTRY", category: "Pets : Food & Supplies", rate: 1, lo: 28, hi: 75),
        Merchant(raw: "CEDAR FAMILY DENTAL", category: "Healthcare : Dental", rate: 0.2, lo: 60, hi: 310),
        Merchant(raw: "LAKESIDE PEDIATRICS", category: "Healthcare : Doctor", rate: 0.3, lo: 30, hi: 60),
        Merchant(raw: "SHEAR DELIGHT SALON", category: "Personal Care", rate: 0.6, lo: 32, hi: 95),
        Merchant(raw: "ORPHEUM CINEMAS", category: "Entertainment : Movies & Events", rate: 0.6, lo: 24, hi: 58),
        Merchant(raw: "MIDAS VALLEY AUTO CARE", category: "Auto : Maintenance", rate: 0.2, lo: 68, hi: 420),
    ]

    private func makeRules() {
        for m in personalMerchants { rules[m.raw] = Rule(category: m.category) }
        rules["STREAMLY.COM"] = Rule(category: "Entertainment : Streaming")
        rules["TUNEBOX MUSIC"] = Rule(category: "Entertainment : Streaming")
        rules["IRONWORKS FITNESS"] = Rule(category: "Fitness")
        rules["ALPINE AIR"] = Rule(category: "Travel : Airfare")
        rules["SEABREEZE INN"] = Rule(category: "Travel : Lodging")
        rules["COASTLINE CAR RENTAL"] = Rule(category: "Travel : Rental Car")
        rules["INKWELL PRINT LAB"] = Rule(category: "Business : Materials", business: prints)
        rules["PARCELPOST SHIPPING"] = Rule(category: "Business : Shipping", business: prints)
        // Studio card: the account belongs to the business, so the category's line does the rest.
        rules["PIXELFORGE CREATIVE SUITE"] = Rule(category: "Business : Software & Subscriptions")
        rules["CLOUDNEST HOSTING"] = Rule(category: "Business : Software & Subscriptions")
        rules["FONTFOUNDRY PRO ANNUAL"] = Rule(category: "Business : Software & Subscriptions")
        rules["LINKBOARD ADS"] = Rule(category: "Business : Advertising")
        rules["PAPERTRAIL OFFICE SUPPLY"] = Rule(category: "Business : Office Supplies")
        rules["TST* THE COPPER KETTLE - CLIENT"] = Rule(category: "Business : Meals")
        rules["SQ *JUNIPER COFFEE - CLIENT"] = Rule(category: "Business : Meals")
        rules["ALPINE AIR - DESIGNCONF"] = Rule(category: "Business : Travel")
        rules["HOTEL MERIDIAN"] = Rule(category: "Business : Travel")
        rules["DESIGNCONF REGISTRATION"] = Rule(category: "Business : Education")
        rules["KEYSTONE CAMERA & VIDEO"] = Rule(category: "Business : Equipment")
        rules["CITYPARK GARAGE"] = Rule(category: "Auto : Fuel", parking: true)
    }

    private func rule(for raw: String) -> Rule? {
        if raw.hasPrefix("AMAZON") { return Rule(category: "Shopping : Online") }
        return rules[raw]
    }

    // MARK: - One month

    private func makePaydays() -> [Date] {
        var d = Day.date(year: firstYear, month: 1, day: 1)
        while Day.calendar.component(.weekday, from: d) != 6 { d = Day.adding(.day, 1, to: d) }
        let last = Day.adding(.year, 1, to: today)
        var out: [Date] = []
        while d <= last { out.append(d); d = Day.adding(.day, 14, to: d) }
        return out
    }

    private func month(_ y: Int, _ m: Int, paydays: [Date]) {
        let yearsIn = Double(y - firstYear) + Double(m - 1) / 12
        let inflation = 1 + 0.04 * yearsIn
        let key = y * 12 + m

        // Mortgage: interest is charged, then the payment arrives.
        add(mortgage, day(y, m, 1), -Int((Double(-bal[mortgage.uuid]!) * 0.0325 / 12).rounded()), "Northwind Home Loans", "Interest Expense : Mortgage", memo: "Interest charged")
        transfer(from: checking, to: mortgage, day(y, m, 1), 1_412_57, "Northwind Home Loans", memo: "Mortgage payment")

        // Car bought in June of the second year: down payment from savings, then the loan.
        if y == firstYear + 1 && m == 6 {
            transfer(from: savings, to: checking, day(y, m, 8), 6_500_00, "Savings Transfer", memo: "Car down payment")
            checkNumber += 1
            add(checking, day(y, m, 10), -6_500_00, "Cascade Auto Sales", "Auto : Purchase", memo: "Down payment, family crossover", num: String(checkNumber))
        }
        if (y, m) > (firstYear + 1, 6) {
            add(autoLoan, day(y, m, 15), -Int((Double(-bal[autoLoan.uuid]!) * 0.059 / 12).rounded()), "Cascade Auto Finance", "Interest Expense : Auto Loan", memo: "Interest charged")
            transfer(from: checking, to: autoLoan, day(y, m, 15), 528_31, "Cascade Auto Finance", memo: "Car payment")
        }

        // Paychecks, every other Friday, with a raise each January and a December bonus.
        let net = Int((2_340_00 * pow(1.035, Double(y - firstYear))).rounded())
        for p in paydays where parts(p).y == y && parts(p).m == m {
            add(checking, p, net, "Larkspur Medical Group", "Wages & Salary : Net Pay", memo: "Payroll", num: "DEP")
        }
        if m == 12 { add(checking, day(y, m, 12), money(1_800, 2_600), "Larkspur Medical Group", "Wages & Salary : Bonus", memo: "Year-end bonus", num: "DEP") }

        // Household bills paid from checking.
        let season = [1.45, 1.35, 1.1, 0.85, 0.8, 1.0, 1.3, 1.35, 1.0, 0.8, 0.95, 1.3][m - 1]
        add(checking, day(y, m, 12), -money(96, 118, scale: season * inflation), "Cascade Power & Light", "Utilities : Electric", num: "EFT")
        if (y, m) != (parts(today).y, parts(today).m) {   // this month's is still unpaid, for the overdue example
            add(checking, day(y, m, 18), -money(62, 88, scale: inflation), "Riverbend Water & Sewer", "Utilities : Water & Sewer", num: "EFT")
        }
        if let e = add(checking, day(y, m, 5), y < firstYear + 3 ? -79_99 : -84_99, "FiberLink Internet", "Utilities : Internet", num: "EFT") {
            e.business = studio
            e.businessPercent = 40
        }
        if let e = add(checking, day(y, m, 9), -Int((138_40 * inflation).rounded()), "Clearwave Mobile", "Utilities : Mobile Phone", num: "EFT") {
            e.business = studio
            e.businessPercent = 50
        }
        add(checking, day(y, m, 3), -46_20, "Beacon Life Insurance", "Insurance : Life", num: "EFT")
        add(checking, day(y, m, 16), -35_00, "Regional Food Bank", "Charity", memo: "Monthly gift", num: "EFT")
        if m == 2 || m == 8 { add(checking, day(y, m, 15), -money(690, 735, scale: inflation), "Evergreen Mutual Insurance", "Auto : Insurance", memo: "6-month auto policy", num: "EFT") }
        if m == 3 { add(checking, day(y, m, 20), -money(1_420, 1_480, scale: inflation), "Evergreen Mutual Insurance", "Housing : Home Insurance", memo: "Annual homeowners policy", num: "EFT") }
        if m == 4 || m == 10 { add(checking, day(y, m, 10), -money(2_120, 2_180, scale: inflation), "Pine County Tax Collector", "Housing : Property Tax", num: "EFT") }
        if m % 3 == 1 {
            checkNumber += 1
            add(checking, day(y, m, 7), -285_00, "Maple Ridge HOA", "Housing : HOA Dues", memo: "Quarterly dues", num: String(checkNumber))
        }
        if [1, 4, 6, 9].contains(m) {
            add(checking, day(y, m, 15), -Int(2_300_00 * inflation / 100_00) * 100_00, "U.S. Treasury", "Taxes : Federal Estimated", memo: "Estimated tax", num: "EFT")
            add(checking, day(y, m, 15), -Int(580_00 * inflation / 100_00) * 100_00, "State Department of Revenue", "Taxes : State Estimated", memo: "Estimated tax", num: "EFT")
        }
        if m == 3 && y <= firstYear + 2 { add(checking, day(y, m, 24), money(640, 1_180), "U.S. Treasury", "Other Income : Tax Refund", memo: "Federal refund", num: "DEP") }

        // Preschool until the summer of year three, then an after-school club in school months.
        if (y, m) <= (firstYear + 2, 8) {
            checkNumber += 1
            add(checking, day(y, m, 2), -1_050_00, "Little Sprouts Preschool", "Childcare & Education : Preschool", memo: "Tuition", num: String(checkNumber))
        } else if ![6, 7, 8].contains(m) {
            add(checking, day(y, m, 2), -310_00, "Cedar Hollow After-School Club", "Childcare & Education : After-School", num: "EFT")
        }
        for _ in 0..<times(1.4) {
            add(checking, randomDay(y, m), -pick([60_00, 80_00, 100_00, 100_00, 140_00, 200_00]), "Cash Withdrawal", "Cash & Miscellaneous", num: "ATM")
        }
        if chance(0.12) { add(checking, randomDay(y, m), pick([50_00, 100_00, 150_00, 250_00]), "Mobile Check Deposit", "Other Income : Gifts Received", memo: "Birthday check from Grandma", num: "DEP") }
        // A furnace in the third winter, paid from savings.
        if y == firstYear + 2 && m == 11 {
            transfer(from: savings, to: checking, day(y, m, 12), 5_800_00, "Savings Transfer", memo: "Furnace replacement")
            checkNumber += 1
            add(checking, day(y, m, 14), -5_850_00, "Hearthstone Heating & Air", "Housing : Repairs & Maintenance", memo: "New furnace, installed", num: String(checkNumber))
        }
        if m == 5 {
            checkNumber += 1
            if let e = add(checking, day(y, m, 21), -4_38_00, "Cedar Hollow Parks & Rec", "Childcare & Education : Activities", memo: "Summer camp deposit", num: String(checkNumber)),
               y == firstYear + 1 {
                e.isVoid = true          // one voided check, written out wrong
                bal[checking.uuid]! += 4_38_00
                checkNumber += 1
                add(checking, day(y, m, 22), -4_83_00, "Cedar Hollow Parks & Rec", "Childcare & Education : Activities", memo: "Summer camp deposit (replaces voided check)", num: String(checkNumber))
            }
        }

        // Saving and investing.
        transfer(from: checking, to: savings, day(y, m, 4), 400_00, "Savings Transfer", memo: "Monthly savings")
        transfer(from: checking, to: brokerage, day(y, m, 6), 350_00, "Summit Ridge Investments", memo: "Monthly investment")
        if m % 3 == 0 { add(brokerage, day(y, m, 28), money(38, 92, scale: inflation), "Summit Ridge Investments", "Investment Income : Dividends", memo: "Dividend reinvested") }

        personalCardMonth(y, m, inflation: inflation)
        studioMonth(y, m, inflation: inflation)
        printsMonth(y, m)

        // Each card is paid in full on the 20th, for what was spent the month before.
        transferCardPayment(personalCard, from: checking, day(y, m, 20), before: key, "Rewards Visa")
        transferCardPayment(businessCard, from: bizChecking, day(y, m, 18), before: key, "Studio Visa")

        // Month end: the studio pays its owner, savings earns interest, and extra cash moves to savings.
        let last = day(y, m, 31)
        guard last <= today else { return }
        let draw = (bal[bizChecking.uuid]! - 3_200_00) / 250_00 * 250_00
        if draw >= 500_00 { transfer(from: bizChecking, to: checking, day(y, m, 27), draw, "Owner Draw", memo: "Juniper Lane Studio draw") }
        let rate = y == firstYear ? 0.006 : (y <= firstYear + 2 ? 0.042 : 0.036)
        add(savings, last, Int((Double(bal[savings.uuid]!) * rate / 12).rounded()), "Interest Earned", "Interest Income", num: "INT")
        let extra = bal[checking.uuid]! - 7_000_00
        if extra >= 2_500_00 {
            transfer(from: checking, to: savings, last, extra / 500_00 * 500_00, "Savings Transfer", memo: "Extra to savings")
        } else if bal[checking.uuid]! < 2_200_00 && bal[savings.uuid]! > 6_000_00 {
            transfer(from: savings, to: checking, last, 2_500_00, "Savings Transfer", memo: "Top up checking")
        }
    }

    /// Pays everything charged before this month that hasn't been paid yet.
    private func transferCardPayment(_ card: Card, from: Account, _ date: Date, before key: Int, _ name: String) {
        let cents = -card.monthTotal.filter { $0.key < key }.values.reduce(0, +) - card.paid
        guard transfer(from: from, to: card.account, date, cents, "\(name) Payment", memo: "Statement balance, paid in full") != nil else { return }
        card.paid += cents
        sequence += 1
        card.charges.append(Charge(date: date, raw: "AUTOMATIC PAYMENT - THANK YOU", cents: cents, seq: sequence, fileOnly: true))
    }

    private func personalCardMonth(_ y: Int, _ m: Int, inflation: Double) {
        let c = personalCard!
        for merchant in personalMerchants {
            let holiday = m == 12 && merchant.category.hasPrefix("Entertainment : Toys") ? 4.0 : 1.0
            for _ in 0..<times(merchant.rate * holiday) {
                charge(c, randomDay(y, m), merchant.raw, -money(merchant.lo, merchant.hi, scale: inflation))
            }
        }
        charge(c, day(y, m, 8), "STREAMLY.COM", y < firstYear + 2 ? -15_49 : (y < firstYear + 4 ? -17_99 : -19_99))
        charge(c, day(y, m, 14), "TUNEBOX MUSIC", y < firstYear + 3 ? -10_99 : -11_99)
        charge(c, day(y, m, 1), "IRONWORKS FITNESS", -42_00)
        if m == 7 {   // summer trip
            charge(c, day(y, 5, int(8...24)), "ALPINE AIR", -money(1_240, 1_890, scale: inflation))
            charge(c, day(y, m, int(12...16)), "SEABREEZE INN", -money(980, 1_460, scale: inflation))
            charge(c, day(y, m, int(12...16)), "COASTLINE CAR RENTAL", -money(260, 410, scale: inflation))
        }
        if m == 11 { charge(c, day(y, m, int(2...9)), "ALPINE AIR", -money(620, 940, scale: inflation)) }   // holidays with family
        for _ in 0..<times(3) { amazonOrder(randomDay(y, m)) }
        if randomDay(y, m) >= printsStart {
            for _ in 0..<times(1.3) { charge(c, randomDay(y, m), "INKWELL PRINT LAB", -money(38, 165)) }
            for _ in 0..<times(2.2) { charge(c, randomDay(y, m), "PARCELPOST SHIPPING", -money(6, 31)) }
        }
    }

    private func studioMonth(_ y: Int, _ m: Int, inflation: Double) {
        let design = "Business Income : Design Services"
        // Clients. The retainer grows; project work comes and goes.
        let retainer = y < firstYear + 2 ? 1_800_00 : (y < firstYear + 4 ? 2_200_00 : 2_600_00)
        add(bizChecking, day(y, m, 5), retainer, "Harbor & Pine Outfitters", design, memo: "Monthly retainer", num: "DEP")
        if chance(0.4) { add(bizChecking, randomDay(y, m), int(9...24) * 100_00, "Blue Heron Dental", design, memo: pick(["Website refresh", "Patient brochure", "Signage package", "Social templates"]), num: "DEP") }
        if m % 3 == 2 { add(bizChecking, day(y, m, 20), 2_750_00, "Northgate Community Foundation", design, memo: "Quarterly newsletter and annual report", num: "DEP") }
        if y >= firstYear + 2 && chance(0.4) { add(bizChecking, randomDay(y, m), int(12...36) * 100_00, "Tamarack Brewing Co.", design, memo: pick(["Seasonal label series", "Taproom menu boards", "Packaging mockups", "Brand guide update"]), num: "DEP") }
        if y >= firstYear + 3 && chance(0.3) { add(bizChecking, randomDay(y, m), int(6...18) * 100_00, "Wren & Finch Books", design, memo: pick(["Book cover", "Catalog layout", "Event posters"]), num: "DEP") }

        // Paid from the business account.
        if chance(0.45) {
            businessCheckNumber += 1
            add(bizChecking, randomDay(y, m), -int(3...14) * 100_00, "Marlowe Illustration", "Business : Contract Labor", memo: "Illustration, subcontract", num: String(businessCheckNumber))
        }
        if m == 3 { add(bizChecking, day(y, m, 11), -money(620, 690, scale: inflation), "Tallyworks CPA", "Business : Professional Fees", memo: "Tax preparation", num: "EFT") }
        if m == 1 { add(bizChecking, day(y, m, 22), -money(540, 580, scale: inflation), "Evergreen Mutual Insurance", "Business : Insurance", memo: "Professional liability, annual", num: "EFT") }
        if m == 2 { add(bizChecking, day(y, m, 3), -125_00, "State Business Registry", "Business : Licenses & Fees", memo: "Annual registration", num: "EFT") }

        // Studio card.
        let c = businessCard!
        charge(c, day(y, m, 3), "PIXELFORGE CREATIVE SUITE", y < firstYear + 3 ? -54_99 : -59_99)
        charge(c, day(y, m, 11), "CLOUDNEST HOSTING", -24_00)
        if m == 1 { charge(c, day(y, m, 19), "FONTFOUNDRY PRO ANNUAL", -199_00) }
        if chance(0.55) { charge(c, randomDay(y, m), "LINKBOARD ADS", -money(45, 280)) }
        for _ in 0..<times(1.1) { charge(c, randomDay(y, m), "PAPERTRAIL OFFICE SUPPLY", -money(14, 120, scale: inflation)) }
        for _ in 0..<times(0.8) { charge(c, randomDay(y, m), "TST* THE COPPER KETTLE - CLIENT", -money(42, 118, scale: inflation)) }
        for _ in 0..<times(1.2) { charge(c, randomDay(y, m), "SQ *JUNIPER COFFEE - CLIENT", -money(9, 24)) }
        if (y, m) > (firstYear + 1, 6) { for _ in 0..<times(1.6) { charge(c, randomDay(y, m), "CITYPARK GARAGE", -pick([8_00, 12_00, 12_00, 18_00, 24_00])) } }
        if m == 9 {   // the yearly conference
            charge(c, day(y, 7, int(6...20)), "DESIGNCONF REGISTRATION", -Int(695_00 * inflation))
            charge(c, day(y, 8, int(3...18)), "ALPINE AIR - DESIGNCONF", -money(380, 560, scale: inflation))
            charge(c, day(y, m, int(18...22)), "HOTEL MERIDIAN", -money(720, 940, scale: inflation))
        }
    }

    private func printsMonth(_ y: Int, _ m: Int) {
        for d in [day(y, m, 8), day(y, m, 22)] where d >= printsStart {
            let holiday = m >= 11 ? 2.2 : 1.0
            if let e = add(checking, d, money(85, 420, scale: holiday), "Craftfair Marketplace", "Business Income : Product Sales", memo: "Shop payout", num: "DEP") {
                e.business = prints
            }
        }
    }

    /// The credit union account everything started in: moved out and closed in the first spring.
    private func closeOldChecking() {
        for m in 1...4 {
            add(oldChecking, day(firstYear, m, 9), -money(18, 64), "Greenfield Market", "Groceries", num: "DEBIT")
            add(oldChecking, day(firstYear, m, 28), 62, "Interest Earned", "Interest Income", num: "INT")
        }
        transfer(from: oldChecking, to: checking, day(firstYear, 5, 3), bal[oldChecking.uuid]!, "Account Closing Transfer", memo: "Closed the credit union account")
        oldChecking.isClosed = true
    }

    // MARK: - Amazon orders

    private enum Use { case personal, studio(TaxLine, String), prints(TaxLine, String) }

    private struct Product {
        let name: String
        let department: String
        let cents: Int
        let use: Use
    }

    private let catalog: [Product] = [
        Product(name: "Insulated Stainless Steel Water Bottle, 32 oz, Leak-Proof Lid", department: "Kitchen", cents: 24_99, use: .personal),
        Product(name: "Kids Rain Boots, Waterproof, Easy-On Handles (Toddler/Little Kid)", department: "Shoes", cents: 27_95, use: .personal),
        Product(name: "Dishwasher Detergent Pods, Fresh Scent, 78 Count", department: "Health & Household", cents: 19_47, use: .personal),
        Product(name: "LED Light Bulbs, 60W Equivalent, Soft White, 16 Pack", department: "Tools & Home Improvement", cents: 21_99, use: .personal),
        Product(name: "Dog Chew Toys for Medium Breeds, 3 Pack", department: "Pet Supplies", cents: 16_49, use: .personal),
        Product(name: "Cast Iron Skillet, 12 Inch, Pre-Seasoned", department: "Kitchen", cents: 34_90, use: .personal),
        Product(name: "Board Game: Forest Friends Cooperative Adventure, Ages 6+", department: "Toys & Games", cents: 29_99, use: .personal),
        Product(name: "Trail Running Socks, Cushioned, 6 Pairs", department: "Clothing", cents: 18_99, use: .personal),
        Product(name: "Furnace Air Filter 16x25x1, MERV 11, 6 Pack", department: "Tools & Home Improvement", cents: 38_64, use: .personal),
        Product(name: "Picture Book Collection: Bedtime Stories, Hardcover Box Set", department: "Books", cents: 32_18, use: .personal),
        Product(name: "Garden Hose, 50 ft, Kink-Resistant, with Brass Fittings", department: "Patio, Lawn & Garden", cents: 41_99, use: .personal),
        Product(name: "Wireless Earbuds with Charging Case, Noise Cancelling", department: "Electronics", cents: 79_99, use: .personal),
        Product(name: "Kids Bike Helmet, Adjustable, Ages 5-8", department: "Sports & Outdoors", cents: 26_50, use: .personal),
        Product(name: "Sunscreen Lotion SPF 50, Family Size, 2 Pack", department: "Beauty", cents: 17_88, use: .personal),
        Product(name: "Slow Cooker, 6 Quart, Programmable", department: "Kitchen", cents: 54_99, use: .personal),
        Product(name: "USB-C Hub, 7-in-1 Multiport Adapter with HDMI and Card Reader", department: "Electronics", cents: 39_99, use: .studio(.office, "Laptop dock for the studio desk")),
        Product(name: "Printer Paper, 8.5 x 11, 24 lb Bright White, 5 Reams", department: "Office Products", cents: 32_49, use: .studio(.office, "Client proofs")),
        Product(name: "Color Reference Swatch Book, Coated and Uncoated", department: "Office Products", cents: 168_00, use: .studio(.supplies, "Print color matching for client work")),
        Product(name: "Portable SSD, 2TB, USB 3.2", department: "Electronics", cents: 149_99, use: .studio(.office, "Project archive backups")),
        Product(name: "27-inch 4K Monitor, Color Accurate, USB-C", department: "Electronics", cents: 429_99, use: .studio(.office, "Design display")),
        Product(name: "Ergonomic Office Chair, Mesh Back, Adjustable Lumbar", department: "Office Products", cents: 289_00, use: .studio(.office, "Home office")),
        Product(name: "Book: Grid Systems and Layout for Working Designers", department: "Books", cents: 36_75, use: .studio(.office, "Reference")),
        Product(name: "Pen Display Drawing Tablet, 22-inch, with Stand", department: "Electronics", cents: 2_649_00, use: .studio(.capitalPurchase, "Illustration and retouching")),
        Product(name: "Desk Lamp, LED, Adjustable Color Temperature", department: "Office Products", cents: 44_95, use: .studio(.office, "Home office")),
        Product(name: "Rigid Photo Mailers, 9 x 12, Stay Flat, 50 Pack", department: "Office Products", cents: 28_99, use: .prints(.supplies, "Shipping prints")),
        Product(name: "Shipping Labels, 4 x 6 Thermal, 500 Count", department: "Office Products", cents: 16_99, use: .prints(.supplies, "Shipping prints")),
        Product(name: "Archival Matte Photo Paper, 13 x 19, 50 Sheets", department: "Office Products", cents: 64_50, use: .prints(.cogsMaterials, "Print stock")),
        Product(name: "Clear Sleeves for Art Prints, 11 x 14, Resealable, 200 Pack", department: "Arts, Crafts & Sewing", cents: 22_75, use: .prints(.supplies, "Packaging")),
    ]

    private func code(_ length: Int, digitsOnly: Bool = false) -> String {
        let chars = Array(digitsOnly ? "0123456789" : "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        return String((0..<length).map { _ in chars[int(0...(chars.count - 1))] })
    }

    private func amazonOrder(_ shipDate: Date) {
        guard shipDate < today else { return }
        var items: [Product] = []
        for _ in 0..<pick([1, 1, 1, 2, 2, 3]) {
            var p = pick(catalog)
            // The big tablet is a once-in-a-while purchase.
            if p.cents > 1_000_00 && !chance(0.04) { p = catalog[int(0...14)] }
            if case .prints = p.use, shipDate < printsStart { p = catalog[int(0...14)] }
            if !items.contains(where: { $0.name == p.name }) { items.append(p) }
        }
        let order = "11\(int(1...4))-\(code(7, digitsOnly: true))-\(code(7, digitsOnly: true))"
        let purchase = Purchase(vendor: "Amazon", date: Day.adding(.day, -int(1...3), to: shipDate))
        ctx.insert(purchase)
        purchase.orderNumber = order
        purchase.shipDate = shipDate
        purchase.source = "amazon"
        purchase.importKey = "amazon:\(order)|\(BankRow.iso.string(from: shipDate))"
        purchase.cardLast4 = personalCard.last4
        purchase.created = shipDate

        let reviewed = shipDate < Day.adding(.day, -50, to: today)
        for (i, p) in items.enumerated() {
            let item = PurchaseItem(name: p.name, amountCents: p.cents)
            ctx.insert(item)
            item.purchase = purchase
            item.department = p.department
            item.asin = "B0" + code(8)
            item.importKey = "\(purchase.importKey!)|\(item.asin)|\(p.cents)"
            item.created = Day.adding(.second, i, to: shipDate)
            guard reviewed else { continue }
            switch p.use {
            case .personal:
                item.isPersonal = true
            case .studio(let line, let purpose):
                item.businessUUID = studio.uuid
                item.taxLine = line
                item.purpose = purpose
            case .prints(let line, let purpose):
                item.businessUUID = prints.uuid
                item.taxLine = line
                item.purpose = purpose
            }
        }
        charge(personalCard, shipDate, "AMAZON MKTPL*\(code(9))", -purchase.totalCents)
        pendingPurchases.append((purchase, visa))
    }

    // MARK: - Cards: register, downloads and imports

    /// Older charges go straight into the register. The last few weeks arrive the way they would
    /// in real life: as bank downloads. One download per card is imported here (so the import
    /// history, the bank's original text and the re-import protection are all there to see), and a
    /// newer, overlapping one is left in the Sample Downloads folder to try.
    private func postCards() {
        let importedFrom = ago(45), importedTo = ago(12), newerFrom = ago(20)
        for (card, isOFX) in [(personalCard!, false), (businessCard!, true)] {
            for c in card.charges where c.date <= importedFrom && !c.fileOnly { materialize(c, on: card.account) }

            let folder = downloads.appendingPathComponent(card.account.name, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let first = card.charges.filter { $0.date > importedFrom && $0.date <= importedTo }
            let second = card.charges.filter { $0.date > newerFrom && $0.date < today }
            let firstURL = folder.appendingPathComponent(fileName(card, isOFX: isOFX, from: importedFrom, to: importedTo))
            let secondURL = folder.appendingPathComponent(fileName(card, isOFX: isOFX, from: newerFrom, to: ago(1)))
            try? (isOFX ? ofx(first, card: card) : chaseCSV(first)).write(to: firstURL, atomically: true, encoding: .utf8)
            try? (isOFX ? ofx(second, card: card) : chaseCSV(second)).write(to: secondURL, atomically: true, encoding: .utf8)

            try? ctx.save()
            let importer = BankImporter(context: ctx)
            if let statement = try? BankFormats.read(firstURL),
               let batch = try? importer.apply(importer.plan([(firstURL, statement)], into: card.account), to: card.account) {
                batch.date = Day.adding(.hour, 7, to: ago(11))
            }
            // Categories and business tags, as if they had been filled in after the import.
            for e in card.account.entries ?? [] where e.bankDescription != nil && e.category == nil && !e.isTransfer {
                apply(rule(for: e.bankDescription!), to: e)
            }
        }
    }

    private func fileName(_ card: Card, isOFX: Bool, from: Date, to: Date) -> String {
        let f = DateFormatter()
        f.calendar = Day.calendar
        f.timeZone = Day.calendar.timeZone
        f.dateFormat = "yyyyMMdd"
        return isOFX
            ? "StudioVisa_\(f.string(from: to))_\(card.last4).qfx"
            : "Chase\(card.last4)_Activity\(f.string(from: from))_\(f.string(from: to))_\(f.string(from: to)).CSV"
    }

    private func chaseCSV(_ charges: [Charge]) -> String {
        let f = DateFormatter()
        f.calendar = Day.calendar
        f.timeZone = Day.calendar.timeZone
        f.dateFormat = "MM/dd/yyyy"
        var lines = ["Transaction Date,Post Date,Description,Category,Type,Amount,Memo"]
        for c in charges.sorted(by: { ($0.date, $0.seq) > ($1.date, $1.seq) }) {
            let posted = f.string(from: Day.adding(.day, 1, to: c.date))
            lines.append(CSV.row([f.string(from: c.date), posted, c.raw, c.cents > 0 ? "" : "Shopping",
                                  c.cents > 0 ? "Payment" : "Sale", "\(Cents.decimal(c.cents))", ""]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func ofx(_ charges: [Charge], card: Card) -> String {
        let f = DateFormatter()
        f.calendar = Day.calendar
        f.timeZone = Day.calendar.timeZone
        f.dateFormat = "yyyyMMdd"
        var s = "OFXHEADER:100\nDATA:OFXSGML\nVERSION:102\nSECURITY:NONE\nENCODING:USASCII\nCHARSET:1252\nCOMPRESSION:NONE\nOLDFILEUID:NONE\nNEWFILEUID:NONE\n\n"
        s += "<OFX>\n<CREDITCARDMSGSRSV1>\n<CCSTMTTRNRS>\n<CCSTMTRS>\n<CURDEF>USD\n<CCACCTFROM>\n<ACCTID>XXXXXXXXXXXX\(card.last4)\n</CCACCTFROM>\n<BANKTRANLIST>\n"
        for c in charges.sorted(by: { ($0.date, $0.seq) < ($1.date, $1.seq) }) {
            let name = c.raw.replacingOccurrences(of: "&", with: "&amp;")
            s += "<STMTTRN>\n<TRNTYPE>\(c.cents > 0 ? "CREDIT" : "DEBIT")\n<DTPOSTED>\(f.string(from: c.date))120000\n<TRNAMT>\(Cents.decimal(c.cents))\n<FITID>\(f.string(from: c.date))\(String(format: "%06d", c.seq))\n<NAME>\(name)\n</STMTTRN>\n"
        }
        return s + "</BANKTRANLIST>\n</CCSTMTRS>\n</CCSTMTTRNRS>\n</CREDITCARDMSGSRSV1>\n</OFX>\n"
    }

    private func materialize(_ c: Charge, on account: Account) {
        guard let e = add(account, c.date, c.cents, PayeeCleaner.clean(c.raw)) else { return }
        // A warehouse run is often part groceries, part everything else.
        if c.raw.hasPrefix("BULKBARN") && chance(0.5) {
            let household = c.cents * int(15...30) / 100, clothing = chance(0.4) ? c.cents * int(8...15) / 100 : 0
            let lines = [("Groceries", c.cents - household - clothing), ("Shopping : Household", household), ("Shopping : Clothing", clothing)]
            for (i, line) in lines.filter({ $0.1 != 0 }).enumerated() {
                let s = Entry(account: account, date: c.date, amountCents: line.1)
                ctx.insert(s)
                s.splitParent = e
                s.splitOrder = i
                s.category = category(line.0)
            }
        } else {
            apply(rule(for: c.raw), to: e)
        }
    }

    private func apply(_ rule: Rule?, to e: Entry) {
        guard let rule else { return }
        if rule.parking {
            e.vehicle = car
            e.vehicleExpense = .parkingTolls
            e.memo = e.memo ?? "Client visit parking"
        } else {
            e.category = category(rule.category)
        }
        if let b = rule.business { e.business = b }
    }

    /// Two things typed into the register by hand, which the newer downloads then match.
    private func addHandEntered() {
        add(visa, ago(6), -184_20, "Paws & Claws Vet", "Pets : Vet", memo: "Annual checkup and vaccines for Biscuit")
        sequence += 1
        personalCard.charges.append(Charge(date: ago(5), raw: "PAWS & CLAWS VET", cents: -184_20, seq: sequence, fileOnly: true))

        // A camera for the studio, itemized as a purchase.
        let bought = Day.date(year: Day.year(of: today) - 1, month: 10, day: 14)
        charge(businessCard, bought, "KEYSTONE CAMERA & VIDEO", -2_931_18)
        let camera = Purchase(vendor: "Keystone Camera & Video", date: bought)
        ctx.insert(camera)
        camera.orderNumber = "KC-20418"
        camera.cardLast4 = businessCard.last4
        camera.link = "https://example.com/orders/KC-20418"
        camera.notes = "Bought for client product photography. Three-year warranty registered."
        camera.created = bought
        for (i, (name, cents, line)) in [("Mirrorless Camera Body, Full Frame", 2_199_00, TaxLine.capitalPurchase),
                                         ("35mm f/1.8 Prime Lens", 549_00, .capitalPurchase), ("Tax & shipping", 183_18, .capitalPurchase)].enumerated() {
            let item = PurchaseItem(name: name, amountCents: cents)
            ctx.insert(item)
            item.purchase = camera
            item.businessUUID = studio.uuid
            item.taxLine = line
            item.purpose = "Product and portfolio photography for clients"
            item.created = Day.adding(.second, i, to: bought)
        }
        pendingPurchases.append((camera, bizVisa))

        // A hardware-store run split between the house and the print business.
        let run = ago(33)
        charge(personalCard, run, "TIMBERLINE HARDWARE", -186_42)
        let hardware = Purchase(vendor: "Timberline Hardware", date: run)
        ctx.insert(hardware)
        hardware.cardLast4 = personalCard.last4
        hardware.notes = "Receipt is in the glove box folder."
        hardware.created = run
        let lines: [(String, Int, Bool)] = [("Deck Stain, Semi-Transparent, 2 gal", 89_98, false), ("Stain Brush Set", 18_49, false),
                                            ("Pine Boards 1x4, for print display racks", 61_95, true), ("Tax", 16_00, false)]
        for (i, (name, cents, forPrints)) in lines.enumerated() {
            let item = PurchaseItem(name: name, amountCents: cents)
            ctx.insert(item)
            item.purchase = hardware
            item.created = Day.adding(.second, i, to: run)
            if forPrints {
                item.businessUUID = prints.uuid
                item.taxLine = .supplies
                item.purpose = "Display racks for the spring craft fair"
            } else {
                item.isPersonal = true
            }
        }
        pendingPurchases.append((hardware, visa))
    }

    /// Links each purchase to the card charge that paid for it, when that charge is in the register.
    private func linkPurchases() {
        var claimed = Set<UUID>()
        var byAccount: [UUID: [Int: [Entry]]] = [:]
        for a in [visa!, bizVisa!] {
            byAccount[a.uuid] = Dictionary(grouping: (a.entries ?? []).filter { !$0.isSplitLine }, by: \.amountCents)
        }
        for (purchase, account) in pendingPurchases {
            let candidates = (byAccount[account.uuid]?[-purchase.totalCents] ?? []).filter {
                !claimed.contains($0.uuid) && abs($0.date.timeIntervalSince(purchase.chargeDate)) <= 3 * 86_400
            }
            guard let e = candidates.min(by: { abs($0.date.timeIntervalSince(purchase.chargeDate)) < abs($1.date.timeIntervalSince(purchase.chargeDate)) }) else { continue }
            purchase.entryUUID = e.uuid
            claimed.insert(e.uuid)
        }
    }

    // MARK: - Finishing touches

    private var nextMortgage: Date { let p = parts(Day.adding(.month, 1, to: Day.startOfMonth(today))); return day(p.y, p.m, 1) }

    /// A couple of payments already entered for next month, the way people do with auto-pay.
    private func enterAhead() {
        if let e = transfer(from: checking, to: mortgage, nextMortgage, 1_412_57, "Northwind Home Loans", memo: "Mortgage payment", future: true) {
            e.isFlagged = true
            e.flagNote = "Auto-pay is scheduled with the lender"
        }
        let p = parts(nextMortgage)
        add(checking, day(p.y, p.m, 3), -46_20, "Beacon Life Insurance", "Insurance : Life", num: "EFT", future: true)
    }

    private var statementDate: Date {
        let thisMonth = Day.startOfMonth(today)
        let cutoff = parts(today).d >= 10 ? thisMonth : Day.adding(.month, -1, to: thisMonth)
        return Day.adding(.day, -1, to: cutoff)
    }

    private func setStatuses() {
        let reconciled = statementDate, cleared = ago(4)
        for e in (try? ctx.fetch(FetchDescriptor<Entry>())) ?? [] {
            if e.date <= reconciled {
                e.status = .reconciled
            } else if e.date <= cleared && !(e.account === visa && e.bankDescription == nil && e.payee?.name == "Paws & Claws Vet") {
                e.status = .cleared
            } else if e.bankDescription == nil {
                e.status = .uncleared
            }
            if e.status != .uncleared { e.dateCleared = e.date }
        }
    }

    private func setStatement(_ a: Account) {
        let date = statementDate
        let balance = a.openingBalanceCents + (a.entries ?? []).filter { $0.date <= date }.reduce(0) { $0 + $1.balanceEffectCents }
        a.statementDate = date
        a.statementBalanceCents = balance
        a.lastReconciledDate = date
        a.lastReconciledBalanceCents = balance
    }

    private func settleOpeningBalance(_ a: Account, floor: Int) {
        var running = a.openingBalanceCents, lowest = a.openingBalanceCents
        for e in (a.entries ?? []).sorted(by: { $0.date < $1.date }) {
            running += e.balanceEffectCents
            lowest = min(lowest, running)
        }
        if lowest < floor { a.openingBalanceCents += (floor - lowest + 99_99) / 100_00 * 100_00 }
    }

    private func flagAFew() {
        func latest(_ a: Account, _ name: String) -> Entry? {
            (a.entries ?? []).filter { $0.payee?.name == name && $0.date <= today && $0.status != .reconciled }.max { $0.date < $1.date }
        }
        if let e = latest(visa, "The Copper Kettle") ?? latest(visa, "Luna Taqueria") {
            e.isFlagged = true
            e.flagNote = "Charged twice? Compare with the receipt and call if so."
            e.flagDate = ago(2)
        }
        if let e = latest(bizChecking, "Tamarack Brewing Co.") ?? latest(bizChecking, "Harbor & Pine Outfitters") {
            e.isFlagged = true
            e.flagNote = "Send the paid receipt and close out the invoice."
            e.flagDate = Day.adding(.day, 5, to: today)
        }
        if let e = latest(checking, "Cascade Power & Light") {
            e.isFlagged = true
            e.flagNote = "Higher than usual. Check the meter reading."
        }
    }

    private func makeMileage() {
        let purposes = ["Client meeting, Harbor & Pine Outfitters", "Press check at the print shop", "Site photos, Tamarack Brewing Co.",
                        "Deliver proofs, Blue Heron Dental", "Board presentation, Northgate Community Foundation", "Supply run, paper and mounting board",
                        "Bookstore event setup, Wren & Finch Books", "Networking breakfast, chamber of commerce"]
        var d = Day.date(year: firstYear + 1, month: 6, day: 14)
        var totals: [String: Int] = [:]
        while d <= today {
            let trip = MileageEntry(date: d, tenthMiles: int(48...460), kind: .business, purpose: pick(purposes))
            ctx.insert(trip)
            trip.vehicle = car
            totals[String(Day.year(of: d)), default: 0] += trip.tenthMiles
            d = Day.adding(.day, int(3...8), to: d)
        }
        // Odometer totals for finished years, so the business-use share is real.
        var odometer: [String: Int] = [:]
        for (year, tenths) in totals where Int(year)! < Day.year(of: today) { odometer[year] = tenths / 10 + int(7_400...9_100) }
        car.yearTotals = odometer
    }

    /// The studio's depreciation schedule, as an accountant would hand it over.
    private func makeAssets() {
        let thisYear = Day.year(of: today)
        func asset(_ name: String, _ date: Date, cost: Int, method: String, prior: Int = 0, amounts: [Int: Int], notes: String = "") {
            let a = Asset(name: name)
            ctx.insert(a)
            a.businessUUID = studio.uuid
            a.placedInService = date
            a.costCents = cost
            a.method = method
            a.priorDepreciationCents = prior
            a.yearAmounts = amounts.filter { $0.key <= thisYear }
            a.notes = notes
            a.created = date
        }
        asset("Office furniture: desk, shelving, flat files", Day.date(year: firstYear - 2, month: 3, day: 18), cost: 4_280_00,
              method: "7-yr MACRS, half-year", prior: 1_660_21,
              amounts: [firstYear: 748_57, firstYear + 1: 534_57, firstYear + 2: 382_20, firstYear + 3: 382_63, firstYear + 4: 382_20])
        asset("Design workstation and display", Day.date(year: firstYear + 1, month: 2, day: 9), cost: 3_480_00,
              method: "Section 179, expensed in full", amounts: [firstYear + 1: 3_480_00],
              notes: "Expensed in the year it was bought, on the accountant's advice.")
        asset("Large-format printer", Day.date(year: firstYear + 2, month: 8, day: 22), cost: 1_895_00,
              method: "5-yr MACRS, half-year", amounts: [firstYear + 2: 379_00, firstYear + 3: 606_40, firstYear + 4: 363_84])
        asset("Camera body and 35mm lens", Day.date(year: thisYear - 1, month: 10, day: 14), cost: 2_931_18,
              method: "5-yr MACRS, half-year", amounts: [thisYear - 1: 586_24, thisYear: 937_98],
              notes: "From the Keystone Camera & Video purchase.")
    }

    // MARK: - Bills and deposits

    private func makeBills(paydays: [Date]) {
        func next(day d: Int, months: [Int]? = nil) -> Date {
            var p = parts(today)
            for _ in 0..<24 {
                let candidate = day(p.y, p.m, d)
                if candidate > today && (months == nil || months!.contains(p.m)) { return candidate }
                p.m += 1
                if p.m > 12 { p.m = 1; p.y += 1 }
            }
            return today
        }

        @discardableResult
        func bill(_ account: Account, _ name: String?, _ cents: Int, _ categoryName: String?, due: Date, unit: RecurrenceUnit = .month,
                  every: Int = 1, to: Account? = nil, memo: String? = nil, flag: Bool = false) -> Bill {
            let b = Bill(amountCents: cents, nextDue: due)
            ctx.insert(b)
            b.account = account
            b.payee = name.map(payee)
            b.category = categoryName.map(category)
            b.transferAccount = to
            b.unit = unit
            b.every = every
            b.anchorDay = unit == .week ? 0 : parts(due).d
            b.memo = memo
            b.flagOnEnter = flag
            b.startDate = Day.date(year: firstYear, month: 1, day: 1)
            return b
        }

        let years = Double(Day.year(of: today) - firstYear)
        let net = Int((2_340_00 * pow(1.035, years)).rounded())
        bill(checking, "Larkspur Medical Group", net, "Wages & Salary : Net Pay", due: paydays.first { $0 > today }!, unit: .week, every: 2, memo: "Payroll")
        bill(checking, "Northwind Home Loans", -1_412_57, nil, due: Day.adding(.month, 1, to: nextMortgage), to: mortgage, memo: "Mortgage payment", flag: true)
        bill(checking, "Cascade Auto Finance", -528_31, nil, due: next(day: 15), to: autoLoan, memo: "Car payment", flag: true)
        bill(checking, "Rewards Visa Payment", -2_650_00, nil, due: next(day: 20), to: visa, memo: "About what the card runs each month")
        bill(checking, "Savings Transfer", -400_00, nil, due: next(day: 4), to: savings, memo: "Monthly savings")
        bill(checking, "Summit Ridge Investments", -350_00, nil, due: next(day: 6), to: brokerage, memo: "Monthly investment")
        bill(checking, "Cascade Power & Light", -168_00, "Utilities : Electric", due: next(day: 12))
        // Overdue: due a few days ago and not entered yet.
        let water = bill(checking, "Riverbend Water & Sewer", -84_00, "Utilities : Water & Sewer", due: ago(4))
        water.anchorDay = 18
        bill(checking, "FiberLink Internet", -84_99, "Utilities : Internet", due: next(day: 5))
        bill(checking, "Clearwave Mobile", -Int(138_40 * (1 + 0.04 * years)), "Utilities : Mobile Phone", due: next(day: 9))
        let life = Day.adding(.month, 1, to: nextMortgage)
        bill(checking, "Beacon Life Insurance", -46_20, "Insurance : Life", due: day(parts(life).y, parts(life).m, 3))
        bill(checking, "Regional Food Bank", -35_00, "Charity", due: next(day: 16))
        bill(checking, "Cedar Hollow After-School Club", -310_00, "Childcare & Education : After-School", due: next(day: 2))
        bill(checking, "Maple Ridge HOA", -285_00, "Housing : HOA Dues", due: next(day: 7, months: [1, 4, 7, 10]), every: 3, memo: "Quarterly dues")
        bill(checking, "U.S. Treasury", -2_600_00, "Taxes : Federal Estimated", due: next(day: 15, months: [1, 4, 7, 10]), every: 3, memo: "Estimated tax")
        bill(checking, "State Department of Revenue", -600_00, "Taxes : State Estimated", due: next(day: 15, months: [1, 4, 7, 10]), every: 3, memo: "Estimated tax")
        bill(checking, "Evergreen Mutual Insurance", -810_00, "Auto : Insurance", due: next(day: 15, months: [2, 8]), every: 6, memo: "6-month auto policy")
        bill(checking, "Evergreen Mutual Insurance", -1_690_00, "Housing : Home Insurance", due: next(day: 20, months: [3]), unit: .year, memo: "Annual homeowners policy")
        bill(checking, "Pine County Tax Collector", -2_520_00, "Housing : Property Tax", due: next(day: 10, months: [4, 10]), every: 6)
        bill(checking, "Craftfair Marketplace", 240_00, "Business Income : Product Sales", due: next(day: parts(today).d < 8 || parts(today).d >= 22 ? 8 : 22), unit: .semimonth, memo: "Shop payout")
        bill(bizChecking, "Harbor & Pine Outfitters", 2_600_00, "Business Income : Design Services", due: next(day: 5), memo: "Monthly retainer")
        bill(bizChecking, "Northgate Community Foundation", 2_750_00, "Business Income : Design Services", due: next(day: 20, months: [2, 5, 8, 11]), every: 3, memo: "Quarterly newsletter and annual report")
        bill(bizChecking, "Studio Visa Payment", -420_00, nil, due: next(day: 18), to: bizVisa, memo: "About what the card runs each month")
        bill(bizChecking, "Owner Draw", -3_250_00, nil, due: next(day: 27), to: checking, memo: "Juniper Lane Studio draw")
        bill(bizChecking, "Tallyworks CPA", -690_00, "Business : Professional Fees", due: next(day: 11, months: [3]), unit: .year, memo: "Tax preparation")
    }

    // MARK: - What-if scenarios

    private func makeScenarios() {
        let bills = (try? ctx.fetch(FetchDescriptor<Bill>())) ?? []
        func billNamed(_ name: String) -> Bill? { bills.first { $0.payee?.name == name } }
        func month(_ n: Int, day d: Int) -> Date {
            let p = parts(Day.adding(.month, n, to: Day.startOfMonth(today)))
            return day(p.y, p.m, d)
        }
        func scenario(_ name: String, _ notes: String, _ items: [ScenarioItem]) {
            let s = Scenario(name: name)
            ctx.insert(s)
            s.notes = notes
            for (i, item) in items.enumerated() {
                ctx.insert(item)
                item.scenario = s
                item.created = Day.adding(.second, i, to: today)
            }
        }
        func item(_ kind: ScenarioKind, _ name: String, _ cents: Int = 0, on date: Date, account: Account? = nil, bill: Bill? = nil, until: Date? = nil) -> ScenarioItem {
            let i = ScenarioItem(kind: kind, startDate: date)
            i.name = name
            i.amountCents = cents
            i.accountUUID = account?.uuid
            i.billUUID = bill?.uuid
            i.endDate = until
            return i
        }

        scenario("New roof in the spring", "Two payments to the roofer, partly offset by the energy rebate.", [
            item(.oneTime, "Summit Roofing, deposit", -6_500_00, on: month(4, day: 8), account: checking),
            item(.oneTime, "Summit Roofing, balance on completion", -9_800_00, on: month(5, day: 20), account: checking),
            item(.oneTime, "State energy rebate", 1_200_00, on: month(7, day: 15), account: checking),
        ])
        scenario("Lose the retainer client", "What if Harbor & Pine ends the retainer and the draw has to shrink?", [
            item(.stopBill, "Harbor & Pine retainer ends", on: month(3, day: 1), bill: billNamed("Harbor & Pine Outfitters")),
            item(.changeBill, "Smaller owner draw", -1_800_00, on: month(4, day: 1), bill: billNamed("Owner Draw")),
            item(.recurring, "Cut streaming and gym", 62_00, on: month(3, day: 1), account: checking),
        ])
        scenario("Second car", "A used commuter car: down payment now, then a 48-month loan and more insurance.", [
            item(.oneTime, "Down payment", -4_000_00, on: month(2, day: 12), account: savings),
            item(.recurring, "Car payment", -385_00, on: month(3, day: 12), account: checking),
            item(.recurring, "Added insurance", -74_00, on: month(3, day: 15), account: checking),
        ])
    }

    private func makePresets() {
        func preset(_ name: String, _ kind: String, _ names: [String], period: ReportPeriod) {
            let p = ReportPreset(name: name, kind: kind)
            ctx.insert(p)
            p.payees = Set(names.compactMap { payees[$0.lowercased()]?.uuid })
            p.periodRaw = period.rawValue
        }
        preset("Utilities", "payees", ["Cascade Power & Light", "Riverbend Water & Sewer", "FiberLink Internet", "Clearwave Mobile"], period: .allDates)
        preset("Groceries", "payees", ["Greenfield Market", "Harvest Co-Op", "Bulkbarn Wholesale"], period: .last12Months)
        preset("Eating out", "payees", ["The Copper Kettle", "Juniper Coffee", "Luna Taqueria", "Golden Bowl Noodles", "Slice House Pizza"], period: .allDates)
        preset("Studio clients", "depositSources", ["Harbor & Pine Outfitters", "Blue Heron Dental", "Northgate Community Foundation",
                                                    "Tamarack Brewing Co.", "Wren & Finch Books"], period: .allDates)
        preset("Paychecks", "depositSources", ["Larkspur Medical Group"], period: .allDates)
    }
}
