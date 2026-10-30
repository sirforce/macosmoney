import SwiftUI
import SwiftData

/// "The bank says the balance on this date is X." Shows what MacMoney has and what will change.
struct SetBalanceView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var date = Day.today
    @State private var amount = ""
    @State private var error: String?

    private var owed: Bool { account.kind == .creditCard || account.kind == .loan }
    /// What the bank shows, signed the way MacMoney stores it (amount owed is negative).
    private var bankCents: Int? { Cents.parse(amount).map { owed ? -abs($0) : $0 } }
    private var current: Int { BalanceAdjustment.balance(of: account, on: date) }
    private var method: BalanceAdjustment.Method { BalanceAdjustment.method(for: account) }
    private func shown(_ cents: Int) -> String { Cents.string(owed ? -cents : cents) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Set Balance", systemImage: "scalemass").font(.title2.bold())
            Text("Enter the balance the bank shows for \(account.name) on a date, such as today's balance or a statement's ending balance.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                DatePicker("Balance on", selection: Binding(get: { Day.toLocal(date) }, set: { date = Day.normalize($0) }),
                           displayedComponents: .date)
                TextField(owed ? "Amount owed" : "Balance", text: $amount, prompt: Text("0.00"))
                    .monospacedDigit()
                LabeledContent("MacMoney shows") { Text(shown(current)).monospacedDigit() }
                if let bank = bankCents {
                    let diff = bank - current
                    LabeledContent("Difference") {
                        Text(Cents.string(owed ? -diff : diff)).monospacedDigit()
                            .foregroundStyle(diff == 0 ? .green : .orange)
                    }
                }
            }
            .formStyle(.grouped)
            explanation
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Balance") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(bankCents == nil || bankCents == current)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder private var explanation: some View {
        if let bank = bankCents, bank != current {
            let diff = bank - current
            switch method {
            case .openingBalance:
                Text("The opening balance changes from \(shown(account.openingBalanceCents)) to \(shown(account.openingBalanceCents + diff)), so every balance before and after \(Day.string(date)) shifts by the difference. Use this when your download didn't reach back to when the account opened.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .correction:
                Text("A reconciled “Balance Correction” of \(Cents.string(diff)) is added on \(Day.string(date)). The account has history from Money, which is left as it is.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        guard let bank = bankCents else { error = "Enter the balance."; return }
        BalanceAdjustment.set(account, to: bank, on: date, context: context)
        do { try context.save(); dismiss() } catch { self.error = error.localizedDescription }
    }
}
