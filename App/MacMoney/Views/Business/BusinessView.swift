import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// One business: Schedule C, Profit & Loss, transaction tagging, vehicles, and tax-line setup.
struct BusinessView: View {
    let business: Business

    enum Tab: String, CaseIterable, Identifiable {
        case scheduleC = "Schedule C"
        case profitLoss = "Profit & Loss"
        case tag = "Tag Transactions"
        case vehicles = "Vehicles & Mileage"
        case taxLines = "Tax Line Setup"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .scheduleC
    @State private var editing = false

    var body: some View {
        Group {
            switch tab {
            case .scheduleC: ScheduleCView(business: business, onFixLines: { tab = .tag })
            case .profitLoss: ProfitLossView(business: business)
            case .tag: TagTransactionsView(business: business)
            case .vehicles: VehiclesView(business: business)
            case .taxLines: TaxLineSetupView(business: business)
            }
        }
        .navigationTitle(business.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { editing = true } label: { Label("Business Settings", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $editing) { BusinessEditor(business: business) }
    }
}

/// Tax year or custom range, shared by the business reports.
struct PeriodPicker: View {
    @Environment(LedgerIndex.self) private var index
    @Binding var year: Int
    @Binding var custom: Bool
    @Binding var from: Date
    @Binding var to: Date

    var body: some View {
        HStack {
            Picker("Tax year", selection: Binding(get: { custom ? 0 : year }, set: { if $0 == 0 { custom = true } else { custom = false; year = $0 } })) {
                ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                Divider()
                Text("Custom range…").tag(0)
            }
            .frame(width: 200)
            if custom {
                DatePicker("From", selection: day($from), displayedComponents: .date)
                DatePicker("To", selection: day($to), displayedComponents: .date)
            }
        }
    }

    private var years: [Int] {
        let now = Day.year(of: Day.today)
        let first = index.rows.first.map { Day.year(of: $0.date) } ?? now
        let last = max(now, index.rows.last.map { Day.year(of: $0.date) } ?? now)
        return Array((first...last).reversed())
    }

    private func day(_ b: Binding<Date>) -> Binding<Date> {
        Binding(get: { Day.toLocal(b.wrappedValue) }, set: { b.wrappedValue = Day.normalize($0) })
    }

    static func range(year: Int, custom: Bool, from: Date, to: Date) -> ClosedRange<Date> {
        if custom { return min(from, to)...max(from, to) }
        return Day.date(year: year, month: 1, day: 1)...Day.date(year: year, month: 12, day: 31)
    }
}

struct BusinessEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let business: Business?
    var onCreated: (Business) -> Void = { _ in }

    @State private var name = ""
    @State private var ein = ""
    @State private var notes = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(business == nil ? "Add Business" : "Business Settings").font(.title2.bold())
            Text("Each business gets its own Schedule C. Link business bank accounts to it, or tag individual transactions in shared accounts.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name)
                TextField("EIN (optional)", text: $ein)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
            }
            HStack {
                if business != nil {
                    Button("Delete Business…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(business == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.nilIfBlank == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            name = business?.name ?? ""
            ein = business?.ein ?? ""
            notes = business?.notes ?? ""
        }
        .confirmationDialog("Delete \(business?.name ?? "")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let business { context.delete(business); try? context.save() }
                dismiss()
            }
        } message: {
            Text("Transactions and accounts stay; they just lose their link to this business. Vehicles stay but are unassigned.")
        }
    }

    private func save() {
        guard let n = name.nilIfBlank else { return }
        let b = business ?? Business(name: n)
        if business == nil { context.insert(b) }
        b.name = n
        b.ein = ein.nilIfBlank
        b.notes = notes.nilIfBlank
        try? context.save()
        if business == nil { onCreated(b) }
        dismiss()
    }
}

// MARK: - Schedule C

struct ScheduleCView: View {
    @Environment(\.modelContext) private var context
    @Environment(LedgerIndex.self) private var index
    let business: Business
    var onFixLines: () -> Void

