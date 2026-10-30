import SwiftUI
import SwiftData
import Charts

// MARK: - Profit & Loss

/// Income and expenses by category for one business, with a monthly net chart.
struct ProfitLossView: View {
    @Environment(\.modelContext) private var context
    @Environment(LedgerIndex.self) private var index
    let business: Business

    @State private var year = Day.year(of: Day.today)
    @State private var custom = false
    @State private var from = Day.startOfYear(Day.today)
    @State private var to = Day.today
    @State private var data: PL?

    struct PL {
        var income: [(name: String, cents: Int)] = []
        var expense: [(name: String, cents: Int)] = []
        var months: [(month: Date, income: Int, expense: Int)] = []
        var totalIncome: Int { income.reduce(0) { $0 + $1.cents } }
        var totalExpense: Int { expense.reduce(0) { $0 + $1.cents } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PeriodPicker(year: $year, custom: $custom, from: $from, to: $to).padding(12)
            Divider()
            if let data {
                HStack(alignment: .top, spacing: 0) {
                    List {
                        Section("Income — \(Cents.string(data.totalIncome))") {
                            ForEach(data.income, id: \.name) { row($0.name, $0.cents) }
                        }
                        Section("Expenses — \(Cents.string(data.totalExpense))") {
                            ForEach(data.expense, id: \.name) { row($0.name, $0.cents) }
                        }
                        Section {
                            row("Net profit (loss)", data.totalIncome - data.totalExpense).bold()
                        }
                    }
                    .frame(minWidth: 380)
                    Chart {
                        ForEach(data.months, id: \.month) { m in
                            BarMark(x: .value("Month", m.month, unit: .month), y: .value("Income", Double(m.income) / 100))
                                .foregroundStyle(by: .value("Type", "Income"))
                                .position(by: .value("Type", "Income"))
                            BarMark(x: .value("Month", m.month, unit: .month), y: .value("Expenses", Double(m.expense) / 100))
                                .foregroundStyle(by: .value("Type", "Expenses"))
                                .position(by: .value("Type", "Expenses"))
                        }
                    }
                    .chartForegroundStyleScale(["Income": Color.green, "Expenses": Color.red])
                    .padding()
                    .frame(minWidth: 380)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(index.version)|\(year)|\(custom)|\(from)|\(to)") { data = build() }
    }

    private func row(_ name: String, _ cents: Int) -> some View {
        HStack { Text(name); Spacer(); Text(Cents.string(cents)).monospacedDigit().foregroundStyle(cents < 0 ? .red : .primary) }
    }

    private func build() -> PL {
        let range = PeriodPicker.range(year: year, custom: custom, from: from, to: to)
        let lower = range.lowerBound, upper = range.upperBound
        let entries = (try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.date >= lower && $0.date <= upper }))) ?? []
        let bid = business.persistentModelID
        var income: [String: Int] = [:], expense: [String: Int] = [:]
        var months: [Date: (Int, Int)] = [:]
        for e in entries {
            guard !e.isVoid, !e.isSplit, !e.isTransfer, e.effectiveBusiness?.persistentModelID == bid else { continue }
            let portion = Int((Double(e.amountCents) * Double(e.businessPercent) / 100).rounded())
            let name = e.vehicle.map { "Vehicle: \($0.name)" } ?? e.category?.fullName ?? "(no category)"
            let m = Day.startOfMonth(e.date)
            if portion >= 0 && e.category?.kind != .expense {
                income[name, default: 0] += portion
                months[m, default: (0, 0)].0 += portion
            } else {
                expense[name, default: 0] += -portion
                months[m, default: (0, 0)].1 += -portion
            }
        }
        var pl = PL()
        pl.income = income.map { ($0.key, $0.value) }.sorted { $0.cents > $1.cents }
        pl.expense = expense.map { ($0.key, $0.value) }.sorted { $0.cents > $1.cents }
        pl.months = months.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.month < $1.month }
        return pl
    }
}

// MARK: - Tax line setup

