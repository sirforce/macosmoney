import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers

/// Payee list with a built-in report. With nothing selected the right side is an overview of the
/// period (trend chart, top payees); select one or more to see their trend, totals by year and
/// category, and every transaction. In `.depositSources` mode it shows only who pays you
/// (deposits, excluding transfers between your own accounts).
struct PayeesView: View {
    enum Mode { case payees, depositSources }
    var mode: Mode = .payees
    private var deposits: Bool { mode == .depositSources }

    @Query(sort: \Payee.name) private var payees: [Payee]
    @Query(sort: \ReportPreset.name) private var allPresets: [ReportPreset]
    @Environment(\.modelContext) private var context
    @Environment(LedgerIndex.self) private var index

    @State private var selection = Set<PersistentIdentifier>()
    @State private var search = ""
    @State private var showHidden = false
    @State private var period: ReportPeriod = .last12Months
    @State private var customFrom = Day.startOfYear(Day.today)
    @State private var customTo = Day.today
    @State private var exporting = false
    @State private var reportSelection = Set<PersistentIdentifier>()
    @State private var activePresetID: UUID?
    /// Browser-style history of what was shown (each entry is a selection; empty = overview).
    @State private var backStack: [Set<PersistentIdentifier>] = []
    @State private var forwardStack: [Set<PersistentIdentifier>] = []
    @State private var navigating = false
    @State private var naming: PresetNaming?

    private enum PresetNaming: Identifiable {
        case new, rename(ReportPreset)
        var id: String { if case .rename(let p) = self { return p.uuid.uuidString } else { return "new" } }
    }

    // MARK: Presets

    private var kind: String { deposits ? "depositSources" : "payees" }
    private var presets: [ReportPreset] { allPresets.filter { $0.kind == kind } }
    private var activePreset: ReportPreset? { activePresetID.flatMap { id in presets.first { $0.uuid == id } } }

    private var selectedPayeeUUIDs: Set<UUID> {
        Set(payees.filter { selection.contains($0.persistentModelID) }.map(\.uuid))
    }

    /// True when the current selection/filters differ from the active preset.
    private var presetEdited: Bool {
        guard let p = activePreset else { return false }
        return p.payees != selectedPayeeUUIDs || p.periodRaw != period.rawValue || p.search != search
            || p.showHidden != showHidden
            || (period == .custom && (p.customFrom != customFrom || p.customTo != customTo))
    }

    private func apply(_ p: ReportPreset) {
        let ids = p.payees
        selection = Set(payees.filter { ids.contains($0.uuid) }.map(\.persistentModelID))
        period = ReportPeriod(rawValue: p.periodRaw) ?? period
        if let f = p.customFrom { customFrom = f }
        if let t = p.customTo { customTo = t }
        search = p.search
        showHidden = p.showHidden
        activePresetID = p.uuid
    }

    private func store(into p: ReportPreset) {
        p.payees = selectedPayeeUUIDs
        p.periodRaw = period.rawValue
        p.customFrom = period == .custom ? customFrom : nil
        p.customTo = period == .custom ? customTo : nil
        p.search = search
        p.showHidden = showHidden
        p.modified = Date()
    }

    private func saveNew(named name: String) {
        // Same name replaces the existing preset rather than making a duplicate.
        let p = presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? {
            let p = ReportPreset(name: name, kind: kind)
            context.insert(p)
            return p
        }()
        p.name = name
        store(into: p)
        try? context.save()
        activePresetID = p.uuid
    }

    private func delete(_ p: ReportPreset) {
        if activePresetID == p.uuid { activePresetID = nil }
        context.delete(p)
        try? context.save()
    }

