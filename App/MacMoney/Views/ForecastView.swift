import SwiftUI
import SwiftData
import Charts

struct ForecastView: View {
    /// Opens a register entry (entry, account).
    var open: (PersistentIdentifier, PersistentIdentifier) -> Void = { _, _ in }

    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var bills: [Bill]
    @Query(sort: \Scenario.name) private var scenarios: [Scenario]

    @AppStorage("forecast.account") private var accountChoice: String = "all"
    /// Months ahead, or 0 for a custom start/end range.
    @AppStorage("forecast.months") private var months = 12
    @AppStorage("forecast.customStart") private var customStart = Day.adding(.month, -1, to: Day.today)
    @AppStorage("forecast.customEnd") private var customEnd = Day.adding(.month, 6, to: Day.today)
    @State private var selection = Set<UUID>()
    @State private var pickedDate: Date?
    @State private var forecast: Forecast?
    /// The forecast without the scenario, for comparison (nil when no scenario is shown).
    @State private var baseline: Forecast?
    @AppStorage("forecast.scenario") private var scenarioChoice = ""
    @State private var showScenarios = false
    @Environment(LedgerIndex.self) private var index

    private static let horizons = [3, 6, 12, 18, 24, 36]

    private var openAccounts: [Account] { accounts.filter { !$0.isClosed } }

    private var selectedAccounts: [Account] {
        if accountChoice == "all" { return openAccounts.filter { $0.kind == .bank } }
        return openAccounts.filter { $0.uuid.uuidString == accountChoice }
    }

    private var custom: Bool { months == 0 }

    private var scenario: Scenario? { scenarios.first { $0.uuid.uuidString == scenarioChoice } }

    /// The visible date range: presets show 3 months of actual history, then the forecast.
    private var window: ClosedRange<Date> {
        let today = Day.today
        if custom { return min(customStart, customEnd)...max(customStart, customEnd) }
        return Day.adding(.month, -3, to: today)...Day.adding(.month, months, to: today)
    }

    var body: some View {
        Group {
            if let forecast { content(forecast) } else { ProgressView() }
        }
        .navigationTitle("Forecast")
        .navigationSubtitle(scenario.map { "What-if: \($0.name)" } ?? "Register entries ahead of today + bills & deposits not yet entered")
        // Recompute only when data is saved or the account/period/scenario changes — not on every redraw.
        .task(id: "\(index.version)|\(accountChoice)|\(months)|\(customStart.timeIntervalSince1970)|\(customEnd.timeIntervalSince1970)|\(scenario?.signature ?? "")") {
            let today = Day.today
            let w = window
            let base = Forecast(accounts: selectedAccounts, bills: bills, today: today,
                                horizon: max(w.upperBound, today), historyFrom: w.lowerBound)
            if let scenario {
                forecast = Forecast(accounts: selectedAccounts, bills: bills, today: today, horizon: max(w.upperBound, today),
                                    historyFrom: w.lowerBound, adjustments: scenario.sortedItems.map(\.adjustment))
                baseline = base
            } else {
                forecast = base
                baseline = nil
            }
        }
        .sheet(isPresented: $showScenarios) { ScenariosView(chosen: $scenarioChoice) }
    }

    /// Rows for the table: the forecast, plus actual history when a custom range starts in the past.
    private func tableRows(_ f: Forecast) -> [Forecast.Event] {
        let w = window
        let past = custom ? f.pastEvents.filter { w.contains($0.date) } : []
        return past + f.events.filter { $0.date >= w.lowerBound && $0.date <= w.upperBound }
    }

