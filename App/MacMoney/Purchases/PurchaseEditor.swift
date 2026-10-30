import SwiftUI
import SwiftData

/// What to open the purchase editor with: an existing purchase, or a new one, optionally started
/// from the charge that paid for it.
struct PurchaseEditRequest: Identifiable {
    let id = UUID()
    var purchase: Purchase?
    var charge: Entry?
}

/// Enter or edit a purchase by hand: a receipt from a music store, a camera shop, anywhere.
/// Items can be marked business or personal as they're entered.
struct PurchaseEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Business.name) private var businesses: [Business]
    @Query private var allPurchases: [Purchase]
    let request: PurchaseEditRequest
    var onSave: (Purchase) -> Void = { _ in }

    struct Line: Identifiable {
        let id = UUID()
        var item: PurchaseItem?
        var name = ""
        var amount = ""
        var tag: PurchaseItem.Tag = .untagged
        var cents: Int? { Cents.parse(amount).map(abs) }
        var isBlank: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty && amount.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @State private var vendor = ""
    @State private var date = Day.today
    @State private var orderNumber = ""
    @State private var notes = ""
    @State private var link = ""
    @State private var lines: [Line] = [Line()]
    @State private var chargeUUID: UUID?
    @State private var candidates: [Entry] = []
    @State private var error: String?
    @State private var confirmDelete = false

    @Query(sort: \AppSettings.created) private var settingsRecords: [AppSettings]
    private var business: Business? { PurchaseSettings.defaultBusiness(in: businesses, settings: settingsRecords.first) }
    private var isNew: Bool { request.purchase == nil }
    private var totalCents: Int { lines.compactMap(\.cents).reduce(0, +) }
    private var charge: Entry? { candidates.first { $0.uuid == chargeUUID } }

    /// Vendors used before, most frequent first.
    private var knownVendors: [String] {
        let counts = Dictionary(allPurchases.map { ($0.vendor, 1) }, uniquingKeysWith: +)
        return counts.keys.filter { !$0.isEmpty }.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }.prefix(15).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(isNew ? "New Purchase" : "Edit Purchase", systemImage: "cart").font(.title2.bold())
            Form {
                Section {
                    HStack {
                        TextField("Vendor", text: $vendor, prompt: Text("Store or website"))
                        if !knownVendors.isEmpty {
                            Menu {
                                ForEach(knownVendors, id: \.self) { v in Button(v) { vendor = v } }
                            } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .help("Vendors you've used")
                        }
                    }
                    DatePicker("Date", selection: Binding(get: { Day.toLocal(date) }, set: { date = Day.normalize($0) }),
                               displayedComponents: .date)
                    TextField("Order or receipt #", text: $orderNumber, prompt: Text("Optional"))
                    TextField("Link", text: $link, prompt: Text("Order or receipt web page (optional)"))
                }
                Section {
                    ForEach($lines) { $line in lineRow($line) }
                    HStack {
                        Button { lines.append(Line()) } label: { Label("Add Item", systemImage: "plus") }
                        Spacer()
                        Text("Total \(Cents.string(totalCents))").monospacedDigit().bold()
                    }
                } header: {
                    Text("Items")
                } footer: {
                    Text("Enter what each item cost, including its share of tax if you like. Mark items for the business now or later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Paid with") {
                    Picker("Charge", selection: $chargeUUID) {
                        Text("Not linked").tag(UUID?.none)
                        ForEach(candidates.prefix(12), id: \.uuid) { e in
                            Text("\(Day.string(e.date))  \(e.payee?.name ?? "")  \(Cents.string(-e.amountCents))  · \(e.account?.name ?? "")")
                                .tag(Optional(e.uuid))
                        }
                    }
                    if let charge { remainder(charge) }
                    TextField("Notes", text: $notes, axis: .vertical)
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if !isNew && request.purchase?.importKey == nil {
                    Button("Delete Purchase…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(vendor.trimmingCharacters(in: .whitespaces).isEmpty || lines.allSatisfy(\.isBlank))
            }
        }
        .padding(20)
        .frame(width: 640, height: 620)
        .onAppear(perform: load)
        .onChange(of: date) { refreshCandidates() }
        .confirmationDialog("Delete this purchase?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let p = request.purchase { context.delete(p); try? context.save() }
                dismiss()
            }
        } message: { Text("Its items and their business tags are removed. The charge stays in its register.") }
    }

    private func lineRow(_ line: Binding<Line>) -> some View {
        HStack(spacing: 8) {
            TextField("Item", text: line.name, prompt: Text("What you bought")).labelsHidden()
            TextField("Amount", text: line.amount, prompt: Text("0.00")).labelsHidden()
                .monospacedDigit().multilineTextAlignment(.trailing).frame(width: 90)
            Picker("For", selection: line.tag) {
                Text("—").tag(PurchaseItem.Tag.untagged)
                Text(business?.name ?? "Business").tag(PurchaseItem.Tag.business)
                Text("Personal").tag(PurchaseItem.Tag.personal)
            }
            .labelsHidden().frame(width: 130)
            Button { lines.removeAll { $0.id == line.wrappedValue.id }; if lines.isEmpty { lines = [Line()] } } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove item")
        }
    }

    /// When the items don't add up to the charge (tax, shipping), offer to add the rest.
    @ViewBuilder private func remainder(_ e: Entry) -> some View {
        let rest = -e.amountCents - totalCents
        if rest != 0 {
            HStack {
                Text(rest > 0 ? "\(Cents.string(rest)) of the charge isn't in an item yet" : "Items are \(Cents.string(-rest)) more than the charge")
                    .foregroundStyle(.orange)
                Spacer()
                if rest > 0 {
                    Button("Add as “Tax & shipping”") {
                        lines.removeAll(where: \.isBlank)
                        lines.append(Line(name: "Tax & shipping", amount: Cents.plain(rest)))
                    }
                }
            }
            .font(.callout)
        }
    }

    // MARK: Loading and saving

    private func load() {
        if let p = request.purchase {
            vendor = p.vendor
            date = p.date
            orderNumber = p.orderNumber
            notes = p.notes
            link = p.link
            chargeUUID = p.entryUUID
            lines = p.sortedItems.map { Line(item: $0, name: $0.name, amount: Cents.plain($0.amountCents), tag: $0.tag) }
            if lines.isEmpty { lines = [Line()] }
        } else if let e = request.charge {
            vendor = e.payee?.name ?? ""
            date = e.date
            chargeUUID = e.uuid
            lines = [Line(amount: Cents.plain(-e.amountCents))]
        }
        refreshCandidates()
    }

    private func refreshCandidates() {
        var list = PurchaseImporter(context: context)
            .chargeCandidates(near: date, totalCents: totalCents, keeping: request.purchase?.entryUUID ?? request.charge?.uuid)
        // The charge it came from (or is linked to) stays available even when it's further away.
        if let id = chargeUUID, !list.contains(where: { $0.uuid == id }),
           let e = try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.uuid == id })).first {
            list.insert(e, at: 0)
        }
        candidates = list
    }

    private func save() {
        let filled = lines.filter { !$0.isBlank }
        if let bad = filled.first(where: { $0.cents == nil }) {
            error = "Enter an amount for “\(bad.name.isEmpty ? "the item" : bad.name)”."
            return
        }
        let p: Purchase
        if let existing = request.purchase {
            p = existing
        } else {
            p = Purchase(vendor: "", date: date)
            p.source = "manual"
            context.insert(p)
        }
        p.vendor = vendor.trimmingCharacters(in: .whitespaces)
        p.date = date
        p.orderNumber = orderNumber.trimmingCharacters(in: .whitespaces)
        p.notes = notes
        p.link = link.trimmingCharacters(in: .whitespaces)
        p.entryUUID = chargeUUID

        // Keep existing items (and their line, %, purpose); remove the ones taken out.
        let kept = Set(filled.compactMap { $0.item?.uuid })
        for item in p.items ?? [] where !kept.contains(item.uuid) { context.delete(item) }
        for (n, line) in filled.enumerated() {
            let item: PurchaseItem
            if let existing = line.item {
                item = existing
            } else {
                item = PurchaseItem(name: "", amountCents: 0)
                context.insert(item)
                item.purchase = p
            }
            item.name = line.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Item \(n + 1)" : line.name.trimmingCharacters(in: .whitespaces)
            item.amountCents = line.cents ?? 0
            item.created = p.created.addingTimeInterval(Double(n))   // keeps the entered order
            switch line.tag {
            case .business:
                item.businessUUID = item.businessUUID ?? business?.uuid
                item.isPersonal = false
                if item.taxLine == nil { item.taxLine = PurchaseRules.suggestedLine(for: item) }
            case .personal:
                item.businessUUID = nil
                item.isPersonal = true
            case .untagged:
                item.businessUUID = nil
                item.isPersonal = false
            }
        }
        do {
            try context.save()
            onSave(p)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
