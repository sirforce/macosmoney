import SwiftUI
import SwiftData

/// Bulk tagging for commingled accounts: filter, select many, then tag as business / personal,
/// set a Schedule C line, business-use %, or vehicle.
struct TagTransactionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(LedgerIndex.self) private var index
    @Query(sort: \Account.name) private var accountsByName: [Account]
    private var accounts: [Account] { accountsByName.inSidebarOrder }
    @Query(sort: \Vehicle.name) private var vehicles: [Vehicle]
    let business: Business

    enum Show: String, CaseIterable, Identifiable {
        case all = "All"
        case untagged = "Not tagged"
        case thisBusiness = "This business"
        case needsLine = "This business, no tax line"
        case personal = "Marked personal"
        var id: String { rawValue }
    }

    @State private var accountID: PersistentIdentifier?
    @State private var period: ReportPeriod = .thisYear
    @State private var search = ""
    @State private var show: Show = .all
    @State private var hideTransfers = true
    @State private var selection = Set<PersistentIdentifier>()
    @State private var customPercent = 50

    var body: some View {
        let rows = filtered()
        VStack(alignment: .leading, spacing: 0) {
            filters
            actions(rows)
            Divider()
            FastTable(rows: rows, columns: Self.columns, selection: $selection, autosave: "TagTransactions",
                      defaultSort: ("Date", false))
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Account", selection: $accountID) {
                Text("All accounts").tag(PersistentIdentifier?.none)
                ForEach(accounts) { Text($0.name).tag(Optional($0.persistentModelID)) }
            }
            .frame(width: 240)
            Picker("Period", selection: $period) {
                ForEach(ReportPeriod.allCases.filter { $0 != .custom }) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 200)
            Picker("Show", selection: $show) {
                ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 260)
            TextField("Search payee, memo, category", text: $search).textFieldStyle(.roundedBorder)
            Toggle("Hide transfers", isOn: $hideTransfers).toggleStyle(.checkbox)
        }
        .padding(12)
    }

    private func actions(_ rows: [TagRow]) -> some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "\(rows.count) transactions — select some (⌘A for all)" : "\(selection.count) selected")
                .foregroundStyle(.secondary)
            Spacer()
            Button { apply { $0.business = business; $0.isPersonal = false } } label: {
                Label("Tag as \(business.name)", systemImage: "briefcase.fill")
            }
            .buttonStyle(.borderedProminent)
            Button("Personal") { apply { $0.business = nil; $0.isPersonal = true } }
            Menu("Tax Line") {
                Button("Use category's line") { apply { $0.taxLine = nil } }
                Divider()
                ForEach([TaxLine.Part.income, .expenses, .cogs, .other], id: \.self) { part in
                    Section(part.rawValue) {
                        ForEach(TaxLine.allCases.filter { $0.part == part }) { line in
                            Button(line.label) { apply { $0.taxLine = line } }
                        }
                    }
                }
            }
            .frame(width: 110)
            Menu("Business %") {
                ForEach([100, 90, 80, 75, 60, 50, 40, 25, 10], id: \.self) { p in
                    Button("\(p)%") { apply { $0.businessPercent = p } }
                }
            }
            .frame(width: 120)
            Menu("Vehicle") {
                Button("None") { apply { $0.vehicle = nil; $0.vehicleExpense = nil } }
                ForEach(vehicles.filter { $0.business == business }) { v in
                    Menu(v.name) {
                        ForEach(VehicleExpense.allCases) { k in
                            Button(k.title) { apply { $0.vehicle = v; $0.vehicleExpense = k } }
                        }
                    }
                }
            }
            .frame(width: 100)
            Button("Clear Tags") { apply { $0.business = nil; $0.isPersonal = false; $0.taxLine = nil; $0.businessPercent = 100; $0.vehicle = nil; $0.vehicleExpense = nil } }
                .help("Back to the account's default")
        }
        .disabled(selection.isEmpty)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func filtered() -> [TagRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let range = period.range()
        return index.rows.lazy.filter { r in
            if let accountID, r.accountID != accountID { return false }
            if let range, !range.contains(r.date) { return false }
            if hideTransfers && r.isTransfer { return false }
            if !r.matches(q) { return false }
            switch show {
            case .all: return true
            case .untagged: return r.business.isEmpty && !r.isPersonal
            case .thisBusiness: return r.business == business.name
            case .needsLine: return r.business == business.name && r.taxLine.isEmpty
            case .personal: return r.isPersonal
            }
        }
        .map(TagRow.init)
    }

    private func apply(_ change: (Entry) -> Void) {
        for id in selection {
            if let e = context.model(for: id) as? Entry { change(e) }
        }
        try? context.save()
    }
}

extension TagTransactionsView {
    static let columns: [FastColumn<TagRow>] = [
        FastColumn("Date", width: 82, min: 70, monospaced: true) { Day.string($0.date) }
            .sorted(by: { DateOrder(date: $0.date, order: $0.row.order) }),
        FastColumn("Account", width: 130, min: 80) { $0.account } style: { _ in FastCellStyle(color: .secondaryLabelColor) }
            .sortedText { $0.account },
        FastColumn("Payee", width: 180, min: 100) { $0.payee }.sortedText { $0.payee },
        FastColumn("Category", width: 170, min: 80) { $0.category } style: { _ in FastCellStyle(color: .secondaryLabelColor) }
            .sortedText { $0.category },
        FastColumn("Memo", width: 200, min: 80) { $0.memo } style: { FastCellStyle(color: .secondaryLabelColor, tooltip: $0.memo.isEmpty ? nil : $0.memo) }
            .sortedText { $0.memo },
        FastColumn("Amount", width: 95, min: 70, align: .right, monospaced: true) { Cents.string($0.amount) }
            .sorted(by: { $0.amount }),
        FastColumn("Business", width: 140, min: 80) { r in
            var t = r.row.isPersonal ? "Personal" : r.business
            if r.row.businessPercent != 100 { t += " \(r.row.businessPercent)%" }
            return t
        } style: { r in
            FastCellStyle(color: r.row.isPersonal || r.row.businessFromAccount ? .secondaryLabelColor : nil,
                          tooltip: r.row.businessFromAccount ? "From the account's business" : nil)
        }
        .sortedText { $0.row.isPersonal ? "~Personal" : $0.business },
        FastColumn("Line", width: 70, min: 40) { r in
            (r.taxLine.isEmpty ? "—" : r.taxLine) + (r.row.vehicle.isEmpty ? "" : " 🚗")
        } style: { r in
            FastCellStyle(color: r.taxLine.isEmpty && !r.business.isEmpty ? .systemOrange : (r.row.taxLineExplicit ? nil : .secondaryLabelColor),
                          tooltip: r.row.vehicle.isEmpty ? nil : r.row.vehicle)
        }
        .sortedText { $0.taxLine },
    ]
}

struct TagRow: Identifiable {
    let row: EntryRow
    var id: PersistentIdentifier { row.id }
    var date: Date { row.date }
    var account: String { row.accountName }
    var payee: String { row.payee }
    var category: String { row.category }
    var memo: String { row.memo }
    var amount: Int { row.amount }
    var business: String { row.business }
    var taxLine: String { row.taxLine }
    init(_ row: EntryRow) { self.row = row }
}