    private func content(_ forecast: Forecast) -> some View {
        let w = window
        let rows = tableRows(forecast)
        let curve = BalanceCurve(forecast)
        let base = baseline.map(BalanceCurve.init)
        let low = curve.lowest(in: w)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Picker("Account", selection: $accountChoice) {
                    Text("All bank accounts").tag("all")
                    Divider()
                    ForEach(openAccounts) { Text($0.name).tag($0.uuid.uuidString) }
                }
                .frame(width: 280)
                Picker("Period", selection: $months) {
                    ForEach(Self.horizons, id: \.self) { Text("Next \($0) months").tag($0) }
                    Divider()
                    Text("Custom range…").tag(0)
                }
                .frame(width: 220)
                if custom {
                    DatePicker("From", selection: dayBinding($customStart), displayedComponents: .date)
                        .frame(width: 170)
                    DatePicker("To", selection: dayBinding($customEnd), displayedComponents: .date)
                        .frame(width: 150)
                }
                Spacer()
                Picker("What-if", selection: $scenarioChoice) {
                    Text("None").tag("")
                    if !scenarios.isEmpty { Divider() }
                    ForEach(scenarios) { Text($0.name.isEmpty ? "Untitled" : $0.name).tag($0.uuid.uuidString) }
                }
                .frame(width: 230)
                .help("Lay a saved what-if scenario over the forecast")
                Button { showScenarios = true } label: { Label("Scenarios…", systemImage: "wand.and.stars") }
                    .help("Create and edit what-if scenarios")
            }
            .padding(12)

            HStack(spacing: 28) {
                if custom && w.lowerBound != Day.today {
                    stat("On \(Day.string(w.lowerBound))", curve.balance(at: w.lowerBound))
                }
                stat("Today", forecast.startBalanceCents)
                stat(custom ? "On \(Day.string(w.upperBound))" : "In \(months) months", curve.balance(at: w.upperBound),
                     baseline: base?.balance(at: w.upperBound))
                if let low {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lowest point").font(.caption).foregroundStyle(.secondary)
                        Button { pick(low.date, rows: rows) } label: {
                            Text("\(Cents.string(low.balanceCents)) on \(Day.string(low.date))")
                                .font(.title3).monospacedDigit().foregroundStyle(low.balanceCents < 0 ? .red : .primary)
                        }
                        .buttonStyle(.plain)
                        .help("Show what happens that day")
                        if let b = base?.lowest(in: w) { delta(low.balanceCents - b.balanceCents) }
                    }
                }
                let overdue = forecast.events.filter { $0.source == .overdueBill }.count
                if overdue > 0 {
                    Label("\(overdue) overdue bill\(overdue == 1 ? "" : "s") counted today", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                }
                Spacer()
            }
            .padding(.horizontal, 12)

            ForecastChart(forecast: forecast, baseline: baseline, curve: curve, domain: w, picked: pickedDate) { date in
                pick(date, rows: rows)
            }
            .frame(minHeight: 260)
            .padding(12)

