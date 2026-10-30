import SwiftUI
import SwiftData

struct RegisterRow: Identifiable {
    let row: EntryRow
    let balanceCents: Int
    var id: PersistentIdentifier { row.id }
}

enum RegisterFilter: String, CaseIterable, Identifiable {
    case all = "All transactions"
    case unreconciled = "Unreconciled"
    case flagged = "Flagged"
    case uncleared = "Uncleared"
    case last30 = "Last 30 days"
    case last12Months = "Last 12 months"
    case thisYear = "This year"
    case lastYear = "Last year"
    case future = "Upcoming (after today)"

    var id: String { rawValue }

    func includes(_ e: EntryRow, today: Date) -> Bool {
        switch self {
        case .all: true
        case .unreconciled: e.status != .reconciled
        case .flagged: e.isFlagged
        case .uncleared: e.status == .uncleared
        case .last30: e.date >= Day.adding(.day, -30, to: today) && e.date <= today
        case .last12Months: e.date >= Day.adding(.month, -12, to: today) && e.date <= today
        case .thisYear: Day.year(of: e.date) == Day.year(of: today)
        case .lastYear: Day.year(of: e.date) == Day.year(of: today) - 1
        case .future: e.date > today
        }
    }
}

struct RegisterView: View {
    @Environment(\.modelContext) private var context
    @Environment(LedgerIndex.self) private var index
    let account: Account
    @Binding var focusEntry: PersistentIdentifier?

    @State private var filter: RegisterFilter = .unreconciled
    @State private var search = ""
    @State private var selection: PersistentIdentifier?
    @AppStorage("register.showForm") private var showForm = true
    @State private var pendingDelete: PersistentIdentifier?
    @State private var flagEditing: Entry?
    @State private var balancing = false
    /// Set while jumping to an entry, so the temporary "All transactions" isn't remembered.
    @State private var jumping = false
    @Query(sort: \Business.name) private var businesses: [Business]