/// Map categories to Schedule C lines once; every business transaction in that category follows.
struct TaxLineSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(LedgerIndex.self) private var index
    @Query private var categories: [Category]
    let business: Business

    @State private var search = ""
    @State private var onlyUsed = true
    @State private var sortOrder = [KeyPathComparator(\CategoryLineRow.usage, order: .reverse)]

    struct CategoryLineRow: Identifiable {
        let category: Category
        let name: String
        let kind: String
        let line: String
        let usage: Int
        var id: PersistentIdentifier { category.persistentModelID }
    }

    var body: some View {
        let used = Dictionary(grouping: index.rows.filter { $0.business == business.name }, by: \.category).mapValues(\.count)
        let q = search.lowercased()
        let rows = categories.filter { !$0.isRoot }
            .map { CategoryLineRow(category: $0, name: $0.fullName, kind: $0.kind.rawValue.capitalized,
                                   line: $0.scheduleCLine ?? "", usage: used[$0.fullName] ?? 0) }
            .filter { (!onlyUsed || $0.usage > 0) && (q.isEmpty || $0.name.lowercased().contains(q)) }
            .sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Search categories", text: $search).textFieldStyle(.roundedBorder).frame(width: 260)
                Toggle("Only categories used by \(business.name)", isOn: $onlyUsed).toggleStyle(.checkbox)
                Spacer()
                Text("Lines apply to business transactions in every business; vehicle costs go through Vehicles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Category", value: \.name) { r in Text(r.name) }.width(min: 200, ideal: 300)
                TableColumn("Type", value: \.kind) { r in Text(r.kind).foregroundStyle(.secondary) }.width(70)
                TableColumn("Business uses", value: \.usage) { r in Text(r.usage == 0 ? "" : "\(r.usage)").monospacedDigit() }.width(90)
                TableColumn("Schedule C line", value: \.line) { r in
                    Menu(r.category.scheduleCLine.flatMap(TaxLine.init)?.label ?? "Not set") {
                        Button("Not set") { set(r.category, nil) }
                        Divider()
                        ForEach([TaxLine.Part.income, .expenses, .cogs, .other], id: \.self) { part in
                            Section(part.rawValue) {
                                ForEach(TaxLine.allCases.filter { $0.part == part }) { line in
                                    Button(line.label) { set(r.category, line) }
                                }
                            }
                        }
                    }
                    .foregroundStyle(r.line.isEmpty && r.usage > 0 ? .orange : .primary)
                }
                .width(min: 260, ideal: 340)
            }
        }
    }

    private func set(_ c: Category, _ line: TaxLine?) {
        c.scheduleCLine = line?.rawValue
        try? context.save()
    }
}

// MARK: - Vehicles & mileage

struct VehiclesView: View {
    @Environment(\.modelContext) private var context
    let business: Business
    @State private var selection: PersistentIdentifier?
    @State private var showRates = false

    private var vehicles: [Vehicle] { (business.vehicles ?? []).sorted { $0.name < $1.name } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(vehicles, selection: $selection) { v in
                    Label(v.name, systemImage: "car").foregroundStyle(v.isActive ? .primary : .secondary)
                }
                HStack {
                    Button { addVehicle() } label: { Label("Add Vehicle", systemImage: "plus") }
                    Spacer()
                    Button("IRS Rates…") { showRates = true }
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
            if let v = vehicles.first(where: { $0.persistentModelID == selection }) {
                VehicleDetail(vehicle: v).id(v.persistentModelID)
            } else {
                ContentUnavailableView("Add a vehicle", systemImage: "car",
                                       description: Text("Log business, commuting and personal miles, and tag fuel, repairs, insurance and other costs to it from Tag Transactions or the transaction form."))
            }
        }
        .sheet(isPresented: $showRates) { MileageRatesEditor() }
        .onAppear { if selection == nil { selection = vehicles.first?.persistentModelID } }
    }

    private func addVehicle() {
        let v = Vehicle(name: "New vehicle")
        v.business = business
        context.insert(v)
        try? context.save()
        selection = v.persistentModelID
    }
}

private struct VehicleDetail: View {
    @Environment(\.modelContext) private var context
    @Bindable var vehicle: Vehicle
    @State private var year = Day.year(of: Day.today)
    @State private var newDate = Day.today
    @State private var newMiles = ""
    @State private var newKind: MileageKind = .business
    @State private var newPurpose = ""
    @State private var odometer = ""