            Divider()
            HStack {
                Text(pickedDate.map { d in
                    let n = rows.filter { $0.date == d }.count
                    return "\(Day.string(d)): \(n) transaction\(n == 1 ? "" : "s") highlighted"
                } ?? "Hover over the chart to see what moves the balance · click to highlight that day below")
                Spacer()
                Text("Double-click an entered transaction to open it in its register")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            FastTable(rows: rows, columns: Self.columns, selection: $selection, autosave: "Forecast2",
                      scrollKey: "\(months)|\(accountChoice)",
                      onDoubleClick: { e in
                          if let entry = e.entryID, let account = e.accountID { open(entry, account) }
                      })
        }
        .onChange(of: selection) {
            // Selecting a row highlights its day on the chart.
            if let id = selection.first, let e = rows.first(where: { $0.id == id }) { pickedDate = e.date }
        }
    }

    private func pick(_ date: Date, rows: [Forecast.Event]) {
        pickedDate = date
        selection = Set(rows.filter { $0.date == date }.map(\.id))
    }

    private static let columns: [FastColumn<Forecast.Event>] = [
        FastColumn("Date", width: 90, min: 70, monospaced: true) { Day.string($0.date) } style: { e in
            FastCellStyle(dimmed: e.source == .actual)
        }
        .sorted(by: { $0.date }),
        FastColumn("Payee", width: 260, min: 120) { $0.payee } style: { e in FastCellStyle(dimmed: e.source == .actual) }
            .sortedText { $0.payee },
        FastColumn("Source", width: 70, min: 50) { e in
            switch e.source {
            case .actual: "actual"; case .register: "entered"; case .bill: "bill"; case .overdueBill: "overdue"; case .scenario: "what-if"
            }
        } style: { e in
            switch e.source {
            case .actual: FastCellStyle(color: .tertiaryLabelColor, tooltip: "Already happened")
            case .register: FastCellStyle(color: .secondaryLabelColor, tooltip: "Entered in the register ahead of time")
            case .bill: FastCellStyle(color: .systemBlue, tooltip: "Scheduled bill or deposit, not yet entered")
            case .overdueBill: FastCellStyle(color: .systemOrange, tooltip: "Past due and not entered — projected on today")
            case .scenario: FastCellStyle(color: .systemPurple, tooltip: "Added or changed by the what-if scenario")
            }
        }
        .sortedText { "\($0.source)" },
        FastColumn("Account", width: 160, min: 80) { $0.account } style: { _ in FastCellStyle(color: .secondaryLabelColor) }
            .sortedText { $0.account },
        FastColumn("Amount", width: 110, min: 70, align: .right, monospaced: true) { Cents.string($0.amountCents) } style: { e in
            FastCellStyle(color: e.amountCents < 0 ? .systemRed : .systemGreen, dimmed: e.source == .actual)
        }
        .sorted(by: { $0.amountCents }),
        FastColumn("Balance", width: 120, min: 80, align: .right, monospaced: true) { Cents.string($0.balanceCents) } style: { e in
            FastCellStyle(color: e.balanceCents < 0 ? .systemRed : nil, dimmed: e.source == .actual)
        }
        .sorted(by: { $0.balanceCents }),
    ]

    private func stat(_ title: String, _ cents: Int, baseline: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Cents.string(cents)).font(.title3).monospacedDigit().foregroundStyle(cents < 0 ? .red : .primary)
            if let baseline { delta(cents - baseline) }
        }
    }

    /// The scenario's difference from the baseline forecast.
    private func delta(_ cents: Int) -> some View {
        Text(cents == 0 ? "same as baseline" : "\(cents > 0 ? "+" : "")\(Cents.string(cents)) vs baseline")
            .font(.caption).monospacedDigit()
            .foregroundStyle(cents == 0 ? Color.secondary : (cents > 0 ? Color.green : Color.purple))
    }

    private func dayBinding(_ b: Binding<Date>) -> Binding<Date> {
        Binding(get: { Day.toLocal(b.wrappedValue) }, set: { b.wrappedValue = Day.normalize($0) })
    }
}

/// Actual history + forecast as one step curve, with each day's transactions for hover/click.
struct BalanceCurve {
    let points: [Forecast.Point]          // sorted by date
    let eventsByDay: [Date: [Forecast.Event]]
    let eventDays: [Date]                 // sorted

    init(_ f: Forecast) {
        let past = f.history.filter { $0.date < f.startDate }
        points = past + f.points
        let all = f.pastEvents + f.events
        eventsByDay = Dictionary(grouping: all, by: \.date)
        eventDays = eventsByDay.keys.sorted()
    }