    var body: some View {
        let today = Day.today
        let all = balancedRows()
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        // Searching looks through every transaction in the account, regardless of the view filter.
        let rows = q.isEmpty ? all.filter { filter.includes($0.row, today: today) } : all.filter { $0.row.matches(q) }
        let totals = index.totals[account.persistentModelID] ?? AccountTotals()
        let flaggedCount = all.lazy.filter(\.row.isFlagged).count

        VStack(spacing: 0) {
            header(totals: totals, shown: rows.count, total: all.count, searching: !q.isEmpty, flagged: flaggedCount,
                   balancedThrough: all.last(where: { $0.row.status == .reconciled })?.row.date)
            Divider()
            table(rows, today: today, key: q.isEmpty ? filter.rawValue : "search")
            if showForm {
                Divider()
                EntryFormView(account: account, entry: selectedEntry) { saved in
                    selection = saved?.persistentModelID
                }
                .id(selection)
            }
        }
        .navigationTitle(account.name)
        .navigationSubtitle(account.isReadOnly ? "Closed — read only" : account.kind.label)
        .searchable(text: $search, placement: .toolbar, prompt: "Search memo, payee, number, amount")
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $filter) {
                    ForEach(RegisterFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Which transactions to show")
            }
            ToolbarItem {
                Button { balancing = true } label: { Label("Balance Account", systemImage: "checkmark.seal") }
                    .help("Balance this account against a statement")
                    .disabled(account.isReadOnly)
            }
            ToolbarItem {
                Toggle(isOn: $showForm) { Label("Transaction form", systemImage: "rectangle.bottomthird.inset.filled") }
                    .help("Show transaction form")
            }
        }
        .confirmationDialog("Delete this transaction?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { id in
            Button("Delete", role: .destructive) {
                if let e = context.model(for: id) as? Entry { EntryStore(context: context).delete(e) }
                if selection == id { selection = nil }
            }
        } message: { id in
            Text(deleteMessage(id))
        }
        .onAppear {
            // Each account remembers its own view; closed accounts default to everything.
            let saved = UserDefaults.standard.string(forKey: filterKey).flatMap(RegisterFilter.init(rawValue:))
            filter = saved ?? (account.isReadOnly ? .all : .unreconciled)
            applyFocus()
        }
        .onChange(of: filter) {
            if jumping { jumping = false } else { UserDefaults.standard.set(filter.rawValue, forKey: filterKey) }
        }
        .onChange(of: focusEntry) { applyFocus() }
        .onReceive(NotificationCenter.default.publisher(for: .editFlag)) { note in
            if let id = note.object as? PersistentIdentifier, let e = context.model(for: id) as? Entry, e.account == account { flagEditing = e }
        }
        .sheet(item: $flagEditing) { FlagEditor(entry: $0) }
        .sheet(isPresented: $balancing) { BalanceAccountView(account: account) }
        .onReceive(NotificationCenter.default.publisher(for: .balanceAccount)) { _ in
            if !account.isReadOnly { balancing = true }
        }
    }

    private var filterKey: String { "register.filter.\(account.uuid.uuidString)" }

    private var selectedEntry: Entry? {
        selection.flatMap { context.model(for: $0) as? Entry }
    }

    private func balancedRows() -> [RegisterRow] {
        var balance = account.openingBalanceCents
        return (index.rowsByAccount[account.persistentModelID] ?? []).map { r in
            balance += r.effect
            return RegisterRow(row: r, balanceCents: balance)
        }
    }

    private func applyFocus() {
        guard let id = focusEntry, index.rowsByAccount[account.persistentModelID]?.contains(where: { $0.id == id }) == true else { return }
        if filter != .all { jumping = true; filter = .all }
        search = ""
        selection = id
        focusEntry = nil
    }

    private func deleteMessage(_ id: PersistentIdentifier) -> String {
        guard let e = context.model(for: id) as? Entry else { return "" }
        var parts = ["\(Day.string(e.date))  \(e.payee?.name ?? "")  \(Cents.string(e.amountCents))"]
        if e.isTransfer { parts.append("The matching entry in \(e.transferAccount?.name ?? "the other account") will also be deleted.") }
        if e.moneyId != nil { parts.append("This came from Money; it will come back on the next re-import unless you also delete it in Money.") }
        return parts.joined(separator: "\n\n")
    }

    private func header(totals: AccountTotals, shown: Int, total: Int, searching: Bool, flagged: Int, balancedThrough: Date?) -> some View {
        HStack(spacing: 28) {
            stat("Today's balance", totals.today)
            stat("Ending balance", totals.current, help: "Includes entries dated after today")
            stat("Cleared balance", totals.cleared, help: "Opening balance plus cleared and reconciled entries")
            if let d = balancedThrough {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Balanced through").font(.caption).foregroundStyle(.secondary)
                    Text(Day.string(d)).font(.title3)
                }
                .help(lastStatementHelp)
            }
            Spacer()
            if flagged > 0 {
                Button { filter = .flagged; search = "" } label: {
                    Label("\(flagged) flagged", systemImage: "flag.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Show flagged transactions")
            }
            Text(searching ? "\(shown) matches in all \(total) transactions" : "\(shown) of \(total) transactions")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// The newest reconciled transaction is shown; the statement itself goes in the tooltip.
    private var lastStatementHelp: String {
        var lines = ["Date of the newest reconciled transaction."]
        if let d = account.statementDate, let b = account.statementBalanceCents {
            lines.append("Last balanced in MacMoney: \(Day.string(d)) statement, ending \(Cents.string(b)).")
        } else if let d = account.lastReconciledDate {
            let bal = account.lastReconciledBalanceCents.map { ", ending \(Cents.string($0))" } ?? ""
            lines.append("Last statement balanced in Money: \(Day.string(d))\(bal).")
        }
        return lines.joined(separator: "\n")
    }

    private func stat(_ title: String, _ cents: Int, help: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Cents.string(cents)).font(.title3).monospacedDigit().foregroundStyle(cents < 0 ? .red : .primary)
        }
        .help(help)
    }

    private func table(_ rows: [RegisterRow], today: Date, key: String) -> some View {
        let readOnly = account.isReadOnly
        func dim(_ r: RegisterRow) -> Bool { r.row.date > today }
        let columns: [FastColumn<RegisterRow>] = [
            FastColumn("", id: "flag", width: 18, min: 18, max: 30, help: "Flag — click to flag or clear") { _ in "" } style: { r in
                let due = r.row.flagDate.map { $0 <= today } ?? false
                var tip = [r.row.flagNote.isEmpty ? "Flagged" : r.row.flagNote]
                if let d = r.row.flagDate { tip.append("Action date: \(Day.string(d))") }
                tip.append("Click to clear · right-click ▸ Edit Flag… for the note")
                return r.row.isFlagged
                    ? FastCellStyle(color: due ? .systemOrange : .systemRed, symbol: "flag.fill", tooltip: tip.joined(separator: "\n"))
                    : FastCellStyle(tooltip: readOnly ? nil : "Click to flag")
            }
            .sorted(by: { $0.row.isFlagged ? 1 : 0 }, descendingFirst: true)
            .onClick { r in toggleFlag(r.id) },
            FastColumn("C", id: "status", width: 20, min: 18, max: 30, align: .center, help: "Cleared / Reconciled — click to toggle cleared") { r in
                r.row.status.marker
            } style: { r in
                FastCellStyle(color: r.row.status == .reconciled ? .secondaryLabelColor : .controlAccentColor, bold: true, dimmed: dim(r))
            }
            .sorted(by: { ClearedStatus.allCases.firstIndex(of: $0.row.status) ?? 0 })
            .onClick { r in toggleCleared(r.id, r.row.status) },
            FastColumn("Num", width: 56, min: 36) { $0.row.number } style: { FastCellStyle(dimmed: dim($0)) }
                .sortedText { $0.row.number },
            FastColumn("Date", width: 82, min: 70, monospaced: true) { Day.string($0.row.date) } style: { FastCellStyle(dimmed: dim($0)) }
                .sorted(by: { DateOrder(date: $0.row.date, order: $0.row.order) }),
            FastColumn("Payee", width: 190, min: 100) { r in
                r.row.isVoid ? "\(r.row.payee)  VOID" : r.row.payee
            } style: { r in
                FastCellStyle(color: r.row.isVoid ? .systemRed : nil, dimmed: dim(r))
            }
            .sortedText { $0.row.payee },
            FastColumn("", id: "business", width: 18, min: 18, max: 30, help: "Business") { _ in "" } style: { r in
                r.row.business.isEmpty ? FastCellStyle() : FastCellStyle(
                    color: .secondaryLabelColor, symbol: "briefcase.fill",
                    tooltip: "\(r.row.business)\(r.row.taxLine.isEmpty ? " — no Schedule C line yet" : " · Line \(r.row.taxLine)")")
            }
            .sortedText { $0.row.business },
            FastColumn("Category", width: 170, min: 80) { $0.row.category } style: { FastCellStyle(color: .secondaryLabelColor, dimmed: dim($0)) }
                .sortedText { $0.row.category },
            FastColumn("Memo", width: 320, min: 100) { $0.row.memo } style: { r in
                FastCellStyle(color: .secondaryLabelColor, dimmed: dim(r), tooltip: r.row.memo.isEmpty ? nil : r.row.memo)
            }
            .sortedText { $0.row.memo },
            FastColumn("Payment", width: 88, min: 60, align: .right, monospaced: true) { r in
                r.row.amount < 0 ? Cents.plain(r.row.amount) : ""
            } style: { FastCellStyle(strikethrough: $0.row.isVoid, dimmed: dim($0)) }
                .sorted(by: { $0.row.amount < 0 ? -$0.row.amount : 0 }, descendingFirst: true),
            FastColumn("Deposit", width: 88, min: 60, align: .right, monospaced: true) { r in
                r.row.amount > 0 ? Cents.plain(r.row.amount) : ""
            } style: { FastCellStyle(strikethrough: $0.row.isVoid, dimmed: dim($0)) }
                .sorted(by: { max(0, $0.row.amount) }, descendingFirst: true),
            FastColumn("Balance", width: 104, min: 70, align: .right, monospaced: true) { Cents.string($0.balanceCents) } style: { r in
                FastCellStyle(color: r.balanceCents < 0 ? .systemRed : nil, dimmed: dim(r))
            }
            .sorted(by: { $0.balanceCents }),
        ]
        return FastTable(rows: rows, columns: columns,
                         selection: Binding(get: { selection.map { [$0] } ?? [] }, set: { selection = $0.first }),
                         multipleSelection: false, autosave: "Register", scrollToEnd: true, scrollKey: key,
                         menu: readOnly ? nil : { ids in ids.first.map(menuItems) ?? [] },
                         onDelete: { ids in if !readOnly, let id = ids.first { pendingDelete = id } })
    }

    private func entry(_ id: PersistentIdentifier) -> Entry? { context.model(for: id) as? Entry }

    private func change(_ id: PersistentIdentifier, _ body: (Entry) -> Void) {
        guard !account.isReadOnly, let e = entry(id) else { return }
        body(e)
        try? context.save()
    }

    private func toggleFlag(_ id: PersistentIdentifier) { change(id) { $0.isFlagged.toggle() } }

    /// Clicking toggles uncleared <-> cleared. Reconciled entries change only via the context menu.
    private func toggleCleared(_ id: PersistentIdentifier, _ status: ClearedStatus) {
        guard status != .reconciled else { return }
        change(id) { e in
            e.status = status == .cleared ? .uncleared : .cleared
            e.dateCleared = e.status == .cleared ? Day.today : nil
        }
    }

    private func menuItems(_ id: PersistentIdentifier) -> [FastMenuItem] {
        guard let e = entry(id) else { return [] }
        var items: [FastMenuItem] = []
        if !businesses.isEmpty {
            items.append(.submenu("Business", businesses.map { b in
                .button(b.name) { change(id) { $0.business = b; $0.isPersonal = false } }
            } + [
                .separator,
                .button("Personal") { change(id) { $0.business = nil; $0.isPersonal = true } },
                .button("Account Default") { change(id) { $0.business = nil; $0.isPersonal = false } },
            ]))
        }
        items.append(.submenu("Mark As", ClearedStatus.allCases.map { s in
            .button(s.rawValue.capitalized) {
                change(id) { $0.status = s; $0.dateCleared = s == .uncleared ? nil : ($0.dateCleared ?? Day.today) }
            }
        }))
        items += [
            .button(e.isFlagged ? "Clear Flag" : "Add Flag") { toggleFlag(id) },
            .button("Edit Flag…") { flagEditing = e },
            .button(e.isVoid ? "Unvoid" : "Void") { change(id) { $0.isVoid.toggle() } },
            .separator,
            .button("Delete…") { pendingDelete = id },
        ]
        return items
    }
}

