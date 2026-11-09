import SwiftUI
import SwiftData

/// Money-style transaction form under the register: Withdrawal / Deposit / Transfer.
struct EntryFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(LedgerIndex.self) private var index
    @Query(sort: \Account.name) private var accountsByName: [Account]
    private var accounts: [Account] { accountsByName.inSidebarOrder }
    @Query(sort: \Business.name) private var businesses: [Business]
    @Query(sort: \Vehicle.name) private var vehicles: [Vehicle]

    let account: Account
    let entry: Entry?
    /// A field to jump into (set by double-clicking a register cell); cleared once taken.
    var focusRequest: Binding<Field?> = .constant(nil)
    var onSaved: (Entry?) -> Void

    @State private var draft = EntryDraft()
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case payee, date, category, number, memo, amount, status }

    private var readOnly: Bool { account.isReadOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $draft.kind) {
                    ForEach(EntryDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                Spacer()
                if entry?.moneyId != nil {
                    Label("From Money — replaced on next re-import", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("New") { onSaved(nil) }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(readOnly)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(draft.kind == .deposit ? "From:" : "Pay to:").gridColumnAlignment(.trailing)
                    TextField("Payee", text: $draft.payeeName)
                        .textInputSuggestions { suggestions(index.payeeNames, matching: draft.payeeName) }
                        .focused($focus, equals: .payee)
                        .onSubmit { fillFromLastUse() }
                    Text("Date:").gridColumnAlignment(.trailing)
                    DatePicker("", selection: dateBinding, displayedComponents: .date).labelsHidden()
                        .focused($focus, equals: .date)
                }
                GridRow {
                    if draft.kind == .transfer {
                        Picker("", selection: $draft.transferIncoming) {
                            Text("To account:").tag(false)
                            Text("From account:").tag(true)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker("", selection: $draft.transferAccountID) {
                            Text("Choose…").tag(PersistentIdentifier?.none)
                            ForEach(accounts.filter { $0 !== account && !$0.isClosed }) { a in
                                Text(a.name).tag(Optional(a.persistentModelID))
                            }
                        }
                        .labelsHidden()
                        .focused($focus, equals: .category)
                    } else {
                        Text("Category:")
                        if entry?.isSplit == true {
                            Text("Split — see lines below").foregroundStyle(.secondary)
                        } else {
                            TextField("Category", text: $draft.categoryName)
                                .textInputSuggestions { suggestions(index.categoryNames, matching: draft.categoryName) }
                                .focused($focus, equals: .category)
                        }
                    }
                    Text("Number:")
                    TextField("Num", text: $draft.number).frame(width: 140)
                        .focused($focus, equals: .number)
                }
                GridRow {
                    Text("Memo:")
                    TextField("Memo", text: $draft.memo, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focus, equals: .memo)
                    Text("Amount:")
                    TextField("0.00", text: $draft.amount)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                        .focused($focus, equals: .amount)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Picker("Status", selection: $draft.status) {
                        ForEach(ClearedStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .focusable()
                    .focused($focus, equals: .status)
                    .onKeyPress(action: statusKey)
                    .help("When selected: U, C or R, or ← →, to change")
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack {
                        Toggle(isOn: $draft.isFlagged) { Label("Flag", systemImage: draft.isFlagged ? "flag.fill" : "flag") }
                            .toggleStyle(.button)
                            .foregroundStyle(draft.isFlagged ? .red : .secondary)
                            .help("Flag this transaction (e.g. auto bill pay is scheduled). Cleared when reconciled.")
                        Button("Cancel") { load() }.keyboardShortcut(.cancelAction)
                        Button(entry == nil ? "Enter" : "Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            if !businesses.isEmpty && draft.kind != .transfer {
                businessRow
            }
            if draft.isFlagged {
                HStack(spacing: 12) {
                    Image(systemName: "flag.fill").foregroundStyle(.red)
                    TextField("Flag note (e.g. auto-pay scheduled 11/1)", text: $draft.flagNote)
                    Toggle("Action date", isOn: Binding(get: { draft.flagDate != nil },
                                                        set: { draft.flagDate = $0 ? (draft.flagDate ?? draft.date) : nil }))
                        .toggleStyle(.checkbox)
                    if draft.flagDate != nil {
                        DatePicker("", selection: Binding(get: { Day.toLocal(draft.flagDate ?? draft.date) },
                                                          set: { draft.flagDate = Day.normalize($0) }),
                                   displayedComponents: .date)
                            .labelsHidden()
                    }
                }
            }
            if !draft.isFlagged, !draft.flagNote.isEmpty {
                Label("Earlier flag note: \(draft.flagNote)\(draft.flagDate.map { " (\(Day.string($0)))" } ?? "")", systemImage: "flag")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let entry, entry.isSplit {
                splitLines(entry)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .disabled(readOnly)
        .padding()
        .background(.background.secondary)
        .onAppear {
            load()
            takeFocusRequest()
        }
        .onChange(of: focusRequest.wrappedValue) { takeFocusRequest() }
    }

    private func takeFocusRequest() {
        guard let field = focusRequest.wrappedValue else { return }
        focusRequest.wrappedValue = nil
        guard !readOnly else { return }
        // Wait a turn so the register's double-click finishes before the field takes the keyboard.
        DispatchQueue.main.async { focus = field }
    }

    /// Keyboard for the status control: U / C / R pick directly, arrows step through.
    private func statusKey(_ press: KeyPress) -> KeyPress.Result {
        let all = ClearedStatus.allCases
        let i = all.firstIndex(of: draft.status) ?? 0
        switch press.key {
        case .leftArrow: draft.status = all[max(0, i - 1)]; return .handled
        case .rightArrow: draft.status = all[min(all.count - 1, i + 1)]; return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "u": draft.status = .uncleared
        case "c": draft.status = .cleared
        case "r": draft.status = .reconciled
        default: return .ignored
        }
        return .handled
    }

    /// Business tagging: which business (or personal), Schedule C line, business-use %, vehicle.
    private var businessRow: some View {
        let accountBusiness = account.business
        let effective: Business? = draft.isPersonal ? nil
            : (draft.businessID.flatMap { id in businesses.first { $0.persistentModelID == id } } ?? accountBusiness)
        return HStack(spacing: 12) {
            Image(systemName: "briefcase").foregroundStyle(effective == nil ? Color.secondary : Color.accentColor)
            Picker("Business", selection: Binding<String>(
                get: { draft.isPersonal ? "personal" : (draft.businessID.map { "\($0.hashValue)" } ?? "default") },
                set: { v in
                    if v == "personal" { draft.isPersonal = true; draft.businessID = nil }
                    else if v == "default" { draft.isPersonal = false; draft.businessID = nil }
                    else { draft.isPersonal = false; draft.businessID = businesses.first { "\($0.persistentModelID.hashValue)" == v }?.persistentModelID }
                })) {
                Text(accountBusiness.map { "Account default (\($0.name))" } ?? "Personal (default)").tag("default")
                Text("Personal").tag("personal")
                Divider()
                ForEach(businesses) { Text($0.name).tag("\($0.persistentModelID.hashValue)") }
            }
            .frame(width: 260)
            if effective != nil {
                Picker("Line", selection: $draft.taxLine) {
                    Text(categoryLineLabel).tag(TaxLine?.none)
                    Divider()
                    ForEach(TaxLine.allCases) { Text($0.label).tag(Optional($0)) }
                }
                .frame(width: 280)
                Stepper("\(draft.businessPercent)% business", value: $draft.businessPercent, in: 1...100, step: 5)
                    .frame(width: 150)
                let mine = vehicles.filter { $0.business == effective }
                if !mine.isEmpty {
                    Picker("Vehicle", selection: $draft.vehicleID) {
                        Text("None").tag(PersistentIdentifier?.none)
                        ForEach(mine) { Text($0.name).tag(Optional($0.persistentModelID)) }
                    }
                    .frame(width: 180)
                    if draft.vehicleID != nil {
                        Picker("", selection: $draft.vehicleExpense) {
                            ForEach(VehicleExpense.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
            }
        }
        .font(.callout)
    }

    private var categoryLineLabel: String {
        let line = EntryStore(context: context).category(named: draft.categoryName)?.scheduleCLine.flatMap(TaxLine.init)
        return line.map { "Category: Line \($0.rawValue)" } ?? "Category line (not set)"
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { Day.toLocal(draft.date) }, set: { draft.date = Day.normalize($0) })
    }

    @ViewBuilder
    private func suggestions(_ names: [String], matching text: String) -> some View {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = q.isEmpty ? [] : names.filter { $0.lowercased().hasPrefix(q) || $0.lowercased().contains(" " + q) }.prefix(12)
        ForEach(Array(matches), id: \.self) { Text($0).textInputCompletion($0) }
    }

    private func splitLines(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Split lines").font(.caption).foregroundStyle(.secondary)
            ForEach(entry.sortedSplits) { s in
                HStack {
                    Text(s.category?.fullName ?? "(no category)")
                    Text(s.memo ?? "").foregroundStyle(.secondary)
                    Spacer()
                    Text(Cents.string(s.amountCents)).monospacedDigit()
                }
                .font(.callout)
            }
            let remainder = entry.amountCents - entry.sortedSplits.reduce(0) { $0 + $1.amountCents }
            if remainder != 0 {
                HStack {
                    Text("Unassigned").foregroundStyle(.orange)
                    Spacer()
                    Text(Cents.string(remainder)).monospacedDigit().foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
    }

    private func load() {
        error = nil
        draft = entry.map(EntryDraft.init) ?? EntryDraft()
        if entry == nil { focus = .payee }
    }

    /// Money's "AutoComplete": typing a known payee fills category and amount from the most recent use.
    private func fillFromLastUse() {
        guard entry == nil, draft.categoryName.isEmpty, draft.amount.isEmpty else { return }
        let name = draft.payeeName.lowercased()
        guard let row = index.rowsByAccount[account.persistentModelID]?.last(where: { $0.payee.lowercased() == name }),
              let last = context.model(for: row.id) as? Entry else { return }
        let template = EntryDraft(last)
        draft.kind = template.kind
        draft.categoryName = template.categoryName
        draft.amount = template.amount
        draft.transferAccountID = template.transferAccountID
        focus = .amount
    }

    private func save() {
        do {
            if draft.kind == .transfer && draft.transferAccountID == nil {
                error = "Choose the account to transfer to."
                return
            }
            let saved = try EntryStore(context: context).save(draft, into: account, editing: entry)
            onSaved(entry == nil ? nil : saved)
            if entry == nil { load() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
