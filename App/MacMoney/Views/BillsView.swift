import SwiftUI
import SwiftData

/// Money's "Bills summary": recurring bills and deposits. Select one to edit it, enter its next
/// occurrence into the register, or skip it.
struct BillsView: View {
    @Environment(\.modelContext) private var context
    @Query private var bills: [Bill]
    @State private var showFinished = false
    @State private var selection: PersistentIdentifier?
    @State private var sortOrder = [KeyPathComparator(\BillRow.nextDue)]
    @State private var entering: Bill?
    @State private var showPreload = false
    @State private var showInspector = true
    @State private var pendingDelete: Bill?

    private var rows: [BillRow] {
        bills.filter { showFinished || $0.isActive }.map(BillRow.init).sorted(using: sortOrder)
    }

    private var selected: Bill? {
        selection.flatMap { id in bills.first { $0.persistentModelID == id } }
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Payee", value: \.payee) { r in
                Text(r.payee).foregroundStyle(r.bill.isActive ? .primary : .secondary)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Amount", value: \.amount) { r in
                Text(Cents.string(r.amount)).monospacedDigit()
                    .foregroundStyle(r.amount < 0 ? Color.red : Color.green)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Due date", value: \.nextDue) { r in
                HStack(spacing: 4) {
                    Text(Day.string(r.nextDue)).monospacedDigit()
                    if r.bill.isActive && r.nextDue < Day.today {
                        Text("OVERDUE").font(.caption2.bold()).foregroundStyle(.orange)
                    }
                }
            }
            .width(min: 90, ideal: 130)
            TableColumn("Frequency", value: \.frequencySort) { r in Text(r.bill.frequencyLabel) }
                .width(min: 100, ideal: 140)
            TableColumn("Category", value: \.category) { r in Text(r.category).foregroundStyle(.secondary) }
                .width(min: 100, ideal: 200)
            TableColumn("Account", value: \.account) { r in Text(r.account) }
                .width(min: 100, ideal: 160)
            TableColumn("Ends", value: \.endsSort) { r in
                Text(r.bill.endDate.map(Day.string) ?? r.bill.remainingOccurrences.map { "\($0) left" } ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if let id = ids.first, let bill = bills.first(where: { $0.persistentModelID == id }), bill.isActive {
                Button("Enter in Register…") { entering = bill }
                Button("Skip This Occurrence") { BillStore(context: context).skip(bill) }
                Divider()
                Button("Delete Bill…", role: .destructive) { pendingDelete = bill }
            }
        } primaryAction: { ids in
            if let id = ids.first, let bill = bills.first(where: { $0.persistentModelID == id }), bill.isActive { entering = bill }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let selected {
                    BillEditor(bill: selected, onEnter: { entering = selected })
                        .id(selected.persistentModelID)
                } else {
                    ContentUnavailableView("Select a bill", systemImage: "calendar.badge.clock",
                                           description: Text("Edit its schedule, or enter it into the register. Double-click a bill to enter it."))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .navigationTitle("Bills & Deposits")
        .navigationSubtitle("\(bills.filter(\.isActive).count) active")
        .toolbar {
            ToolbarItemGroup {
                Button { showPreload = true } label: { Label("Enter Bills Due…", systemImage: "tray.and.arrow.down") }
                    .help("Enter every bill due through a date into the registers")
                Button { newBill() } label: { Label("New Bill", systemImage: "plus") }
                Toggle("Show finished", isOn: $showFinished)
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
            }
        }
        .sheet(item: $entering) { EnterBillSheet(bill: $0) }
        .confirmationDialog("Delete this bill?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { bill in
            Button("Delete", role: .destructive) {
                if selection == bill.persistentModelID { selection = nil }
                context.delete(bill)
                try? context.save()
            }
        } message: { bill in
            Text("\(bill.displayName) · \(Cents.string(bill.amountCents)) · \(bill.frequencyLabel)\n\nTransactions already entered from it stay in the register.")
        }
        .sheet(isPresented: $showPreload) { PreloadBillsSheet() }
    }

    private func newBill() {
        let bill = Bill(amountCents: 0, nextDue: Day.today)
        bill.anchorDay = Day.calendar.component(.day, from: Day.today)
        bill.account = (try? context.fetch(FetchDescriptor<Account>()))?.first { !$0.isClosed && $0.kind == .bank }
        context.insert(bill)
        try? context.save()
        selection = bill.persistentModelID
        showInspector = true
    }
}

/// Flattened, sortable view of a bill.
struct BillRow: Identifiable {
    let bill: Bill
    let payee: String
    let amount: Int
    let nextDue: Date
    let category: String
    let account: String
    let frequencySort: Int
    let endsSort: Date

    init(_ b: Bill) {
        bill = b
        payee = b.displayName
        amount = b.amountCents
        nextDue = b.nextDue
        category = b.category?.fullName ?? ""
        account = b.account?.name ?? ""
        let days: Int = switch b.unit {
        case .once: 0
        case .week: 7 * b.every
        case .semimonth: 15
        case .month: 30 * b.every
        case .year: 365 * b.every
        }
        frequencySort = days
        endsSort = b.endDate ?? .distantFuture
    }

    var id: PersistentIdentifier { bill.persistentModelID }
}

// MARK: - Editor

struct BillEditor: View {
    @Environment(\.modelContext) private var context
    @Bindable var bill: Bill
    var onEnter: () -> Void

    @Query(sort: \Account.name) private var accountsByName: [Account]
    private var accounts: [Account] { accountsByName.inSidebarOrder }
    @Environment(LedgerIndex.self) private var index

    @State private var payeeName = ""
    @State private var categoryName = ""
    @State private var amount = ""
    @State private var kind: EntryDraft.Kind = .withdrawal
    @State private var ending: Ending = .never

    enum Ending: String, CaseIterable { case never = "Never", onDate = "On date", afterCount = "After" }

    var body: some View {
        Form {
            Section {
                HStack {
                    Button { onEnter() } label: { Label("Enter in Register…", systemImage: "square.and.arrow.down.on.square") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!bill.isActive || bill.account == nil)
                    Button("Skip") { BillStore(context: context).skip(bill) }
                        .disabled(!bill.isActive)
                        .help("Advance to the following due date without entering this one")
                }
            }

            Section("Transaction") {
                Picker("Type", selection: $kind) {
                    ForEach(EntryDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { applyKind() }
                TextField(kind == .deposit ? "From" : "Pay to", text: $payeeName)
                    .textInputSuggestions { suggestions(index.payeeNames, payeeName) }
                    .onSubmit { commitPayee() }
                Picker("Account", selection: $bill.account) {
                    Text("None").tag(Account?.none)
                    ForEach(accounts.filter { !$0.isClosed }) { Text($0.name).tag(Optional($0)) }
                }
                if kind == .transfer {
                    Picker("Transfer to", selection: $bill.transferAccount) {
                        Text("Choose…").tag(Account?.none)
                        ForEach(accounts.filter { !$0.isClosed && $0 !== bill.account }) { Text($0.name).tag(Optional($0)) }
                    }
                } else {
                    TextField("Category", text: $categoryName)
                        .textInputSuggestions { suggestions(index.categoryNames, categoryName) }
                        .onSubmit { commitCategory() }
                }
                TextField("Amount", text: $amount)
                    .monospacedDigit()
                    .onSubmit { commitAmount() }
                TextField("Number", text: Binding(get: { bill.number ?? "" }, set: { bill.number = $0.nilIfBlank }))
                TextField("Memo", text: Binding(get: { bill.memo ?? "" }, set: { bill.memo = $0.nilIfBlank }))
            }

            Section("Schedule") {
                DatePicker("Next due", selection: Binding(get: { Day.toLocal(bill.nextDue) }, set: {
                    bill.nextDue = Day.normalize($0)
                    bill.anchorDay = Day.calendar.component(.day, from: bill.nextDue)
                }), displayedComponents: .date)
                Picker("Repeats", selection: $bill.unitRaw) {
                    Text("Only once").tag(RecurrenceUnit.once.rawValue)
                    Text("Weekly").tag(RecurrenceUnit.week.rawValue)
                    Text("Twice a month").tag(RecurrenceUnit.semimonth.rawValue)
                    Text("Monthly").tag(RecurrenceUnit.month.rawValue)
                    Text("Yearly").tag(RecurrenceUnit.year.rawValue)
                }
                if bill.unit == .week || bill.unit == .month || bill.unit == .year {
                    Stepper("Every \(bill.every) \(unitWord)", value: $bill.every, in: 1...52)
                }
                Text(bill.frequencyLabel).foregroundStyle(.secondary)
                Picker("Ends", selection: $ending) {
                    ForEach(Ending.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: ending) { applyEnding() }
                if ending == .onDate {
                    DatePicker("End date", selection: Binding(get: { Day.toLocal(bill.endDate ?? bill.nextDue) },
                                                              set: { bill.endDate = Day.normalize($0) }), displayedComponents: .date)
                }
                if ending == .afterCount {
                    Stepper("\(bill.remainingOccurrences ?? 1) more payments", value: Binding(get: { bill.remainingOccurrences ?? 1 },
                                                                                             set: { bill.remainingOccurrences = $0 }), in: 1...999)
                }
                Toggle("Flag when entered (auto-pay scheduled)", isOn: $bill.flagOnEnter)
                Toggle("Active", isOn: $bill.isActive)
            }

            Section("Upcoming") {
                ForEach(bill.occurrences(through: Day.adding(.month, 6, to: Day.today)).prefix(8), id: \.self) { d in
                    HStack {
                        Text(Day.mediumFormatter.string(from: d))
                        Spacer()
                        Text(Cents.string(bill.amountCents)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            if bill.moneySeriesId != nil {
                Text("Imported from Money — a re-import replaces changes made here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onDisappear { commitPayee(); commitCategory(); commitAmount() }
    }

    private var unitWord: String {
        switch bill.unit {
        case .week: bill.every == 1 ? "week" : "weeks"
        case .year: bill.every == 1 ? "year" : "years"
        default: bill.every == 1 ? "month" : "months"
        }
    }

    @ViewBuilder
    private func suggestions(_ names: [String], _ text: String) -> some View {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = q.isEmpty ? [] : names.filter { $0.lowercased().hasPrefix(q) || $0.lowercased().contains(" " + q) }.prefix(12)
        ForEach(Array(matches), id: \.self) { Text($0).textInputCompletion($0) }
    }

    private func load() {
        payeeName = bill.payee?.name ?? ""
        categoryName = bill.category?.fullName ?? ""
        amount = Cents.plain(bill.amountCents)
        kind = bill.transferAccount != nil ? .transfer : (bill.amountCents > 0 ? .deposit : .withdrawal)
        ending = bill.endDate != nil ? .onDate : (bill.remainingOccurrences != nil ? .afterCount : .never)
    }

    private func applyKind() {
        if kind != .transfer { bill.transferAccount = nil }
        commitAmount()
    }

    private func applyEnding() {
        switch ending {
        case .never: bill.endDate = nil; bill.remainingOccurrences = nil
        case .onDate: bill.remainingOccurrences = nil; bill.endDate = bill.endDate ?? Day.adding(.year, 1, to: bill.nextDue)
        case .afterCount: bill.endDate = nil; bill.remainingOccurrences = bill.remainingOccurrences ?? 12
        }
    }

    private func commitPayee() {
        guard payeeName != (bill.payee?.name ?? "") else { return }
        bill.payee = EntryStore(context: context).payee(named: payeeName)
        try? context.save()
    }

    private func commitCategory() {
        guard kind != .transfer, categoryName != (bill.category?.fullName ?? "") else { return }
        bill.category = EntryStore(context: context).category(named: categoryName)
        try? context.save()
    }

    private func commitAmount() {
        guard let c = Cents.parse(amount) else { return }
        bill.amountCents = kind == .deposit ? abs(c) : -abs(c)
        amount = Cents.plain(bill.amountCents)
        try? context.save()
    }
}

// MARK: - Entering bills

/// Confirms one occurrence (date/amount can be adjusted, like Money's "Enter" dialog).
struct EnterBillSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let bill: Bill
    @State private var draft = EntryDraft()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter \(bill.displayName)").font(.title2.bold())
            Text("Into \(bill.account?.name ?? "—") · \(bill.frequencyLabel)").foregroundStyle(.secondary)
            Form {
                DatePicker("Date", selection: Binding(get: { Day.toLocal(draft.date) }, set: { draft.date = Day.normalize($0) }),
                           displayedComponents: .date)
                TextField("Amount", text: $draft.amount).monospacedDigit()
                TextField("Number", text: $draft.number)
                TextField("Memo", text: $draft.memo)
                Toggle("Flag (auto-pay scheduled)", isOn: $draft.isFlagged)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Skip This One") { BillStore(context: context).skip(bill); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enter") {
                    do { try BillStore(context: context).enter(bill, as: draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { draft = BillStore(context: context).draft(for: bill) }
    }
}

/// Preloads the registers: every active bill occurrence due through a chosen date.
struct PreloadBillsSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var bills: [Bill]
    @State private var through = Day.adding(.month, 1, to: Day.today)
    @State private var excluded = Set<String>()
    @State private var error: String?

    private struct Item: Identifiable {
        let bill: Bill
        let date: Date
        var id: String { "\(bill.uuid)-\(date.timeIntervalSince1970)" }
    }

    private var items: [Item] {
        bills.filter { $0.isActive && $0.account != nil }
            .flatMap { b in b.occurrences(through: through).map { Item(bill: b, date: $0) } }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter Bills Due").font(.title2.bold())
            DatePicker("Enter everything due through", selection: Binding(get: { Day.toLocal(through) }, set: { through = Day.normalize($0) }),
                       displayedComponents: .date)
            List(items) { item in
                Toggle(isOn: Binding(get: { !excluded.contains(item.id) },
                                     set: { if $0 { excluded.remove(item.id) } else { excluded.insert(item.id) } })) {
                    HStack {
                        Text(Day.string(item.date)).monospacedDigit().frame(width: 80, alignment: .leading)
                        Text(item.bill.displayName)
                        Spacer()
                        Text(item.bill.account?.name ?? "").foregroundStyle(.secondary)
                        Text(Cents.string(item.bill.amountCents)).monospacedDigit().frame(width: 100, alignment: .trailing)
                    }
                }
            }
            .frame(minHeight: 300)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text("Unchecked bills keep their due date; their later dates aren't entered either.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enter Selected") { enterAll() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(items.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
    }

    private func enterAll() {
        let store = BillStore(context: context)
        // Items are in date order, so each bill's nextDue matches the occurrence being entered.
        // Unchecking an occurrence leaves it (and that bill's later ones) unentered.
        var held = Set<UUID>()
        for item in items {
            if held.contains(item.bill.uuid) || excluded.contains(item.id) {
                held.insert(item.bill.uuid)
                continue
            }
            do { try store.enter(item.bill, as: store.draft(for: item.bill, date: item.date)) }
            catch { self.error = error.localizedDescription; return }
        }
        dismiss()
    }
}