    private var trips: [MileageEntry] {
        (vehicle.trips ?? []).filter { Day.year(of: $0.date) == year }.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $vehicle.name)
                Picker("Deduction method", selection: $vehicle.methodRaw) {
                    Text("Standard mileage rate").tag("standard")
                    Text("Actual expenses × business-use %").tag("actual")
                }
                DatePicker("Placed in service", selection: Binding(get: { Day.toLocal(vehicle.placedInService ?? Day.today) },
                                                                  set: { vehicle.placedInService = Day.normalize($0) }), displayedComponents: .date)
                Toggle("Active", isOn: $vehicle.isActive)
            }
            .formStyle(.grouped)
            .frame(height: 200)

            HStack {
                Stepper("Year \(String(year))", value: $year, in: 1990...2100)
                Spacer()
                let totals = (vehicle.trips ?? []).filter { Day.year(of: $0.date) == year }
                ForEach(MileageKind.allCases) { k in
                    Text("\(k.title): \(String(format: "%.1f", Double(totals.filter { $0.kind == k }.reduce(0) { $0 + $1.tenthMiles }) / 10))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                TextField("Odometer total miles for year", text: $odometer)
                    .frame(width: 200)
                    .onSubmit {
                        var t = vehicle.yearTotals
                        t[String(year)] = Int(odometer.replacingOccurrences(of: ",", with: ""))
                        vehicle.yearTotals = t
                        try? context.save()
                    }
                    .help("Total miles driven this year (end minus start odometer). Used for business-use %; otherwise the log total is used.")
            }
            .padding(.horizontal, 12)

            HStack {
                DatePicker("", selection: Binding(get: { Day.toLocal(newDate) }, set: { newDate = Day.normalize($0) }), displayedComponents: .date)
                    .labelsHidden()
                TextField("Miles", text: $newMiles).frame(width: 80)
                Picker("", selection: $newKind) { ForEach(MileageKind.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 120)
                TextField("Purpose / destination", text: $newPurpose)
                Button("Add Trip") { addTrip() }.disabled(Cents.parse(newMiles) == nil)
            }
            .padding(12)

            Table(trips) {
                TableColumn("Date") { t in Text(Day.string(t.date)).monospacedDigit() }.width(80)
                TableColumn("Miles") { t in Text(String(format: "%.1f", Double(t.tenthMiles) / 10)).monospacedDigit() }.width(70)
                TableColumn("Type") { t in Text(t.kind.title) }.width(90)
                TableColumn("Purpose") { t in Text(t.purpose) }
            }
            .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
                Button("Delete Trip", role: .destructive) {
                    for id in ids { if let t = context.model(for: id) as? MileageEntry { context.delete(t) } }
                    try? context.save()
                }
            }
        }
        .onAppear { odometer = vehicle.yearTotals[String(year)].map(String.init) ?? "" }
        .onChange(of: year) { odometer = vehicle.yearTotals[String(year)].map(String.init) ?? "" }
    }

    private func addTrip() {
        // Reuse the exact cents parser: "12.3" miles -> 1230 hundredths -> 123 tenths.
        guard let hundredths = Cents.parse(newMiles) else { return }
        let t = MileageEntry(date: newDate, tenthMiles: hundredths / 10, kind: newKind, purpose: newPurpose)
        t.vehicle = vehicle
        context.insert(t)
        try? context.save()
        newMiles = ""
        newPurpose = ""
    }
}

private struct MileageRatesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rates: [(year: Int, cents: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("IRS Standard Mileage Rates").font(.title2.bold())
            Text("Cents per business mile. The IRS publishes a new rate each year (irs.gov) — add it here when announced. 2022 had two rates (58.5¢ Jan–Jun, 62.5¢ Jul–Dec); enter a blended rate or split trips yourself.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading) {
                ForEach($rates, id: \.year) { $r in
                    GridRow {
                        Text(String(r.year))
                        TextField("¢/mile", text: $r.cents).frame(width: 100)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var all: [Int: Double] = [:]
                    for r in rates { if let v = Double(r.cents) { all[r.year] = v } }
                    MileageRates.all = all
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            let current = MileageRates.all
            let now = Day.year(of: Day.today)
            rates = (2015...(now + 1)).reversed().map { y in (y, current[y].map { String($0) } ?? "") }
        }
    }
}
