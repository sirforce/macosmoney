import SwiftUI
import SwiftData
import AppKit

/// Everything bought, item by item, for marking what was for the business.
/// Select items and press B (business) or P (personal); details go in the panel on the right.
struct PurchasesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]
    @Query(sort: \Business.name) private var businesses: [Business]
    /// Opens a transaction in its register.
    var open: (PersistentIdentifier, PersistentIdentifier) -> Void = { _, _ in }
    /// Purchase to select on arrival (from a register's "Show Purchase").
    var initialPurchase: UUID?
    /// An Amazon export to import as soon as the page is showing (dropped on the window).
    @Binding var importURL: URL?

    enum Show: String, CaseIterable, Identifiable {
        case needsReview = "Needs review"
        case business = "Business"
        case personal = "Personal"
        case unlinked = "Not linked to a charge"
        case all = "All"
        var id: String { rawValue }
    }

    @AppStorage("purchases.show") private var show: Show = .needsReview
    @AppStorage("purchases.period") private var period: ReportPeriod = .allDates
    @AppStorage("purchases.showHidden") private var showHidden = false
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var importing = false
    @State private var importMessage: String?
    @State private var linking: Purchase?
    @State private var editing: PurchaseEditRequest?

    @Query(sort: \AppSettings.created) private var settingsRecords: [AppSettings]
    private var settings: AppSettings? { settingsRecords.first }
    private var reviewFrom: Date { settings?.reviewFrom ?? AppSettings.defaultReviewFrom }
    private var business: Business? { PurchaseSettings.defaultBusiness(in: businesses, settings: settings) }

    var body: some View {
        Group {
            if purchases.isEmpty { empty } else { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Purchases")
        .toolbar {
            ToolbarItem {
                Button { editing = PurchaseEditRequest() } label: { Label("New Purchase", systemImage: "cart.badge.plus") }
                    .help("Enter a purchase by hand")
            }
            ToolbarItem {
                Button { chooseExport() } label: { Label("Import Amazon Orders…", systemImage: "shippingbox") }
                    .help("Import your Amazon order history (Amazon ▸ Account ▸ Request Your Data)")
            }
        }
        .sheet(item: $linking) { LinkChargeView(purchase: $0) }
        .sheet(item: $editing) { PurchaseEditor(request: $0) { p in reveal(p) } }
        .alert("Amazon Orders", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") {}
        } message: { Text(importMessage ?? "") }
        .onAppear {
            if let id = initialPurchase, let p = purchases.first(where: { $0.uuid == id }) {
                show = .all
                selection = Set(p.sortedItems.map(\.uuid))
            }
        }
        .task(id: importURL) {
            guard let url = importURL else { return }
            importURL = nil
            runImport(url)
        }
    }

    private var content: some View {
        let rows = filtered()
        return HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                filters
                Divider()
                if rows.isEmpty {
                    noMatches
                } else {
                    FastTable(rows: rows, columns: Self.columns(businesses), selection: $selection, autosave: "Purchases",
                              defaultSort: ("Date", false),
                              menu: { menu(for: $0) },
                              onDoubleClick: { r in
                                  if r.purchase.importKey == nil { editing = PurchaseEditRequest(purchase: r.purchase) } else { showCharge(r.purchase) }
                              },
                              onKey: { key, ids in tagKey(key, ids) })
                }
                footer(rows)
            }
            .frame(minWidth: 560)
            PurchaseDetail(items: selectedItems, business: business, open: open, link: { linking = $0 })
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420, maxHeight: .infinity)
        }
    }

    private var noMatches: some View {
        ContentUnavailableView(show == .needsReview ? "All caught up" : "Nothing matches",
                               systemImage: show == .needsReview ? "checkmark.circle" : "magnifyingglass",
                               description: Text(show == .needsReview
                                                 ? "Every purchase from \(Day.string(reviewFrom)) on is marked business or personal."
                                                 : "Try another Show or Period choice, or clear the search."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $show) {
                ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 250)
            Picker("Period", selection: $period) {
                ForEach(ReportPeriod.allCases.filter { $0 != .custom }) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 200)
            TextField("Search items, vendor, order", text: $search).textFieldStyle(.roundedBorder)
            Toggle("Show hidden", isOn: $showHidden).toggleStyle(.checkbox)
                .help("Include items you've hidden (shown dimmed)")
            if businesses.count > 1 {
                Picker("For", selection: Binding(get: { business?.uuid }, set: {
                    AppSettings.current(in: context).purchasesBusinessUUID = $0
                    try? context.save()
                })) {
                    ForEach(businesses) { Text($0.name).tag(Optional($0.uuid)) }
                }
                .frame(width: 200)
                .help("The business that B tags items for")
            }
        }
        .padding(12)
    }

    private func footer(_ rows: [PurchaseRow]) -> some View {
        HStack(spacing: 14) {
            let pending = purchases.filter { PurchaseSettings.needsReview($0, from: reviewFrom) }.count
            Text(selection.isEmpty
                 ? "\(rows.count) items · \(pending) purchases to review"
                 : "\(selection.count) selected · \(Cents.string(selectedItems.reduce(0) { $0 + $1.amountCents }))")
                .foregroundStyle(.secondary)
            Spacer()
            Text("B business · P personal · U undo · H hide").font(.caption).foregroundStyle(.tertiary)
            Button { tag(selection, business: true) } label: {
                Label(business.map { "Business (\($0.name))" } ?? "Business", systemImage: "briefcase.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty || business == nil)
            Button("Personal") { tag(selection, business: false) }.disabled(selection.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("No purchases yet").font(.title.bold())
                Text("Keep track of what you buy, item by item, and mark what was for the business.")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                startCard("Enter a purchase", symbol: "cart.badge.plus",
                          text: "From any store. Tip: right-click a charge in a register ▸ Itemize Purchase… to start from it.",
                          button: "New Purchase…") { editing = PurchaseEditRequest() }
                startCard("Import Amazon orders", symbol: "square.and.arrow.down",
                          text: "On Amazon, Account ▸ Request Your Data ▸ Your Orders. Unzip the download and choose the folder (or drop it on this window).",
                          button: "Import Amazon Orders…") { chooseExport() }
            }
            .frame(maxWidth: 640)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startCard(_ title: String, symbol: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button, action: action)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Rows

    private var selectedItems: [PurchaseItem] {
        guard !selection.isEmpty else { return [] }
        return purchases.flatMap { $0.items ?? [] }.filter { selection.contains($0.uuid) }
    }

    private func filtered() -> [PurchaseRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let range = period.range()
        let from = reviewFrom
        var rows: [PurchaseRow] = []
        for p in purchases {
            if let range, !range.contains(p.chargeDate) { continue }
            switch show {
            case .needsReview: if p.chargeDate < from || p.review != .needsReview { continue }
            case .unlinked: if p.entryUUID != nil { continue }
            default: break
            }
            let header = "\(p.vendor) \(p.orderNumber)".lowercased()
            for item in p.sortedItems {
                if item.isHidden && !showHidden { continue }
                switch show {
                case .business: if item.tag != .business { continue }
                case .personal: if item.tag != .personal { continue }
                default: break
                }
                if !q.isEmpty && !header.contains(q) && !item.name.lowercased().contains(q) && !item.department.lowercased().contains(q)
                    && !item.notes.lowercased().contains(q) { continue }
                rows.append(PurchaseRow(item: item, purchase: p))
            }
        }
        return rows
    }

    // MARK: Tagging

    private func tagKey(_ key: String, _ ids: Set<UUID>) -> Bool {
        switch key.lowercased() {
        case "b": guard business != nil else { return false }; tag(ids, business: true)
        case "p": tag(ids, business: false)
        case "u": tag(ids, business: nil)
        case "h": setHidden(ids)
        default: return false
        }
        return true
    }

    /// true = the business, false = personal, nil = not reviewed.
    private func tag(_ ids: Set<UUID>, business isBusiness: Bool?) {
        for item in purchases.flatMap({ $0.items ?? [] }) where ids.contains(item.uuid) {
            switch isBusiness {
            case true?:
                item.businessUUID = business?.uuid
                item.isPersonal = false
                if item.taxLine == nil { item.taxLine = PurchaseRules.suggestedLine(for: item) }
            case false?:
                item.businessUUID = nil
                item.isPersonal = true
            case nil:
                item.businessUUID = nil
                item.isPersonal = false
            }
        }
        try? context.save()
    }

    /// Hides the items, or shows them again when they're all hidden already.
    private func setHidden(_ ids: Set<UUID>, _ hidden: Bool? = nil) {
        let items = purchases.flatMap { $0.items ?? [] }.filter { ids.contains($0.uuid) }
        let hide = hidden ?? !items.allSatisfy(\.isHidden)
        items.forEach { $0.isHidden = hide }
        if hide && !showHidden { selection.subtract(ids) }
        try? context.save()
    }

    private func menu(for ids: Set<UUID>) -> [FastMenuItem] {
        let items = purchases.flatMap { $0.items ?? [] }.filter { ids.contains($0.uuid) }
        let orders = Set(items.compactMap { $0.purchase?.uuid })
        var menu: [FastMenuItem] = [
            .button(business.map { "Business (\($0.name))" } ?? "Business", enabled: business != nil) { tag(ids, business: true) },
            .button("Personal") { tag(ids, business: false) },
            .button("Not Reviewed") { tag(ids, business: nil) },
            items.allSatisfy(\.isHidden)
                ? .button(items.count == 1 ? "Unhide Item" : "Unhide Items") { setHidden(ids, false) }
                : .button(items.count == 1 ? "Hide Item" : "Hide Items") { setHidden(ids, true) },
            .submenu("Tax Line", [TaxLine.Part.expenses, .cogs, .other].flatMap { part in
                TaxLine.allCases.filter { $0.part == part }.map { line in
                    FastMenuItem.button(line.label) {
                        items.forEach { $0.taxLine = line }
                        try? context.save()
                    }
                }
            }),
            .separator,
        ]
        if orders.count == 1, let p = items.first?.purchase {
            menu.append(.button("Show Charge", enabled: p.entryUUID != nil) { showCharge(p) })
            menu.append(.button(p.entryUUID == nil ? "Link to Charge…" : "Change Linked Charge…") { linking = p })
            if p.importKey == nil {
                menu.append(.button("Edit Purchase…") { editing = PurchaseEditRequest(purchase: p) })
            }
            if let url = p.webURL {
                menu.append(.button(p.webLabel) { NSWorkspace.shared.open(url) })
            }
            if items.count == 1, let url = items[0].productURL {
                menu.append(.button("View Item on Amazon") { NSWorkspace.shared.open(url) })
            }
        }
        return menu
    }

    /// Selects a just-saved purchase, widening the filter if it would be hidden.
    private func reveal(_ p: Purchase) {
        let ids = Set(p.sortedItems.map(\.uuid))
        if !filtered().contains(where: { ids.contains($0.id) }) { show = .all; period = .allDates }
        selection = ids
    }

    private func showCharge(_ p: Purchase) {
        guard let id = p.entryUUID,
              let e = try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.uuid == id })).first,
              let a = e.account else { return }
        open(e.persistentModelID, a.persistentModelID)
    }

    // MARK: Import

    private func chooseExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose the unzipped Amazon data folder (or its “Your Orders” folder)"
        if panel.runModal() == .OK, let url = panel.url { runImport(url) }
    }

    private func runImport(_ url: URL) {
        do {
            let export = try AmazonExport.read(url)
            guard !export.orders.isEmpty else {
                importMessage = "No Amazon orders were found there. Choose the folder that contains “Your Orders”."
                return
            }
            try? context.save()
            if FileManager.default.fileExists(atPath: Backup.storeURL.path) { try Backup.make(.beforeImport) }
            let r = try PurchaseImporter(context: context).importAmazon(export)
            show = .needsReview
            importMessage = PurchaseRules.describe(r)
        } catch {
            importMessage = error.localizedDescription
        }
    }
}

