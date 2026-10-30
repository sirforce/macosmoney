import SwiftUI
import SwiftData
import AppKit

/// Money's Balance Account: enter the statement, check off what cleared until the difference is
/// zero (it beeps), then finish to mark everything reconciled.
struct BalanceAccountView: View {
    @Environment(\.modelContext) private var context
    @Environment(LedgerIndex.self) private var index
    @Environment(\.dismiss) private var dismiss
    let account: Account

    private enum Phase { case statement, marking, done(Int) }
    @State private var phase: Phase = .statement
    @State private var statement = Statement()
    @State private var ending = ""
    @State private var charge = ""
    @State private var interest = ""
    @State private var showLater = false
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var error: String?
    @State private var confirmAdjust = false

    /// Credit cards and loans: the statement shows what you owe, which is a negative balance here.
    private var owed: Bool { account.kind == .creditCard || account.kind == .loan }
    private var reconciler: Reconciler { Reconciler(context: context, account: account) }
    private var rows: [EntryRow] { index.rowsByAccount[account.persistentModelID] ?? [] }
    private var clearedCents: Int { index.totals[account.persistentModelID]?.cleared ?? account.openingBalanceCents }
    private var difference: Int { statement.endingCents - clearedCents }

    var body: some View {
        Group {
            switch phase {
            case .statement: statementForm
            case .marking: marking
            case .done(let n): done(n)
            }
        }
        .onChange(of: difference) { old, new in
            guard case .marking = phase, new == 0, old != 0 else { return }
            if NSSound(named: "Glass")?.play() != true { NSSound.beep() }
        }
    }

    // MARK: Step 1 — the statement

