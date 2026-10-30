import SwiftUI
import SwiftData

/// Search every transaction in every account (open and closed) by any fragment of the memo,
/// payee, category, check number or amount. Double-click a result to open it in its register.
struct FindView: View {
    @Environment(LedgerIndex.self) private var index
    var open: (_ entry: PersistentIdentifier, _ account: PersistentIdentifier) -> Void

    @State private var query = ""
    @State private var period: ReportPeriod = .allDates
    @State private var memoOnly = false
    @State private var selection = Set<PersistentIdentifier>()
    @FocusState private var focused: Bool

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let range = period.range()
        let results: [FindRow] = q.count < 2 ? [] : index.rows
            .filter { r in
                (memoOnly ? r.memo.lowercased().contains(q) : r.matches(q)) && (range?.contains(r.date) ?? true)
            }
            .map(FindRow.init)
        let total = results.reduce(0) { $0 + $1.row.effect }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search for any part of a memo, payee, category, number or amount", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($focused)
                Toggle("Memo only", isOn: $memoOnly).toggleStyle(.checkbox)
                Picker("", selection: $period) {
                    ForEach(ReportPeriod.allCases.filter { $0 != .custom }) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            .padding(12)
            HStack {
                Text(q.count < 2 ? "Type at least 2 characters" : "\(results.count) transactions · net \(Cents.string(total))")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("Double-click to open in register").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            FastTable(rows: results, columns: Self.columns, selection: $selection, autosave: "Find",
                      defaultSort: ("Date", false), scrollKey: q, onDoubleClick: { r in
                if let account = r.row.accountID { open(r.id, account) }
            })
        }
        .navigationTitle("Find Transactions")
        .onAppear { focused = true }
    }
}

extension FindView {
    static let columns: [FastColumn<FindRow>] = [
        FastColumn("Date", width: 82, min: 70, monospaced: true) { Day.string($0.date) }
            .sorted(by: { DateOrder(date: $0.date, order: $0.row.order) }),
        FastColumn("Account", width: 150, min: 80) { $0.account }.sortedText { $0.account },
        FastColumn("Num", width: 56, min: 36) { $0.number }.sortedText { $0.number },
        FastColumn("Payee", width: 190, min: 100) { $0.payee }.sortedText { $0.payee },
        FastColumn("Category", width: 170, min: 80) { $0.category } style: { _ in FastCellStyle(color: .secondaryLabelColor) }
            .sortedText { $0.category },
        FastColumn("Memo", width: 320, min: 100) { $0.memo } style: { FastCellStyle(tooltip: $0.memo.isEmpty ? nil : $0.memo) }
            .sortedText { $0.memo },
        FastColumn("Amount", width: 100, min: 70, align: .right, monospaced: true) { Cents.string($0.amount) } style: { r in
            FastCellStyle(color: r.amount < 0 ? nil : .systemGreen)
        }
        .sorted(by: { $0.amount }),
    ]
}

struct FindRow: Identifiable {
    let row: EntryRow
    var id: PersistentIdentifier { row.id }
    var date: Date { row.date }
    var account: String { row.accountName }
    var number: String { row.number }
    var payee: String { row.payee }
    var category: String { row.category }
    var memo: String { row.memo }
    var amount: Int { row.amount }

    init(_ row: EntryRow) { self.row = row }
}