extension PurchasesView {
    static func columns(_ businesses: [Business]) -> [FastColumn<PurchaseRow>] {
        let names = Dictionary(businesses.map { ($0.uuid, $0.name) }, uniquingKeysWith: { a, _ in a })
        return [
            FastColumn("Date", width: 82, min: 70, monospaced: true) { Day.string($0.purchase.chargeDate) }
                .sorted(by: { $0.purchase.chargeDate }),
            FastColumn("Vendor", width: 90, min: 60) { $0.purchase.vendor } style: { _ in FastCellStyle(color: .secondaryLabelColor) }
                .sortedText { $0.purchase.vendor },
            FastColumn("Item", width: 320, min: 120) { $0.item.name } style: { r in
                FastCellStyle(color: r.item.isHidden ? .tertiaryLabelColor : nil, strikethrough: r.item.returned,
                              symbol: nil, tooltip: r.item.isHidden ? "Hidden · \(r.item.name)" : r.item.name)
            }
            .sortedText { $0.item.name },
            FastColumn("Department", width: 120, min: 60) { $0.item.department } style: { _ in FastCellStyle(color: .secondaryLabelColor) }
                .sortedText { $0.item.department },
            FastColumn("Amount", width: 85, min: 60, align: .right, monospaced: true) { Cents.string($0.item.amountCents) }
                .sorted(by: { $0.item.amountCents }),
            FastColumn("For", width: 120, min: 60) { r in
                switch r.item.tag {
                case .business: (r.item.businessUUID.flatMap { names[$0] } ?? "Business") + (r.item.businessPercent == 100 ? "" : " \(r.item.businessPercent)%")
                case .personal: "Personal"
                case .untagged: "—"
                }
            } style: { r in
                FastCellStyle(color: r.item.tag == .business ? nil : .secondaryLabelColor, bold: r.item.tag == .business)
            }
            .sortedText { r in r.item.tag == .business ? "a" : (r.item.tag == .personal ? "b" : "c") },
            FastColumn("Line", width: 60, min: 40) { r in r.item.tag == .business ? (r.item.taxLineRaw ?? "—") : "" } style: { r in
                FastCellStyle(color: r.item.tag == .business && r.item.taxLine == nil ? .systemOrange : .secondaryLabelColor,
                              tooltip: r.item.taxLine?.label)
            }
            .sortedText { $0.item.taxLineRaw ?? "" },
            FastColumn("", id: "files", width: 22, min: 18, max: 30, help: "Receipts and notes · click to show the receipt in Finder") { _ in "" } style: { r in
                let files = r.item.files ?? []
                guard !files.isEmpty || !r.item.notes.isEmpty else { return FastCellStyle() }
                var tip = files.map { "📎 \($0.name)" }
                if !r.item.notes.isEmpty { tip.append(r.item.notes) }
                return FastCellStyle(color: .secondaryLabelColor, symbol: files.isEmpty ? "note.text" : "paperclip",
                                     tooltip: tip.joined(separator: "\n"))
            }
            .sorted(by: { ($0.item.files ?? []).count * 2 + ($0.item.notes.isEmpty ? 0 : 1) }, descendingFirst: true)
            .onClick { r in
                if let f = (r.item.files ?? []).min(by: { $0.added < $1.added }) { _ = ReceiptFiles.reveal(f) }
            },
            FastColumn("Charge", id: "Linked", width: 34, min: 24, help: "Linked to a card or bank charge") { _ in "" } style: { r in
                FastCellStyle(color: r.purchase.entryUUID == nil ? .tertiaryLabelColor : .secondaryLabelColor,
                              symbol: r.purchase.entryUUID == nil ? (r.purchase.usedGiftCard ? "giftcard" : "") : "link",
                              tooltip: r.purchase.entryUUID == nil
                                ? (r.purchase.usedGiftCard ? "Paid partly with a gift card" : "Not linked to a charge")
                                : "Linked to the charge that paid for it")
            }
            .sorted(by: { $0.purchase.entryUUID == nil ? 0 : 1 }),
        ]
    }
}