    private var statementForm: some View {
        let pending = Reconciler.pending(for: account)
        return VStack(alignment: .leading, spacing: 16) {
            Label("Balance \(account.name)", systemImage: "checkmark.seal").font(.title2.bold())
            if let pending {
                GroupBox {
                    HStack {
                        Text("You postponed balancing to the \(Day.string(pending.date)) statement (ending \(Cents.string(display(pending.endingCents)))).")
                        Spacer()
                        Button("Resume") { statement = pending; phase = .marking }.buttonStyle(.borderedProminent)
                    }
                    .padding(4)
                }
            }
            Text("Enter the figures from your statement.").foregroundStyle(.secondary)
            Form {
                LabeledContent("Starting balance") {
                    Text(Cents.string(display(reconciler.startingCents))).monospacedDigit()
                }
                .help("Opening balance plus everything already reconciled")
                DatePicker("Statement date", selection: Binding(get: { Day.toLocal(statement.date) }, set: { statement.date = Day.normalize($0) }),
                           displayedComponents: .date)
                TextField(owed ? "Ending balance owed" : "Ending balance", text: $ending, prompt: Text("0.00"))
                Section("Service charge (optional)") {
                    TextField("Amount", text: $charge, prompt: Text("0.00"))
                    TextField("Category", text: $statement.serviceChargeCategory)
                }
                Section("Interest earned (optional)") {
                    TextField("Amount", text: $interest, prompt: Text("0.00"))
                    TextField("Category", text: $statement.interestCategory)
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Next") { start() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        let lastBalanced = rows.last(where: { $0.status == .reconciled })?.date
        let base = account.statementDate ?? lastBalanced
        statement.date = base.map { min(Day.adding(.month, 1, to: $0), Day.today) } ?? Day.today
        statement.serviceChargeCategory = guess(["Service Charge", "Bank Charge", "Bank Fee"])
        statement.interestCategory = guess(["Interest Inc", "Interest Earned", "Interest"])
    }

    private func guess(_ names: [String]) -> String {
        for n in names { if let c = index.categoryNames.first(where: { $0.localizedCaseInsensitiveContains(n) }) { return c } }
        return ""
    }

    /// Shows balances the way the statement does (amount owed is positive for credit cards and loans).
    private func display(_ cents: Int) -> Int { owed ? -cents : cents }

    private func start() {
        guard let end = Cents.parse(ending) else { error = "Enter the statement's ending balance."; return }
        let store = EntryStore(context: context)
        var s = statement
        s.endingCents = owed ? -end : end
        s.serviceChargeCents = charge.nilIfBlank.flatMap(Cents.parse) ?? 0
        s.interestCents = interest.nilIfBlank.flatMap(Cents.parse) ?? 0
        if s.serviceChargeCents != 0, !s.serviceChargeCategory.isEmpty, store.category(named: s.serviceChargeCategory) == nil {
            error = "There's no category named “\(s.serviceChargeCategory)”."; return
        }
        if s.interestCents != 0, !s.interestCategory.isEmpty, store.category(named: s.interestCategory) == nil {
            error = "There's no category named “\(s.interestCategory)”."; return
        }
        do {
            statement = try reconciler.enterChargesAndInterest(s)
            // Charges are now in the register; a postponed session must not add them again.
            Reconciler.postpone(statement, for: account)
            phase = .marking
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Step 2 — check off what cleared

    // Column widths add up to fit the 860-point minimum width without a horizontal scroller.

    private var marking: some View {
        let candidates = rows.filter { $0.status != .reconciled && (showLater || $0.date <= statement.date) }
        let later = rows.lazy.filter { $0.status != .reconciled && $0.date > statement.date }.count
        let marked = candidates.filter { $0.status == .cleared }
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Balance \(account.name)").font(.title2.bold())
                    Text("Statement of \(Day.string(statement.date)) · click ✓ for each transaction on the statement")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show \(later) after statement date", isOn: $showLater).disabled(later == 0)
            }
            .padding()
            Divider()
            FastTable(rows: candidates, columns: columns, selection: $selection, multipleSelection: true,
                      autosave: "BalanceAccount.v2", scrollKey: showLater,
                      menu: { ids in [
                          .button("Mark Cleared") { set(ids, cleared: true) },
                          .button("Mark Uncleared") { set(ids, cleared: false) },
                      ] },
                      onDoubleClick: { toggle($0.id) })
            Divider()
            HStack(alignment: .bottom, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Mark All") { set(Set(candidates.map(\.id)), cleared: true) }
                        Button("Unmark All") { set(Set(candidates.map(\.id)), cleared: false) }
                    }
                    let ins = marked.filter { $0.effect > 0 }, outs = marked.filter { $0.effect < 0 }
                    Text("\(ins.count) deposits \(Cents.string(ins.reduce(0) { $0 + $1.effect })) · \(outs.count) payments \(Cents.string(outs.reduce(0) { $0 + $1.effect }))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                figure("Statement ending", display(statement.endingCents))
                figure("Cleared balance", display(clearedCents))
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Difference").font(.caption).foregroundStyle(.secondary)
                    Text(Cents.string(display(difference)))
                        .font(.title.bold()).monospacedDigit()
                        .foregroundStyle(difference == 0 ? .green : .orange)
                        .contentTransition(.numericText())
                        .animation(.default, value: difference)
                }
            }
            .padding()
            if let error { Text(error).foregroundStyle(.red).padding(.bottom, 8) }
            HStack {
                Text(difference == 0 ? "Balanced. Click Finish to mark these transactions reconciled." : "Keep marking until the difference is zero.")
                    .foregroundStyle(difference == 0 ? .green : .secondary)
                Spacer()
                Button("Postpone") { Reconciler.postpone(statement, for: account); dismiss() }
                    .help("Keep your marks and come back to it later")
                Button("Finish") { difference == 0 ? finish(adjust: false) : (confirmAdjust = true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(difference == 0 ? .green : .accentColor)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 560, idealHeight: 680)
        .confirmationDialog("The account is off by \(Cents.string(abs(difference))).", isPresented: $confirmAdjust) {
            Button("Add \(Cents.string(difference)) Adjustment and Finish") { finish(adjust: true) }
            Button("Keep Balancing", role: .cancel) {}
        } message: {
            Text("MacMoney can enter a “Balance Adjustment” transaction for the difference so the account matches the statement. It's usually better to find the missing or mistyped transaction.")
        }
    }

    private var columns: [FastColumn<EntryRow>] {
        [
            FastColumn("✓", id: "cleared", width: 26, min: 22, max: 34, align: .center, help: "Click to mark cleared") { _ in "" } style: { r in
                r.status == .cleared
                    ? FastCellStyle(color: .systemGreen, symbol: "checkmark.circle.fill", tooltip: "Cleared — click to unmark")
                    : FastCellStyle(color: .tertiaryLabelColor, symbol: "circle", tooltip: "Click to mark cleared")
            }
            .sorted(by: { $0.status == .cleared ? 1 : 0 })
            .onClick { toggle($0.id) },
            FastColumn("Date", width: 80, min: 70, monospaced: true) { Day.string($0.date) } style: { r in FastCellStyle(dimmed: r.date > statement.date) }
                .sorted(by: { DateOrder(date: $0.date, order: $0.order) }),
            FastColumn("Num", width: 50, min: 36) { $0.number }.sortedText { $0.number },
            FastColumn("Payee", width: 240, min: 100) { r in r.isVoid ? "\(r.payee)  VOID" : r.payee }.sortedText { $0.payee },
            FastColumn("Memo", width: 185, min: 80) { $0.memo } style: { _ in FastCellStyle(color: .secondaryLabelColor) }.sortedText { $0.memo },
            FastColumn("Payment", width: 90, min: 60, align: .right, monospaced: true) { $0.amount < 0 ? Cents.plain($0.amount) : "" }
                .sorted(by: { $0.amount < 0 ? -$0.amount : 0 }, descendingFirst: true),
            FastColumn("Deposit", width: 90, min: 60, align: .right, monospaced: true) { $0.amount > 0 ? Cents.plain($0.amount) : "" }
                .sorted(by: { max(0, $0.amount) }, descendingFirst: true),
        ]
    }

    private func figure(_ title: String, _ cents: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Cents.string(cents)).font(.title3).monospacedDigit()
        }
    }

    private func toggle(_ id: PersistentIdentifier) {
        guard let e = context.model(for: id) as? Entry else { return }
        set([id], cleared: e.status != .cleared)
    }

    private func set(_ ids: Set<PersistentIdentifier>, cleared: Bool) {
        for id in ids {
            guard let e = context.model(for: id) as? Entry, e.status != .reconciled else { continue }
            e.status = cleared ? .cleared : .uncleared
            e.dateCleared = cleared ? (e.dateCleared ?? Day.today) : nil
        }
        try? context.save()
    }

    private func finish(adjust: Bool) {
        do {
            phase = .done(try reconciler.finish(statement, adjust: adjust))
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Done

    private func done(_ count: Int) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("\(account.name) is balanced").font(.title2.bold())
            Text("\(count) transactions marked reconciled through the \(Day.string(statement.date)) statement.")
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(width: 440)
    }
}