    @State private var year = Day.year(of: Day.today)
    @State private var custom = false
    @State private var from = Day.startOfYear(Day.today)
    @State private var to = Day.today
    @State private var report: ScheduleCReport?
    @State private var exporting = false
    @State private var showZero = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PeriodPicker(year: $year, custom: $custom, from: $from, to: $to)
                Toggle("Show empty lines", isOn: $showZero).toggleStyle(.checkbox)
                Spacer()
                Button { exporting = true } label: { Label("Export CSV for accountant", systemImage: "square.and.arrow.up") }
                    .disabled(report == nil)
            }
            .padding(12)
            Divider()
            if let report { content(report) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: "\(index.version)|\(year)|\(custom)|\(from)|\(to)") {
            report = ScheduleCReport(business: business, range: PeriodPicker.range(year: year, custom: custom, from: from, to: to), context: context)
        }
        .fileExporter(isPresented: $exporting, document: CSVDocument(text: report?.csv() ?? ""), contentType: .commaSeparatedText,
                      defaultFilename: "\(business.name) Schedule C \(custom ? "custom" : String(year))") { _ in }
    }

    private func content(_ r: ScheduleCReport) -> some View {
        List {
            if !r.needsLine.isEmpty {
                Section {
                    HStack {
                        Label("\(r.needsLine.count) business transactions have no Schedule C line (\(Cents.string(r.needsLine.reduce(0) { $0 + $1.cents })))",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Assign lines…", action: onFixLines)
                    }
                    DisclosureGroup("Show them") { itemList(r.needsLine) }
                }
            }
            Section("Part I · Income") {
                lineRow(r, .grossReceipts)
                lineRow(r, .returnsAllowances)
                totalRow("Line 3 · Subtract line 2 from line 1", r.grossReceipts)
                totalRow("Line 4 · Cost of goods sold (Part III)", r.costOfGoodsSold)
                totalRow("Line 5 · Gross profit", r.grossProfit)
                lineRow(r, .otherIncome)
                totalRow("Line 7 · Gross income", r.grossIncome, bold: true)
            }
            if r.costOfGoodsSold != 0 || showZero {
                Section("Part III · Cost of Goods Sold") {
                    ForEach([TaxLine.cogsPurchases, .cogsLabor, .cogsMaterials, .cogsOther]) { lineRow(r, $0) }
                }
            }
            Section("Part II · Expenses") {
                ForEach(TaxLine.allCases.filter { $0.part == .expenses }) { line in
                    if showZero || r.cents(line) != 0 { lineRow(r, line) }
                }
                totalRow("Line 28 · Total expenses", r.totalExpenses, bold: true)
                totalRow("Line 31 · Net profit (loss)", r.netProfit, bold: true)
            }
            ForEach(r.vehicles) { v in
                Section("Part IV · \(v.name)") { vehicleSummary(v) }
            }
            if !r.otherExpenseBreakdown.isEmpty {
                Section("Part V · Other expenses") {
                    ForEach(r.otherExpenseBreakdown, id: \.label) { o in
                        HStack { Text(o.label); Spacer(); Text(Cents.string(o.cents)).monospacedDigit() }
                    }
                }
            }
            let tracked = [TaxLine.capitalPurchase, .notDeductible].filter { r.lines[$0] != nil }
            if !tracked.isEmpty {
                Section("Tracked, not deducted") {
                    ForEach(tracked) { lineRow(r, $0) }
                }
            }
        }
    }

    @ViewBuilder private func lineRow(_ r: ScheduleCReport, _ line: TaxLine) -> some View {
        let total = r.lines[line]
        let amount = line.part == .other ? (total?.cents ?? 0) : r.cents(line)
        DisclosureGroup {
            if line == .meals, let t = total {
                Text("\(Cents.string(t.cents)) spent · 50% deductible").font(.caption).foregroundStyle(.secondary)
            }
            if line == .carTruck, !r.vehicles.isEmpty {
                Text("Includes vehicle worksheet amounts (see Part IV)").font(.caption).foregroundStyle(.secondary)
            }
            itemList(total?.items ?? [])
        } label: {
            HStack {
                Text(line.label)
                Spacer()
                if let n = total?.items.count, n > 0 { Text("\(n)").font(.caption).foregroundStyle(.secondary) }
                Text(Cents.string(amount)).monospacedDigit().frame(width: 120, alignment: .trailing)
            }
        }
        .disabled((total?.items.isEmpty ?? true) && line != .carTruck)
    }

    private func totalRow(_ title: String, _ cents: Int, bold: Bool = false) -> some View {
        HStack {
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(Cents.string(cents)).monospacedDigit().fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(cents < 0 ? .red : .primary)
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.leading, 18)
    }

    private func itemList(_ items: [ScheduleCReport.Item]) -> some View {
        ForEach(items) { i in
            HStack(spacing: 10) {
                Text(Day.string(i.date)).monospacedDigit().frame(width: 76, alignment: .leading)
                Text(i.payee).frame(width: 180, alignment: .leading).lineLimit(1)
                Text(i.category).foregroundStyle(.secondary).frame(width: 180, alignment: .leading).lineLimit(1)
                Text(i.memo).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if i.percent != 100 { Text("\(i.percent)%").font(.caption).foregroundStyle(.secondary) }
                Text(i.account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(Cents.string(i.cents)).monospacedDigit().frame(width: 100, alignment: .trailing)
            }
            .font(.callout)
        }
    }

    private func vehicleSummary(_ v: ScheduleCReport.VehicleSummary) -> some View {
        Group {
            HStack { Text("Method"); Spacer(); Text(v.usesStandardRate ? "Standard mileage rate" : "Actual expenses") }
            if let d = v.placedInService { HStack { Text("Placed in service"); Spacer(); Text(Day.string(d)) } }
            HStack { Text("Business miles"); Spacer(); Text(miles(v.businessTenths)).monospacedDigit() }
            HStack { Text("Commuting miles"); Spacer(); Text(miles(v.commutingTenths)).monospacedDigit() }
            HStack { Text("Other miles"); Spacer(); Text(miles(max(0, v.totalTenths - v.businessTenths - v.commutingTenths))).monospacedDigit() }
            HStack { Text("Business use"); Spacer(); Text(v.businessPercent, format: .percent.precision(.fractionLength(1))) }
            ForEach(v.expenses.sorted { $0.key.title < $1.key.title }, id: \.key) { k, c in
                HStack { Text(k.title).foregroundStyle(.secondary); Spacer(); Text(Cents.string(c)).monospacedDigit() }
            }
            if v.usesStandardRate {
                HStack { Text("Standard mileage deduction"); Spacer(); Text(Cents.string(v.standardMileageCents)).monospacedDigit() }
            }
            if !v.missingRateYears.isEmpty {
                Label("No IRS mileage rate set for \(v.missingRateYears.map(String.init).joined(separator: ", ")) — add it under Vehicles & Mileage.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack { Text("Line 9 amount").fontWeight(.semibold); Spacer(); Text(Cents.string(v.line9Cents)).monospacedDigit().fontWeight(.semibold) }
        }
    }

    private func miles(_ tenths: Int) -> String { String(format: "%.1f", Double(tenths) / 10) }
}

/// Side-by-side totals for every business.
struct AllBusinessesView: View {
    @Environment(\.modelContext) private var context
    @Environment(LedgerIndex.self) private var index
    @Query(sort: \Business.name) private var businesses: [Business]
    @State private var year = Day.year(of: Day.today)
    @State private var custom = false
    @State private var from = Day.startOfYear(Day.today)
    @State private var to = Day.today
    @State private var reports: [ScheduleCReport] = []

    var body: some View {
        VStack(alignment: .leading) {
            PeriodPicker(year: $year, custom: $custom, from: $from, to: $to).padding(12)
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("Business").gridColumnAlignment(.leading)
                    Text("Gross income"); Text("Expenses"); Text("Net profit"); Text("Needs a line")
                }
                .font(.caption.bold())
                ForEach(reports, id: \.business) { r in
                    GridRow {
                        Text(r.business)
                        Text(Cents.string(r.grossIncome)).monospacedDigit()
                        Text(Cents.string(r.totalExpenses)).monospacedDigit()
                        Text(Cents.string(r.netProfit)).monospacedDigit().foregroundStyle(r.netProfit < 0 ? .red : .primary)
                        Text(r.needsLine.isEmpty ? "—" : "\(r.needsLine.count)").foregroundStyle(r.needsLine.isEmpty ? Color.secondary : .orange)
                    }
                }
                Divider()
                GridRow {
                    Text("Total").bold()
                    Text(Cents.string(reports.reduce(0) { $0 + $1.grossIncome })).monospacedDigit().bold()
                    Text(Cents.string(reports.reduce(0) { $0 + $1.totalExpenses })).monospacedDigit().bold()
                    Text(Cents.string(reports.reduce(0) { $0 + $1.netProfit })).monospacedDigit().bold()
                    Text("")
                }
            }
            .padding(12)
            Spacer()
        }
        .navigationTitle("All Businesses")
        .task(id: "\(index.version)|\(year)|\(custom)|\(from)|\(to)") {
            let range = PeriodPicker.range(year: year, custom: custom, from: from, to: to)
            reports = businesses.map { ScheduleCReport(business: $0, range: range, context: context) }
        }
    }
}