struct PurchaseRow: Identifiable {
    let item: PurchaseItem
    let purchase: Purchase
    var id: UUID { item.uuid }
}

// MARK: - Detail panel

/// Details for the selected items: what they're for, the tax line, business %, purpose, and the
/// order they came in.
struct PurchaseDetail: View {
    @Environment(\.modelContext) private var context
    let items: [PurchaseItem]
    let business: Business?
    var open: (PersistentIdentifier, PersistentIdentifier) -> Void
    var link: (Purchase) -> Void

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("Select items", systemImage: "cart",
                                   description: Text("Press B to mark them business, P for personal."))
        } else {
            Form {
                tagging
                ReceiptFilesSection(items: items)
                if let p = singlePurchase { order(p) }
            }
            .formStyle(.grouped)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                ReceiptFiles.attach(files, to: items, context: context)
                return true
            }
        }
    }

    private var singlePurchase: Purchase? {
        let ps = Set(items.compactMap { $0.purchase?.uuid })
        return ps.count == 1 ? items.first?.purchase : nil
    }

    private var tagging: some View {
        Section(items.count == 1 ? items[0].shortName : "\(items.count) items") {
            Picker("For", selection: Binding(get: { common(\.tag) }, set: { t in
                guard let t else { return }
                change {
                    $0.businessUUID = t == .business ? business?.uuid : nil
                    $0.isPersonal = t == .personal
                    if t == .business && $0.taxLine == nil { $0.taxLine = PurchaseRules.suggestedLine(for: $0) }
                }
            })) {
                Text("Not reviewed").tag(PurchaseItem.Tag?.some(.untagged))
                Text(business?.name ?? "Business").tag(PurchaseItem.Tag?.some(.business))
                Text("Personal").tag(PurchaseItem.Tag?.some(.personal))
                if common(\.tag) == nil { Text("Mixed").tag(PurchaseItem.Tag?.none) }
            }
            if common(\.tag) == .business {
                Picker("Schedule C", selection: Binding(get: { common(\.taxLine) ?? nil }, set: { l in change { $0.taxLine = l } })) {
                    Text("Choose a line").tag(TaxLine?.none)
                    ForEach([TaxLine.Part.expenses, .cogs, .other], id: \.self) { part in
                        Section(part.rawValue) {
                            ForEach(TaxLine.allCases.filter { $0.part == part }) { Text($0.label).tag(TaxLine?.some($0)) }
                        }
                    }
                }
                Picker("Business use", selection: Binding(get: { common(\.businessPercent) ?? 100 }, set: { v in change { $0.businessPercent = v } })) {
                    ForEach([100, 90, 80, 75, 60, 50, 40, 25, 10], id: \.self) { Text("\($0)%").tag($0) }
                }
                TextField("Purpose", text: Binding(get: { common(\.purpose) ?? "" }, set: { v in change { $0.purpose = v } }),
                          prompt: Text("What it's for"), axis: .vertical)
            }
            Toggle("Returned", isOn: Binding(get: { common(\.returned) ?? false }, set: { v in change { $0.returned = v } }))
            Toggle("Hidden", isOn: Binding(get: { common(\.isHidden) ?? false }, set: { v in change { $0.isHidden = v } }))
                .help("Leave it out of the list and search (turn on Show hidden to see it)")
            TextField("Notes", text: Binding(get: { common(\.notes) ?? "" }, set: { v in change { $0.notes = v } }),
                      prompt: Text(items.count == 1 ? "About this item" : "Same note for all"), axis: .vertical)
            LabeledContent("Amount") { Text(Cents.string(items.reduce(0) { $0 + $1.amountCents })).monospacedDigit() }
        }
    }

    private func order(_ p: Purchase) -> some View {
        Section("Order") {
            LabeledContent("Vendor", value: p.vendor)
            if !p.orderNumber.isEmpty {
                LabeledContent("Order") { Text(p.orderNumber).textSelection(.enabled).monospacedDigit() }
            }
            LabeledContent("Ordered", value: Day.string(p.date))
            if let s = p.shipDate { LabeledContent("Shipped", value: Day.string(s)) }
            LabeledContent("Total") { Text(Cents.string(p.totalCents)).monospacedDigit() }
            if p.refundCents != 0 {
                LabeledContent("Refunded") { Text("\(Cents.string(p.refundCents)) on \(Day.string(p.refundDate))").monospacedDigit() }
            }
            if !p.cardLast4.isEmpty || p.usedGiftCard {
                LabeledContent("Paid with", value: [p.usedGiftCard ? "Gift card" : nil, p.cardLast4.isEmpty ? nil : "card ending \(p.cardLast4)"]
                    .compactMap { $0 }.joined(separator: " and "))
            }
            charge(p)
            TextField("Order notes", text: Binding(get: { p.notes }, set: { p.notes = $0; try? context.save() }), axis: .vertical)
            if !p.isAmazon {
                TextField("Link", text: Binding(get: { p.link }, set: { p.link = $0; try? context.save() }),
                          prompt: Text("Order or receipt web page"))
            }
            webButtons(p)
        }
    }

    @ViewBuilder private func charge(_ p: Purchase) -> some View {
        if let id = p.entryUUID, let e = try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.uuid == id })).first {
            LabeledContent("Charge") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Day.string(e.date)) · \(Cents.string(-e.amountCents))").monospacedDigit()
                    Text(e.account?.name ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Show Charge") { if let a = e.account { open(e.persistentModelID, a.persistentModelID) } }
                Button("Change…") { link(p) }
                Spacer()
            }
        } else {
            LabeledContent("Charge") {
                Button("Link to Charge…") { link(p) }
            }
        }
    }

    /// Opens the order (and, for one Amazon item, the product) in the default browser, where
    /// you're already signed in.
    @ViewBuilder private func webButtons(_ p: Purchase) -> some View {
        let product = items.count == 1 ? items[0].productURL : nil
        if p.webURL != nil || product != nil {
            HStack {
                if let url = p.webURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label(p.webLabel, systemImage: "safari") }
                        .help(url.absoluteString)
                }
                if let product {
                    Button { NSWorkspace.shared.open(product) } label: { Label("View Item", systemImage: "arrow.up.right.square") }
                        .help("The product's page on Amazon")
                }
                Spacer()
            }
        }
    }

    /// The value all selected items share, or nil when they differ.
    private func common<T: Equatable>(_ key: KeyPath<PurchaseItem, T>) -> T? {
        guard let first = items.first?[keyPath: key] else { return nil }
        return items.allSatisfy { $0[keyPath: key] == first } ? first : nil
    }

    private func change(_ apply: (PurchaseItem) -> Void) {
        items.forEach(apply)
        try? context.save()
    }
}