    /// End-of-day balance on `d` (the last point on or before it).
    func balance(at d: Date) -> Int {
        var lo = 0, hi = points.count - 1, best = points.first?.balanceCents ?? 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if points[mid].date <= d { best = points[mid].balanceCents; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    func lowest(in range: ClosedRange<Date>) -> Forecast.Point? {
        points.filter { range.contains($0.date) }.min { $0.balanceCents < $1.balanceCents }
    }

    /// The day with transactions closest to `d`, within the range.
    func nearestDay(to d: Date, in range: ClosedRange<Date>) -> Date? {
        var lo = 0, hi = eventDays.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if eventDays[mid] < d { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { eventDays.indices.contains($0) }.map { eventDays[$0] }.filter { range.contains($0) }
        return candidates.min { abs($0.timeIntervalSince(d)) < abs($1.timeIntervalSince(d)) }
    }
}

/// The balance chart. Hover shows the nearest day's transactions; click highlights them in the table.
/// Kept as its own view so mouse movement redraws only the chart.
private struct ForecastChart: View {
    let forecast: Forecast
    /// The forecast without the what-if scenario, drawn dashed underneath it.
    let baseline: Forecast?
    let curve: BalanceCurve
    let domain: ClosedRange<Date>
    let picked: Date?
    let onPick: (Date) -> Void
    @State private var hover: Date?

    var body: some View {
        let today = forecast.startDate
        let history = forecast.history.filter { domain.contains($0.date) || $0.date == today }
        let future = forecast.points.filter { $0.date <= domain.upperBound }
        let basePoints = baseline?.points.filter { $0.date <= domain.upperBound } ?? []
        let tint: Color = baseline == nil ? .orange : .purple
        Chart {
            ForEach(basePoints) { p in
                LineMark(x: .value("Date", p.date), y: .value("Balance", Double(p.balanceCents) / 100), series: .value("Series", "Baseline"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            ForEach(history) { p in
                LineMark(x: .value("Date", p.date), y: .value("Balance", Double(p.balanceCents) / 100), series: .value("Series", "Actual"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(.gray)
            }
            ForEach(future) { p in
                AreaMark(x: .value("Date", p.date), y: .value("Balance", Double(p.balanceCents) / 100), series: .value("Series", "Forecast"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(tint.opacity(baseline == nil ? 0.25 : 0.15))
                LineMark(x: .value("Date", p.date), y: .value("Balance", Double(p.balanceCents) / 100), series: .value("Series", "Forecast"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(tint)
            }
            if domain.contains(today) {
                RuleMark(x: .value("Today", today))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) { Text("Today").font(.caption2).foregroundStyle(.secondary) }
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(.red.opacity(0.4))
            if let picked, picked != hover {
                RuleMark(x: .value("Picked", picked)).foregroundStyle(Color.accentColor.opacity(0.6))
                PointMark(x: .value("Picked", picked), y: .value("Balance", Double(curve.balance(at: picked)) / 100))
                    .foregroundStyle(Color.accentColor)
            }
            if let hover {
                RuleMark(x: .value("Hover", hover))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        HoverCard(date: hover, balance: curve.balance(at: hover), events: curve.eventsByDay[hover] ?? [])
                    }
                PointMark(x: .value("Hover", hover), y: .value("Balance", Double(curve.balance(at: hover)) / 100))
                    .symbolSize(60)
                    .foregroundStyle(hover < today ? Color.gray : tint)
            }
        }
        .chartXScale(domain: domain)
        .overlay(alignment: .topTrailing) {
            if baseline != nil {
                HStack(spacing: 12) {
                    legend("What-if", .purple, dashed: false)
                    legend("Baseline", .orange, dashed: true)
                }
                .font(.caption).padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(.trailing, 50)
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(d, format: .currency(code: "USD").precision(.fractionLength(0))) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = day(at: p, proxy: proxy, geo: geo)
                        case .ended: hover = nil
                        }
                    }
                    .onTapGesture { p in
                        if let d = day(at: p, proxy: proxy, geo: geo) { onPick(d) }
                    }
            }
        }
    }

    private func legend(_ title: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 18, y: 4)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
                .frame(width: 18, height: 8)
            Text(title)
        }
    }

    private func day(at p: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Date? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = p.x - geo[plot].origin.x
        guard let d: Date = proxy.value(atX: x) else { return nil }
        return curve.nearestDay(to: d, in: domain)
    }
}

/// What happened on a day: the balance and the transactions that moved it.
private struct HoverCard: View {
    let date: Date
    let balance: Int
    let events: [Forecast.Event]

    var body: some View {
        let change = events.reduce(0) { $0 + $1.amountCents }
        let shown = events.sorted { abs($0.amountCents) > abs($1.amountCents) }.prefix(6)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Day.string(date)).font(.caption.bold())
                Spacer(minLength: 12)
                Text(Cents.string(balance)).font(.caption.bold()).monospacedDigit()
                    .foregroundStyle(balance < 0 ? .red : .primary)
            }
            if !events.isEmpty {
                Text("\(change >= 0 ? "+" : "")\(Cents.string(change)) that day").font(.caption2).foregroundStyle(.secondary)
                Divider()
                ForEach(shown) { e in
                    HStack(spacing: 6) {
                        Text(e.payee).lineLimit(1)
                        switch e.source {
                        case .bill: Text("bill").font(.caption2).foregroundStyle(.blue)
                        case .overdueBill: Text("overdue").font(.caption2).foregroundStyle(.orange)
                        case .scenario: Text("what-if").font(.caption2).foregroundStyle(.purple)
                        default: EmptyView()
                        }
                        Spacer(minLength: 8)
                        Text(Cents.string(e.amountCents)).monospacedDigit()
                            .foregroundStyle(e.amountCents < 0 ? Color.red : Color.green)
                    }
                    .font(.caption)
                }
                if events.count > shown.count {
                    Text("+ \(events.count - shown.count) more — click to list them").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }
}