/// Date with Money's same-day order as a tie-break, so sorting by date keeps the register order.
struct DateOrder: Comparable {
    let date: Date
    let order: Int
    static func < (a: DateOrder, b: DateOrder) -> Bool { (a.date, a.order) < (b.date, b.order) }
}

extension Notification.Name {
    static let editFlag = Notification.Name("editFlag")
    static let balanceAccount = Notification.Name("balanceAccount")
}

/// Flag with its note and optional action date (Money's "Flag for follow up").
struct FlagEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let entry: Entry
    @State private var note = ""
    @State private var hasDate = false
    @State private var date = Day.today

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Flag", systemImage: "flag.fill").font(.title2.bold()).foregroundStyle(.red)
            Text("\(Day.string(entry.date))  \(entry.payee?.name ?? "")  \(Cents.string(entry.amountCents))").foregroundStyle(.secondary)
            TextField("Note (e.g. auto-pay scheduled 11/1)", text: $note, axis: .vertical).lineLimit(1...4)
            Toggle("Action date", isOn: $hasDate)
            if hasDate {
                DatePicker("Date", selection: Binding(get: { Day.toLocal(date) }, set: { date = Day.normalize($0) }), displayedComponents: .date)
            }
            HStack {
                if entry.isFlagged {
                    Button("Clear Flag", role: .destructive) {
                        entry.isFlagged = false
                        try? context.save()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Flag") {
                    entry.isFlagged = true
                    entry.flagNote = note.nilIfBlank
                    entry.flagDate = hasDate ? date : nil
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            note = entry.flagNote ?? ""
            hasDate = entry.flagDate != nil
            date = entry.flagDate ?? entry.date
        }
    }
}