// MARK: - Linking by hand

/// Pick the charge that paid for a purchase: nearby charges, closest amount first.
struct LinkChargeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let purchase: Purchase
    @State private var candidates: [Entry] = []
    @State private var choice: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link to Charge").font(.title2.bold())
            Text("\(purchase.vendor) \(purchase.orderNumber) · \(Day.string(purchase.chargeDate)) · \(Cents.string(purchase.totalCents))")
                .foregroundStyle(.secondary)
            List(candidates, id: \.uuid, selection: $choice) { e in
                HStack {
                    Text(Day.string(e.date)).monospacedDigit().frame(width: 80, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text(e.payee?.name ?? "")
                        Text(e.account?.name ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Cents.string(-e.amountCents)).monospacedDigit()
                        .foregroundStyle(-e.amountCents == purchase.totalCents ? .green : .primary)
                }
                .tag(e.uuid)
            }
            .frame(minHeight: 260)
            HStack {
                if purchase.entryUUID != nil {
                    Button("Unlink") { purchase.entryUUID = nil; try? context.save(); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link") { purchase.entryUUID = choice; try? context.save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(choice == nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .onAppear {
            candidates = PurchaseImporter(context: context).chargeCandidates(for: purchase)
            choice = purchase.entryUUID
        }
    }
}

// MARK: - Helpers

enum PurchaseRules {
    /// A starting Schedule C line from the department and price. Equipment of $2,500 or more is
    /// flagged as an asset (above the de minimis safe harbor) for the accountant to depreciate.
    static func suggestedLine(for item: PurchaseItem) -> TaxLine {
        if item.amountCents >= 250_000 { return .capitalPurchase }
        let d = item.department.lowercased()
        if d.contains("office") || d.contains("software") || d.contains("digital") || d.contains("book") { return .office }
        return .supplies
    }

    static func describe(_ r: PurchaseImporter.Result) -> String {
        var parts = ["\(r.added) new purchases", "\(r.itemsAdded) items"]
        if r.unchanged > 0 { parts.append("\(r.unchanged) already here") }
        if r.refunds > 0 { parts.append("\(r.refunds) refunds") }
        parts.append("\(r.linked) linked to card charges")
        return parts.joined(separator: " · ") + "."
    }

}

extension PurchaseRules {
    /// "Amazon order 111-…: 3 items, $42.10 business" for a register row's tooltip.
    static func registerTip(_ p: Purchase) -> String {
        var lines = ["\(p.vendor)\(p.orderNumber.isEmpty ? "" : " order \(p.orderNumber)")"]
        lines += p.sortedItems.prefix(8).map { i in
            let tag = i.tag == .business ? " · business" : (i.tag == .personal ? " · personal" : "")
            return "• \(i.shortName)  \(Cents.string(i.amountCents))\(tag)"
        }
        if p.sortedItems.count > 8 { lines.append("…and \(p.sortedItems.count - 8) more") }
        if p.businessCents > 0 { lines.append("Business: \(Cents.string(p.businessCents))") }
        lines.append("Right-click ▸ Show Purchase")
        return lines.joined(separator: "\n")
    }
}
