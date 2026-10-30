import SwiftUI
import SwiftData

/// Create, rename and edit what-if scenarios. Each scenario is a list of changes laid over the forecast.
struct ScenariosView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Scenario.name) private var scenarios: [Scenario]
    @Query(sort: \Account.name) private var accountsByName: [Account]
    private var accounts: [Account] { accountsByName.inSidebarOrder }
    @Query private var bills: [Bill]
    /// The scenario shown in the forecast (uuid string); new scenarios become the shown one.
    @Binding var chosen: String
    @State private var selected: Scenario?
    @State private var editing: ScenarioItem?
    @State private var pendingDelete: Scenario?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Divider()
                if let selected {
                    detail(selected).id(selected.uuid)
                } else {
                    ContentUnavailableView("No Scenario", systemImage: "wand.and.stars",
                                           description: Text("Add a scenario to try out a what-if: a new car payment, a raise, losing a client."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("Scenarios are only projections. They never change your registers or bills.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 860, height: 540)
        .onAppear { selected = scenarios.first { $0.uuid.uuidString == chosen } ?? scenarios.first }
        .sheet(item: $editing) { item in
            ScenarioItemEditor(item: item, accounts: accounts.filter { !$0.isClosed }, bills: bills.filter(\.isActive)) {
                item.scenario?.modified = Date()
                try? context.save()
            } onCancel: {
                // A brand-new item that was cancelled is thrown away.
                if item.name.isEmpty && item.amountCents == 0 && item.billUUID == nil {
                    context.delete(item)
                    try? context.save()
                }
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { s in
            Button("Delete Scenario", role: .destructive) { delete(s) }
        } message: { s in
            Text("Its \((s.items ?? []).count) changes will be deleted too.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selected?.uuid }, set: { id in selected = scenarios.first { $0.uuid == id } })) {
                ForEach(scenarios) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name.isEmpty ? "Untitled" : s.name)
                        Text("\((s.items ?? []).count) changes").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(s.uuid)
                    .contextMenu {
                        Button("Duplicate") { duplicate(s) }
                        Button("Delete…", role: .destructive) { pendingDelete = s }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 4) {
                Button { add() } label: { Image(systemName: "plus") }.help("New scenario")
                Button { if let selected { pendingDelete = selected } } label: { Image(systemName: "minus") }
                    .disabled(selected == nil).help("Delete scenario")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func detail(_ s: Scenario) -> some View {
        @Bindable var s = s
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $s.name, prompt: Text("Scenario name"))
                .textFieldStyle(.plain).font(.title2.bold())
                .onSubmit { touch(s) }
            TextField("Notes", text: $s.notes, prompt: Text("Notes (optional)"), axis: .vertical)
                .lineLimit(1...3).foregroundStyle(.secondary)
                .onSubmit { touch(s) }
            HStack {
                Text("Changes").font(.headline)
                Spacer()
                Menu {
                    ForEach(ScenarioKind.allCases) { k in
                        Button { addItem(k, to: s) } label: { Label(k.label, systemImage: k.symbol) }
                    }
                } label: { Label("Add Change", systemImage: "plus") }
                    .fixedSize()
            }
            if s.sortedItems.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "plus.circle",
                                       description: Text("Add a one-time or recurring amount, or change or stop an existing bill."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(s.sortedItems) { item in
                        row(item)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { editing = item }
                            .contextMenu {
                                Button("Edit…") { editing = item }
                                Button("Delete", role: .destructive) { deleteItem(item) }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(16)
        .onDisappear { touch(s) }
    }

    private func row(_ item: ScenarioItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol).foregroundStyle(.purple).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(ScenarioText.title(item, bills: bills))
                Text(ScenarioText.detail(item, accounts: accounts, bills: bills)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.kind != .stopBill {
                Text(Cents.string(item.amountCents)).monospacedDigit()
                    .foregroundStyle(item.amountCents < 0 ? .red : .green)
            }
            Button { editing = item } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
        }
        .padding(.vertical, 2)
    }

    private func touch(_ s: Scenario) {
        s.modified = Date()
        try? context.save()
    }

    private func add() {
        let s = Scenario(name: "New Scenario")
        context.insert(s)
        try? context.save()
        selected = s
        chosen = s.uuid.uuidString
    }

    private func duplicate(_ s: Scenario) {
        let copy = Scenario(name: "\(s.name) copy")
        copy.notes = s.notes
        context.insert(copy)
        for i in s.sortedItems {
            let c = ScenarioItem(kind: i.kind, startDate: i.startDate)
            c.name = i.name; c.amountCents = i.amountCents; c.accountUUID = i.accountUUID; c.billUUID = i.billUUID
            c.endDate = i.endDate; c.unitRaw = i.unitRaw; c.every = i.every
            c.scenario = copy
            context.insert(c)
        }
        try? context.save()
        selected = copy
    }

    private func delete(_ s: Scenario) {
        if chosen == s.uuid.uuidString { chosen = "" }
        if selected == s { selected = nil }
        context.delete(s)
        try? context.save()
        selected = scenarios.first { $0 != s }
    }

    private func addItem(_ kind: ScenarioKind, to s: Scenario) {
        let start = Day.adding(.day, 1, to: Day.today)
        let item = ScenarioItem(kind: kind, startDate: kind == .recurring ? Day.startOfMonth(Day.adding(.month, 1, to: Day.today)) : start)
        item.accountUUID = accounts.first { !$0.isClosed && $0.kind == .bank }?.uuid
        item.scenario = s
        context.insert(item)
        editing = item
    }

    private func deleteItem(_ item: ScenarioItem) {
        item.scenario?.modified = Date()
        context.delete(item)
        try? context.save()
    }
}

/// Human-readable descriptions of scenario changes.
enum ScenarioText {
    static func title(_ item: ScenarioItem, bills: [Bill]) -> String {
        let bill = bills.first { $0.uuid == item.billUUID }?.displayName ?? "a bill (no longer exists)"
        switch item.kind {
        case .oneTime, .recurring: return item.name.isEmpty ? item.kind.label : item.name
        case .changeBill: return "Change \(bill)"
        case .stopBill: return "Stop \(bill)"
        }
    }

    static func detail(_ item: ScenarioItem, accounts: [Account], bills: [Bill]) -> String {
        let account = accounts.first { $0.uuid == item.accountUUID }?.name ?? "no account"
        switch item.kind {
        case .oneTime:
            return "On \(Day.string(item.startDate)) · \(account)"
        case .recurring:
            let freq = frequency(item.unit, item.every)
            let end = item.endDate.map { " through \(Day.string($0))" } ?? ""
            return "\(freq) from \(Day.string(item.startDate))\(end) · \(account)"
        case .changeBill:
            let old = bills.first { $0.uuid == item.billUUID }.map { " (now \(Cents.string($0.amountCents)))" } ?? ""
            return "New amount from \(Day.string(item.startDate))\(old)"
        case .stopBill:
            return "No more occurrences from \(Day.string(item.startDate))"
        }
    }

    static func frequency(_ unit: RecurrenceUnit, _ every: Int) -> String {
        let b = Bill(amountCents: 0, nextDue: Day.today)
        b.unit = unit
        b.every = every
        return b.frequencyLabel
    }
}

/// Edits one change in a scenario.
struct ScenarioItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: ScenarioItem
    let accounts: [Account]
    let bills: [Bill]
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var amount = ""
    @State private var moneyIn = false
    @State private var hasEnd = false
    @State private var frequency = "month.1"
    @State private var error: String?
    @State private var original: ScenarioAdjustment?

    private static let frequencies: [(String, RecurrenceUnit, Int)] = [
        ("Weekly", .week, 1), ("Every other week", .week, 2), ("Twice a month", .semimonth, 1),
        ("Monthly", .month, 1), ("Every other month", .month, 2), ("Every three months", .month, 3),
        ("Twice a year", .month, 6), ("Yearly", .year, 1),
    ]

    private var bill: Bill? { bills.first { $0.uuid == item.billUUID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(item.kind.label, systemImage: item.kind.symbol).font(.title2.bold())
            Form {
                switch item.kind {
                case .oneTime, .recurring:
                    TextField("Description", text: $item.name, prompt: Text(item.kind == .oneTime ? "New laptop" : "Car payment"))
                    Picker("", selection: $moneyIn) {
                        Text("Money out").tag(false)
                        Text("Money in").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    TextField("Amount", text: $amount, prompt: Text("0.00"))
                    Picker("Account", selection: $item.accountUUID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.uuid)) }
                    }
                    DatePicker(item.kind == .oneTime ? "Date" : "Starting", selection: day($item.startDate), displayedComponents: .date)
                    if item.kind == .recurring {
                        Picker("How often", selection: $frequency) {
                            ForEach(Self.frequencies, id: \.0) { f in Text(f.0).tag("\(f.1.rawValue).\(f.2)") }
                        }
                        Toggle("Ends", isOn: $hasEnd)
                        if hasEnd {
                            DatePicker("Last date", selection: day(Binding(get: { item.endDate ?? Day.adding(.year, 1, to: item.startDate) },
                                                                           set: { item.endDate = $0 })), displayedComponents: .date)
                        }
                    }
                case .changeBill, .stopBill:
                    Picker("Bill or deposit", selection: $item.billUUID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(bills.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }, id: \.uuid) { b in
                            Text("\(b.displayName) · \(Cents.string(b.amountCents)) · \(b.frequencyLabel)").tag(Optional(b.uuid))
                        }
                    }
                    if item.kind == .changeBill {
                        TextField("New amount", text: $amount, prompt: Text(bill.map { Cents.plain(abs($0.amountCents)) } ?? "0.00"))
                        DatePicker("Starting", selection: day($item.startDate), displayedComponents: .date)
                    } else {
                        DatePicker("Stops from", selection: day($item.startDate), displayedComponents: .date)
                            .help("Occurrences on or after this date are left out")
                    }
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { revert(); onCancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    private func day(_ b: Binding<Date>) -> Binding<Date> {
        Binding(get: { Day.toLocal(b.wrappedValue) }, set: { b.wrappedValue = Day.normalize($0) })
    }

    private func load() {
        original = item.adjustment
        amount = item.amountCents == 0 ? "" : Cents.plain(abs(item.amountCents))
        moneyIn = item.amountCents > 0
        hasEnd = item.endDate != nil
        frequency = "\(item.unit.rawValue).\(item.every)"
    }

    /// Cancel puts back what was there before the sheet opened.
    private func revert() {
        guard let o = original else { return }
        item.name = o.name
        item.accountUUID = o.accountUUID
        item.billUUID = o.billUUID
        item.startDate = o.startDate
        item.endDate = o.endDate
    }

    private func save() {
        switch item.kind {
        case .oneTime, .recurring:
            guard let c = Cents.parse(amount), c != 0 else { error = "Enter an amount."; return }
            guard item.accountUUID != nil else { error = "Choose an account."; return }
            item.amountCents = moneyIn ? abs(c) : -abs(c)
            if item.kind == .recurring {
                let parts = frequency.split(separator: ".")
                item.unit = RecurrenceUnit(rawValue: String(parts[0])) ?? .month
                item.every = Int(parts[1]) ?? 1
                if !hasEnd { item.endDate = nil } else if item.endDate == nil { item.endDate = Day.adding(.year, 1, to: item.startDate) }
                if let end = item.endDate, end < item.startDate { error = "The last date is before the start."; return }
            } else {
                item.endDate = nil
            }
        case .changeBill:
            guard let bill else { error = "Choose a bill or deposit."; return }
            guard let c = Cents.parse(amount) else { error = "Enter the new amount."; return }
            // Keep the bill's direction: a bill stays money out, a deposit stays money in.
            item.amountCents = bill.amountCents < 0 ? -abs(c) : abs(c)
        case .stopBill:
            guard bill != nil else { error = "Choose a bill or deposit."; return }
        }
        onSave()
        dismiss()
    }
}
