import SwiftUI
import SwiftData

/// A business's depreciable assets and each year's depreciation, entered from the accountant's
/// depreciation schedule. The year's amounts go on Schedule C line 13.
struct AssetsView: View {
    @Environment(\.modelContext) private var context
    let business: Business
    @Query private var allAssets: [Asset]
    @State private var selection: PersistentIdentifier?
    @State private var year = Day.year(of: Day.today) - (DemoTour.preset("business.lastYear") == nil ? 0 : 1)
    @State private var deleting: Asset?

    private var assets: [Asset] {
        allAssets.filter { $0.businessUUID == business.uuid }
            .sorted { ($0.placedInService ?? .distantPast, $0.name) < ($1.placedInService ?? .distantPast, $1.name) }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Stepper("Tax year \(String(year))", value: $year, in: 1990...2100)
                    Spacer()
                    Text("Line 13 for \(String(year)): \(Cents.string(assets.reduce(0) { $0 + ($1.yearAmounts[year] ?? 0) }))")
                        .fontWeight(.semibold).monospacedDigit()
                }
                .padding(12)
                Table(assets, selection: $selection) {
                    TableColumn("Asset") { a in
                        Text(a.name).foregroundStyle(a.disposedDate == nil ? .primary : .secondary)
                    }
                    .width(min: 200, ideal: 300)
                    TableColumn("In service") { a in Text(Day.string(a.placedInService)).monospacedDigit() }.width(76)
                    TableColumn("Cost") { a in money(a.costCents) }.width(92)
                    TableColumn(String(year)) { a in money(a.yearAmounts[year] ?? 0, dimZero: true) }.width(92)
                    TableColumn("Depreciated") { a in money(a.depreciatedCents(through: year)) }.width(96)
                    TableColumn("Remaining") { a in
                        money(a.remainingCents(through: year)).foregroundStyle(a.remainingCents(through: year) < 0 ? .red : .primary)
                    }
                    .width(92)
                }
                .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
                    Button("Delete Asset…", role: .destructive) { deleting = assets.first { ids.contains($0.persistentModelID) } }
                }
                HStack {
                    Button { add() } label: { Label("Add Asset", systemImage: "plus") }
                    Spacer()
                    Text("Enter each year's amount from your accountant's depreciation schedule. MacMoney doesn't calculate depreciation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .frame(minWidth: 680, maxWidth: .infinity)
            if let a = assets.first(where: { $0.persistentModelID == selection }) {
                AssetDetail(asset: a).id(a.persistentModelID)
            } else {
                ContentUnavailableView("Add an asset", systemImage: "shippingbox.and.arrow.backward",
                                       description: Text("Equipment, computers, furniture and other things the business depreciates over several years. Your accountant's depreciation schedule lists them with each year's amount."))
                    .frame(minWidth: 340)
            }
        }
        .onAppear { if selection == nil { selection = assets.first?.persistentModelID } }
        .confirmationDialog("Delete asset?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { a in
            Button("Delete \(a.name)", role: .destructive) {
                context.delete(a)
                try? context.save()
            }
        } message: { _ in
            Text("Its depreciation comes off Schedule C for every year. If it was sold or scrapped, set a disposed date instead.")
        }
    }

    private func money(_ cents: Int, dimZero: Bool = false) -> some View {
        Text(Cents.string(cents)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            .foregroundStyle(dimZero && cents == 0 ? .tertiary : .primary)
    }

    private func add() {
        let a = Asset(name: "New asset")
        a.businessUUID = business.uuid
        a.placedInService = Day.today
        context.insert(a)
        try? context.save()
        selection = a.persistentModelID
    }
}

private struct AssetDetail: View {
    @Environment(\.modelContext) private var context
    @Bindable var asset: Asset
    @State private var cost = ""
    @State private var prior = ""
    @State private var years: [YearRow] = []

    struct YearRow: Identifiable {
        let id = UUID()
        var year: Int
        var amount: String
    }

    var body: some View {
        Form {
            Section("Asset") {
                TextField("Description", text: $asset.name)
                DatePicker("Placed in service", selection: Binding(get: { Day.toLocal(asset.placedInService ?? Day.today) },
                                                                  set: { asset.placedInService = Day.normalize($0) }), displayedComponents: .date)
                TextField("Cost or basis", text: $cost, prompt: Text("0.00"))
                    .onChange(of: cost) { asset.costCents = Cents.parse(cost) ?? 0 }
                TextField("Method", text: $asset.method, prompt: Text("As on the schedule, e.g. 5-yr MACRS, Section 179"))
            }
            Section {
                TextField("Before the years below", text: $prior, prompt: Text("0.00"))
                    .onChange(of: prior) { asset.priorDepreciationCents = Cents.parse(prior) ?? 0 }
                    .help("Depreciation already taken in earlier years, as one figure, if you aren't entering those years one by one.")
                ForEach($years) { $row in
                    HStack {
                        TextField("Year", value: $row.year, format: .number.grouping(.never)).frame(width: 70).labelsHidden()
                        TextField("Amount", text: $row.amount, prompt: Text("0.00")).labelsHidden().multilineTextAlignment(.trailing)
                        Button { years.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this year")
                    }
                }
                Button { years.append(YearRow(year: (years.map(\.year).max() ?? Day.year(of: Day.today) - 1) + 1, amount: "")) } label: {
                    Label("Add Year", systemImage: "plus")
                }
            } header: {
                Text("Depreciation by tax year")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Depreciated so far") { Text(Cents.string(asset.depreciatedCents())).monospacedDigit() }
                    LabeledContent("Remaining") {
                        Text(Cents.string(asset.remainingCents())).monospacedDigit().foregroundStyle(asset.remainingCents() < 0 ? .red : .primary)
                    }
                    if asset.remainingCents() < 0 {
                        Label("More has been depreciated than the asset cost. Check the amounts against the schedule.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }
            Section("Disposal and notes") {
                Toggle("Sold, scrapped or no longer used", isOn: Binding(get: { asset.disposedDate != nil },
                                                                        set: { asset.disposedDate = $0 ? Day.today : nil }))
                if asset.disposedDate != nil {
                    DatePicker("Date", selection: Binding(get: { Day.toLocal(asset.disposedDate ?? Day.today) },
                                                          set: { asset.disposedDate = Day.normalize($0) }), displayedComponents: .date)
                }
                TextField("Notes", text: $asset.notes, axis: .vertical).lineLimit(2...5)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 340, idealWidth: 380, maxWidth: 420)
        .onAppear {
            cost = asset.costCents == 0 ? "" : Cents.plain(asset.costCents)
            prior = asset.priorDepreciationCents == 0 ? "" : Cents.plain(asset.priorDepreciationCents)
            years = asset.yearAmounts.sorted { $0.key < $1.key }.map { YearRow(year: $0.key, amount: Cents.plain($0.value)) }
        }
        .onChange(of: years.map { "\($0.year)=\($0.amount)" }) {
            var amounts: [Int: Int] = [:]
            for row in years { if let c = Cents.parse(row.amount), c != 0 { amounts[row.year, default: 0] += abs(c) } }
            asset.yearAmounts = amounts
            try? context.save()
        }
        .onDisappear { try? context.save() }
    }
}