    private var presetMenu: some View {
        Menu {
            if presets.isEmpty {
                Text("No presets yet")
            } else {
                Section("Recall") {
                    ForEach(presets) { p in
                        Button { apply(p) } label: {
                            if p.uuid == activePresetID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                }
            }
            Divider()
            Button("Save as New Preset…") { naming = .new }
                .disabled(selection.isEmpty && search.isEmpty)
            if let p = activePreset {
                Button("Update “\(p.name)”") { store(into: p); try? context.save() }
                    .disabled(!presetEdited)
                Button("Rename “\(p.name)”…") { naming = .rename(p) }
                Button("Delete “\(p.name)”", role: .destructive) { delete(p) }
            }
            if presets.count > 1 {
                Menu("Delete Preset") {
                    ForEach(presets) { p in Button(p.name, role: .destructive) { delete(p) } }
                }
            }
        } label: {
            Label(activePreset.map { $0.name + (presetEdited ? " (edited)" : "") } ?? "Presets", systemImage: "bookmark")
        }
        .fixedSize()
        .help("Save the selected \(deposits ? "sources" : "payees") and filters, and recall them later")
    }

    /// One-click chips for saved presets.
    @ViewBuilder private var presetChips: some View {
        if !presets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets) { p in
                        let active = p.uuid == activePresetID
                        Button { active ? clearPreset() : apply(p) } label: {
                            Text(p.name + (active && presetEdited ? " •" : ""))
                                .font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(active ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(active ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .help(active ? "Clear" : "Recall “\(p.name)”")
                        .contextMenu {
                            Button("Rename…") { naming = .rename(p) }
                            Button("Delete", role: .destructive) { delete(p) }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.bottom, 6)
        }
    }

    private func clearPreset() {
        activePresetID = nil
        selection = []
        search = ""
    }

    // MARK: Data

    private func isDeposit(_ e: EntryRow) -> Bool { e.amount > 0 && !e.isTransfer && !e.isVoid }
    /// Rows this page is about: deposits, or (for payees) everything that isn't void.
    private func counts(_ e: EntryRow) -> Bool { deposits ? isDeposit(e) : !e.isVoid }
    /// Positive = money in (deposits) or money out (payees), so charts read naturally.
    private func value(_ e: EntryRow) -> Int { deposits ? e.amount : -e.amount }

    private var range: ClosedRange<Date>? {
        period == .custom ? min(customFrom, customTo)...max(customFrom, customTo) : period.range()
    }

    private func usage() -> [PersistentIdentifier: PayeeUsage] {
        let year = Day.year(of: Day.today)
        let today = Day.today
        var u: [PersistentIdentifier: PayeeUsage] = [:]
        for e in index.rows where counts(e) {
            guard let p = e.payeeID else { continue }
            var x = u[p] ?? PayeeUsage()
            x.count += 1
            x.total += value(e)
            if Day.year(of: e.date) == year { x.thisYear += value(e) }
            if e.date > x.last && e.date <= today { x.last = e.date }
            u[p] = x
        }
        return u
    }

    private func visiblePayees(_ u: [PersistentIdentifier: PayeeUsage]) -> [Payee] {
        let q = search.lowercased()
        return payees.filter {
            (showHidden || !$0.isHidden) && (q.isEmpty || $0.name.lowercased().contains(q))
                && (!deposits || u[$0.persistentModelID] != nil)
        }
    }

    private func matches() -> [EntryRow] {
        let r = range
        return index.rows.filter { e in
            guard let p = e.payeeID, selection.contains(p), counts(e) else { return false }
            return r?.contains(e.date) ?? true
        }
    }

    /// Overview rows: all deposits, or all payments to payees, in the period.
    private func overviewRows() -> [EntryRow] {
        let r = range
        return index.rows.filter { e in
            guard e.payeeID != nil, r?.contains(e.date) ?? true else { return false }
            return deposits ? isDeposit(e) : (!e.isVoid && !e.isTransfer && e.amount < 0)
        }
    }

    // MARK: Layout

    var body: some View {
        HSplitView {
            payeeList.frame(minWidth: 340, idealWidth: 470, maxWidth: 680, maxHeight: .infinity)
            Group {
                if selection.isEmpty { overview } else { detail }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(deposits ? "Deposit Sources" : "Payees")
        .onChange(of: selection) { old, new in
            if navigating { navigating = false; return }
            guard old != new else { return }
            backStack.append(old)
            if backStack.count > 100 { backStack.removeFirst() }
            forwardStack = []
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(backStack.isEmpty)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back (⌘[)")
                Button { goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(forwardStack.isEmpty)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Forward (⌘])")
            }
            ToolbarItem {
                Button { showOverview() } label: { Label("Overview", systemImage: "chart.bar.xaxis") }
                    .disabled(selection.isEmpty)
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Back to the \(deposits ? "income" : "spending") overview (⌘0)")
            }
        }
        .sheet(item: $naming) { n in
            switch n {
            case .new:
                PresetNameSheet(title: "Save Preset", initial: activePreset?.name ?? "",
                                existing: Set(presets.map { $0.name.lowercased() })) { saveNew(named: $0) }
            case .rename(let p):
                PresetNameSheet(title: "Rename Preset", initial: p.name, existing: []) { name in
                    p.name = name
                    try? context.save()
                }
            }
        }
    }

    private var payeeList: some View {
        let u = usage()
        let visible = visiblePayees(u)
        return VStack(spacing: 0) {
            HStack {
                TextField(deposits ? "Search deposit sources" : "Search payees", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Hidden", isOn: $showHidden).toggleStyle(.checkbox)
                presetMenu
            }
            .padding(8)
            presetChips
            FastTable(rows: visible.map { PayeeRow($0, usage: u[$0.persistentModelID]) }, columns: payeeColumns,
                      selection: $selection, autosave: deposits ? "DepositSources2" : "Payees2",
                      defaultSort: deposits ? ("Last", false) : ("Payee", true))
            HStack {
                Text("\(visible.count) \(deposits ? "sources" : "payees")")
                Spacer()
                if !selection.isEmpty {
                    Button("Show Overview") { showOverview() }.buttonStyle(.link)
                } else {
                    Text("⌘-click to select several")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private var toolbarRow: some View {
        HStack {
            Picker("Period", selection: $period) {
                ForEach(ReportPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 220)
            if period == .custom {
                DatePicker("From", selection: dayBinding($customFrom), displayedComponents: .date).labelsHidden()
                Text("to").foregroundStyle(.secondary)
                DatePicker("To", selection: dayBinding($customTo), displayedComponents: .date).labelsHidden()
            }
            Spacer()
        }
    }

    // MARK: Overview (nothing selected)

    private var overview: some View {
        let rows = overviewRows()
        let total = rows.reduce(0) { $0 + value($1) }
        let byPayee = Dictionary(grouping: rows) { $0.payeeID! }
            .map { (id: $0.key, name: $0.value[0].payee, cents: $0.value.reduce(0) { $0 + value($1) }, count: $0.value.count) }
            .sorted { $0.cents > $1.cents }
        let top = Array(byPayee.prefix(5).map(\.name))
        let months = monthSpan(rows)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deposits ? "Income overview" : "Spending overview").font(.title2.bold())
                    Text(deposits ? "Deposits from outside sources — transfers between your accounts are excluded."
                                  : "Payments to payees — transfers between your accounts are excluded.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                toolbarRow
                HStack(spacing: 12) {
                    StatCard(title: deposits ? "Total received" : "Total paid", value: Cents.string(total), tint: deposits ? .green : nil)
                    StatCard(title: "Per month", value: Cents.string(total / max(1, months)))
                    StatCard(title: deposits ? "Deposits" : "Payments", value: rows.count.formatted())
                    StatCard(title: deposits ? "Active sources" : "Payees paid", value: byPayee.count.formatted())
                    if let first = byPayee.first, total > 0 {
                        StatCard(title: "Largest", value: first.name,
                                 detail: "\(Int((Double(first.cents) / Double(total) * 100).rounded()))% · \(Cents.string(first.cents))")
                    }
                }
                if rows.isEmpty {
                    ContentUnavailableView("Nothing in this period", systemImage: deposits ? "arrow.down.circle" : "person.2",
                                           description: Text("Choose a longer period, or select \(deposits ? "a source" : "a payee") on the left."))
                } else {
                    GroupBox(deposits ? "Received over time — top 5 sources" : "Paid over time — top 5 payees") {
                        trendChart(rows) { top.contains($0.payee) ? $0.payee : "Everyone else" }
                            .frame(height: 240)
                            .padding(.top, 4)
                    }
                    GroupBox(deposits ? "Top sources" : "Top payees") {
                        VStack(spacing: 2) {
                            ForEach(byPayee.prefix(15), id: \.id) { p in
                                Button { selection = [p.id] } label: {
                                    ShareRow(name: p.name, detail: "\(p.count)×", cents: p.cents, share: total > 0 ? Double(p.cents) / Double(total) : 0,
                                             tint: deposits ? .green : .accentColor)
                                }
                                .buttonStyle(.plain)
                                .help("Show \(p.name)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: Detail (one or more selected)

    // MARK: Navigation

    private func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(selection)
        move(to: prev)
    }

    private func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(selection)
        move(to: next)
    }

    /// Changes the selection without recording it in history.
    private func move(to ids: Set<PersistentIdentifier>) {
        guard ids != selection else { return }
        navigating = true
        selection = ids
    }

    private func showOverview() {
        selection = []
        activePresetID = nil
    }

    private func breadcrumb(_ names: [String]) -> some View {
        HStack(spacing: 4) {
            Button { showOverview() } label: {
                Label(deposits ? "Income overview" : "Spending overview", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            .help("Back to the overview (⌘0)")
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            Text(names.count == 1 ? names[0] : "\(names.count) selected").foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
    }

    private var detail: some View {
        let rows = matches()
        let names = payees.filter { selection.contains($0.persistentModelID) }.map(\.name)
        let inCents = rows.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let outCents = -rows.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }
        let total = rows.reduce(0) { $0 + value($1) }
        let months = monthSpan(rows)
        let largest = rows.max { value($0) < value($1) }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                breadcrumb(names)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(names.count == 1 ? names[0] : "\(names.count) \(deposits ? "sources" : "payees")")
                            .font(.title2.bold()).lineLimit(1)
                        if let p = activePreset {
                            Label(p.name + (presetEdited ? " — edited" : ""), systemImage: "bookmark.fill")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if names.count > 1 {
                            Text(names.sorted().joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Button { naming = .new } label: { Label("Save Preset…", systemImage: "bookmark") }
                    if let p = activePreset, presetEdited {
                        Button("Update “\(p.name)”") { store(into: p); try? context.save() }
                    }
                    Button { exporting = true } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                        .disabled(rows.isEmpty)
                }
                toolbarRow
                HStack(spacing: 12) {
                    if deposits {
                        StatCard(title: "Received", value: Cents.string(inCents), tint: .green)
                        StatCard(title: "Deposits", value: rows.count.formatted())
                        StatCard(title: "Average", value: Cents.string(rows.isEmpty ? 0 : inCents / rows.count))
                        StatCard(title: "Per month", value: Cents.string(inCents / max(1, months)))
                    } else {
                        StatCard(title: "Paid", value: Cents.string(outCents))
                        if inCents > 0 { StatCard(title: "Received", value: Cents.string(inCents), tint: .green) }
                        StatCard(title: "Transactions", value: rows.count.formatted())
                        StatCard(title: "Per month", value: Cents.string(total / max(1, months)))
                    }
                    if let largest {
                        StatCard(title: "Largest", value: Cents.string(abs(largest.amount)), detail: Day.string(largest.date))
                    }
                    if let last = rows.map(\.date).filter({ $0 <= Day.today }).max() {
                        StatCard(title: deposits ? "Last deposit" : "Last paid", value: Day.string(last),
                                 detail: rows.map(\.date).min().map { "since \(Day.string($0))" })
                    }
                }
                if rows.isEmpty {
                    emptyPeriodHint
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        GroupBox("Over time") {
                            trendChart(rows) { names.count > 1 && names.count <= 6 ? $0.payee : (deposits ? "Received" : "Paid") }
                                .frame(minHeight: 180, maxHeight: 200)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        breakdown(rows, total: total)
                            .frame(width: 300)
                    }
                }
            }
            .padding(16)
            Divider()
            FastTable(rows: rows.map(PayeeEntryRow.init), columns: Self.entryColumns, selection: $reportSelection,
                      autosave: "PayeeReport2", defaultSort: ("Date", false), scrollKey: selection)
                .frame(minHeight: 200)
        }
        .fileExporter(isPresented: $exporting, document: CSVDocument(text: csv(rows)), contentType: .commaSeparatedText,
                      defaultFilename: "\(deposits ? "Deposit" : "Payee") report \(period.rawValue)") { _ in }
    }

    @ViewBuilder private var emptyPeriodHint: some View {
        let last = index.rows.filter { e in e.payeeID.map(selection.contains) ?? false && counts(e) }.map(\.date).max()
        HStack {
            Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.secondary)
            Text("Nothing in \(period.rawValue.lowercased())\(last.map { " — last one was \(Day.string($0))" } ?? "").")
                .foregroundStyle(.secondary)
            if period != .allDates { Button("Show All Dates") { period = .allDates } }
        }
        .padding(.vertical, 8)
    }

    /// By year and by category side panel.
    private func breakdown(_ rows: [EntryRow], total: Int) -> some View {
        let byYear = Dictionary(grouping: rows) { Day.year(of: $0.date) }
            .map { (year: $0.key, cents: $0.value.reduce(0) { $0 + value($1) }, count: $0.value.count) }
            .sorted { $0.year > $1.year }
        let byCategory = Dictionary(grouping: rows) { $0.category.isEmpty ? "(none)" : $0.category }
            .map { (name: $0.key, cents: $0.value.reduce(0) { $0 + value($1) }, count: $0.value.count) }
            .sorted { $0.cents > $1.cents }
        let maxYear = max(1, byYear.map { abs($0.cents) }.max() ?? 1)
        return GroupBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("By year").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(byYear, id: \.year) { y in
                        ShareRow(name: String(y.year), detail: "\(y.count)×", cents: y.cents,
                                 share: Double(abs(y.cents)) / Double(maxYear), tint: deposits ? .green : .accentColor)
                    }
                    if byCategory.count > 1 || byCategory.first?.name != "(none)" {
                        Text("By category").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(byCategory.prefix(12), id: \.name) { c in
                            ShareRow(name: c.name, detail: "\(c.count)×", cents: c.cents,
                                     share: total != 0 ? Double(abs(c.cents)) / Double(abs(total)) : 0, tint: .orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 220)
    }

    // MARK: Chart

    private struct Bucket: Identifiable {
        let date: Date
        let series: String
        let cents: Int
        var id: String { "\(series)|\(date.timeIntervalSince1970)" }
    }

    /// Monthly bars for spans up to 3 years, yearly beyond that.
    private func trendChart(_ rows: [EntryRow], series: (EntryRow) -> String) -> some View {
        let yearly = monthSpan(rows) > 36
        var sums: [String: (Date, String, Int)] = [:]
        for e in rows {
            let d = yearly ? Day.startOfYear(e.date) : Day.startOfMonth(e.date)
            let s = series(e)
            let key = "\(s)|\(d.timeIntervalSince1970)"
            sums[key, default: (d, s, 0)].2 += value(e)
        }
        let buckets = sums.values.map { Bucket(date: $0.0, series: $0.1, cents: $0.2) }.sorted { $0.date < $1.date }
        return Chart(buckets) { b in
            BarMark(x: .value("Period", Day.toLocal(b.date), unit: yearly ? .year : .month),
                    y: .value("Amount", Double(b.cents) / 100))
                .foregroundStyle(by: .value("Series", b.series))
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(d, format: .currency(code: "USD").precision(.fractionLength(0))) }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
    }

    // MARK: Helpers

    private func monthSpan(_ rows: [EntryRow]) -> Int {
        let lo: Date?, hi: Date?
        if let range { lo = max(range.lowerBound, rows.map(\.date).min() ?? range.lowerBound); hi = min(range.upperBound, Day.today) }
        else { lo = rows.map(\.date).min(); hi = rows.map(\.date).max() }
        guard let lo, let hi, hi >= lo else { return 1 }
        return max(1, (Day.calendar.dateComponents([.month], from: lo, to: hi).month ?? 0) + 1)
    }

    private var payeeColumns: [FastColumn<PayeeRow>] {
        let money: (PayeeRow) -> FastCellStyle = { [deposits] r in
            FastCellStyle(color: r.count == 0 ? .tertiaryLabelColor : (deposits ? .systemGreen : nil))
        }
        return [
            FastColumn(deposits ? "Source" : "Payee", id: "Payee", width: 170, min: 100) { $0.name } style: { r in
                FastCellStyle(color: r.payee.isHidden ? .secondaryLabelColor : nil)
            }
            .sortedText { $0.name },
            FastColumn(deposits ? "Deposits" : "Uses", id: "Uses", width: 56, min: 36, align: .right, monospaced: true) { r in
                r.count == 0 ? "" : "\(r.count)"
            } style: { _ in FastCellStyle(color: .secondaryLabelColor) }
            .sorted(by: { $0.count }, descendingFirst: true),
            FastColumn(deposits ? "Last deposit" : "Last used", id: "Last", width: 82, min: 70, monospaced: true) { r in
                r.lastUsed == .distantPast ? "" : Day.string(r.lastUsed)
            } style: { _ in FastCellStyle(color: .secondaryLabelColor) }
            .sorted(by: { $0.lastUsed }, descendingFirst: true),
            FastColumn("This year", width: 96, min: 70, align: .right, monospaced: true,
                       help: deposits ? "Received this calendar year" : "Net paid this calendar year") { r in
                r.thisYear == 0 ? "" : Cents.string(r.thisYear)
            } style: { money($0) }
            .sorted(by: { $0.thisYear }, descendingFirst: true),
            FastColumn(deposits ? "Total received" : "Total paid", id: "Total", width: 110, min: 80, align: .right, monospaced: true,
                       help: deposits ? "All deposits ever" : "Net paid over all years") { r in
                r.count == 0 ? "" : Cents.string(r.total)
            } style: { money($0) }
            .sorted(by: { $0.total }, descendingFirst: true),
        ]
    }

    static let entryColumns: [FastColumn<PayeeEntryRow>] = [
        FastColumn("Date", width: 82, min: 70, monospaced: true) { Day.string($0.date) }.sorted(by: { $0.date }),
        FastColumn("Account", width: 150, min: 80) { $0.account }.sortedText { $0.account },
        FastColumn("Num", width: 56, min: 36) { $0.number }.sortedText { $0.number },
        FastColumn("Payee", width: 180, min: 80) { $0.payee }.sortedText { $0.payee },
        FastColumn("Category", width: 180, min: 80) { $0.category } style: { _ in FastCellStyle(color: .secondaryLabelColor) }
            .sortedText { $0.category },
        FastColumn("Memo", width: 260, min: 80) { $0.memo } style: { FastCellStyle(color: .secondaryLabelColor, tooltip: $0.memo.isEmpty ? nil : $0.memo) }
            .sortedText { $0.memo },
        FastColumn("Amount", width: 100, min: 70, align: .right, monospaced: true) { Cents.string($0.amount) } style: { r in
            FastCellStyle(color: r.amount < 0 ? nil : .systemGreen)
        }
        .sorted(by: { $0.amount }),
    ]

    private func dayBinding(_ b: Binding<Date>) -> Binding<Date> {
        Binding(get: { Day.toLocal(b.wrappedValue) }, set: { b.wrappedValue = Day.normalize($0) })
    }

    private func csv(_ rows: [EntryRow]) -> String {
        var lines = [CSV.row(["Date", "Account", "Number", "Payee", "Category", "Memo", "Amount", "Status"])]
        for e in rows.sorted(by: { $0.date < $1.date }) {
            lines.append(CSV.row([Day.string(e.date), e.accountName, e.number, e.payee,
                                  e.category, e.memo, "\(Cents.decimal(e.amount))", e.status.rawValue]))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Asks for a preset name.
struct PresetNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: String
    /// Lowercased names already in use (saving one of these replaces it).
    let existing: Set<String>
    let save: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            TextField("Name, e.g. “Utilities” or “Business clients”", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if existing.contains(name.trimmingCharacters(in: .whitespaces).lowercased()) {
                Text("This replaces the existing preset with the same name.").font(.caption).foregroundStyle(.orange)
            }
            Text("Saves the selection, period, search and Hidden setting.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: commit).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { name = initial }
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        save(n)
        dismiss()
    }
}

/// A headline number in a rounded box.
struct StatCard: View {
    let title: String
    let value: String
    var detail: String?
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(tint ?? .primary)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Name, amount and a proportional bar.
struct ShareRow: View {
    let name: String
    let detail: String
    let cents: Int
    let share: Double
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).lineLimit(1)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(Cents.string(cents)).monospacedDigit().frame(minWidth: 90, alignment: .trailing)
            }
            GeometryReader { g in
                Capsule().fill(tint.opacity(0.7)).frame(width: max(2, g.size.width * min(1, max(0, share))))
            }
            .frame(height: 4)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct PayeeRow: Identifiable {
    let payee: Payee
    let name: String
    let count: Int
    let lastUsed: Date
    let total: Int
    let thisYear: Int

    init(_ p: Payee, usage: PayeeUsage?) {
        payee = p
        name = p.name
        count = usage?.count ?? 0
        lastUsed = usage?.last ?? .distantPast
        total = usage?.total ?? 0
        thisYear = usage?.thisYear ?? 0
    }

    var id: PersistentIdentifier { payee.persistentModelID }
}

struct PayeeUsage {
    var count = 0
    var last = Date.distantPast
    var total = 0
    var thisYear = 0
}

struct PayeeEntryRow: Identifiable {
    let id: PersistentIdentifier
    let date: Date
    let account: String
    let number: String
    let payee: String
    let category: String
    let memo: String
    let amount: Int

    init(_ e: EntryRow) {
        id = e.id
        date = e.date
        account = e.accountName
        number = e.number
        payee = e.payee
        category = e.category
        memo = e.memo
        amount = e.amount
    }
}

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
