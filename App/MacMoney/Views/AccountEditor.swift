import SwiftUI
import SwiftData

/// Create or edit an account. An account can be linked to a business so everything in it counts
/// toward that business's Schedule C by default.
struct AccountEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Business.name) private var businesses: [Business]

    let account: Account?
    var onCreated: (Account) -> Void = { _ in }

    @State private var name = ""
    @State private var kind: AccountKind = .bank
    @State private var opening = ""
    @State private var openDate = Day.today
    @State private var number = ""
    @State private var notes = ""
    @State private var business: Business?
    @State private var closed = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(account == nil ? "New Account" : "Edit Account").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $kind) {
                    ForEach(AccountKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Opening balance", text: $opening).monospacedDigit()
                    .help(kind == .creditCard || kind == .loan ? "Enter what you owe as a negative number" : "")
                DatePicker("Opened", selection: Binding(get: { Day.toLocal(openDate) }, set: { openDate = Day.normalize($0) }),
                           displayedComponents: .date)
                TextField("Account number", text: $number)
                Picker("Business", selection: $business) {
                    Text("Personal (none)").tag(Business?.none)
                    ForEach(businesses) { Text($0.name).tag(Optional($0)) }
                }
                .help("Transactions in a business account count toward that business's Schedule C unless marked personal")
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                if account != nil {
                    Toggle("Closed (read-only, kept for history)", isOn: $closed)
                }
            }
            if account?.moneyId != nil {
                Text("Imported from Money — name and balance are refreshed on re-import. Closing or reopening it here, and the business link, are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(account == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    private func load() {
        guard let a = account else { return }
        name = a.name
        kind = a.kind
        opening = Cents.plain(a.openingBalanceCents).replacingOccurrences(of: ",", with: "")
        if a.openingBalanceCents < 0 { opening = "-" + opening }
        openDate = a.openDate ?? Day.today
        number = a.accountNumber ?? ""
        notes = a.notes ?? ""
        business = a.business
        closed = a.isClosed
    }

    private func save() {
        guard let trimmed = name.nilIfBlank else { error = "Enter a name."; return }
        let openingCents = opening.nilIfBlank.map { Cents.parse($0) } ?? 0
        guard let openingCents else { error = "Opening balance isn't a valid amount."; return }
        let a = account ?? Account(name: trimmed, kind: kind)
        if account == nil { context.insert(a) }
        a.name = trimmed
        a.kind = kind
        a.openingBalanceCents = openingCents
        a.openDate = openDate
        a.accountNumber = number.nilIfBlank
        a.notes = notes.nilIfBlank
        a.business = business
        // Money refreshes a Money account's closed status on re-import; remember the user's choice.
        if a.moneyId != nil, a.isClosed != closed { a.closedOverride = closed }
        a.isClosed = closed
        try? context.save()
        if account == nil { onCreated(a) }
        dismiss()
    }
}
