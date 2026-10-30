import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// File ▸ Import Bank Files…: drop downloads (or a whole folder), check where each goes and what's
/// new, then import. Re-importing anything is harmless — rows already in MacMoney are skipped.
struct BankImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \BankImportBatch.date, order: .reverse) private var batches: [BankImportBatch]

    /// Files handed over by a drop on the main window.
    var initialURLs: [URL] = []

    private enum Tab: String, CaseIterable { case importFiles = "Import", history = "History" }
    @State private var tab: Tab = .importFiles
    @State private var items: [Item] = []
    @State private var targets: [UUID: String] = [:]          // item id → target key
    @State private var checks: [String: Check] = [:]          // target key → balance check
    @State private var plans: [UUID: BankImporter.FilePlan] = [:]
    @State private var results: [BankImportBatch]?
    @State private var error: String?
    @State private var undoing: BankImportBatch?
    @State private var dropping = false

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var statement: BankStatement?
        var failure: String?
        var folder: String { url.deletingLastPathComponent().lastPathComponent }
    }

    struct Check {
        var on = false
        var date = Day.today
        var amount = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Import Bank Files", systemImage: "tray.and.arrow.down").font(.title2.bold())
                Spacer()
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding()
            Divider()
            switch tab {
            case .importFiles:
                if let results { resultsView(results) } else if items.isEmpty { dropZone } else { review }
            case .history: history
            }
        }
        .frame(width: 920, height: 640)
        .onAppear { if !initialURLs.isEmpty { add(initialURLs) } }
        .confirmationDialog("Undo this import?", isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } }),
                            presenting: undoing) { b in
            Button("Undo Import", role: .destructive) { undo(b) }
        } message: { b in
            Text("Removes the \(b.added) transactions it added to \(b.accountName), including any business details you've added to them since. Matched transactions are kept. A backup is made first.")
        }
    }

    // MARK: Choosing files

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Drop bank downloads or a folder of them here").font(.title3)
            Text("CSV, Excel (.xlsx), OFX/QFX, and Discover's .xls download. Bank of America, Chase, American Express, Discover and most other banks.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button("Choose Files or Folder…") { choose() }.buttonStyle(.borderedProminent)
            Text("Importing the same file twice, or files that overlap, never adds a transaction twice.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.4)).padding(24))
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { dropping = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose bank downloads, or a folder that contains them"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                files += (e?.compactMap { $0 as? URL } ?? []).filter { !$0.hasDirectoryPath }
            } else {
                files.append(url)
            }
        }
        let known = Set(items.map(\.url))
        for url in files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) where !known.contains(url) {
            var item = Item(url: url)
            do { item.statement = try BankFormats.read(url) } catch { item.failure = error.localizedDescription }
            items.append(item)
            if let s = item.statement { targets[item.id] = defaultTarget(for: s, folder: item.folder) }
        }
        prefillChecks()
        replan()
    }

    // MARK: Targets

    private func defaultTarget(for s: BankStatement, folder: String) -> String {
        // Files from the same folder as one already assigned go to the same place.
        if let sibling = items.first(where: { $0.folder == folder && targets[$0.id] != nil }), let t = targets[sibling.id] { return t }
        if let a = BankImporter.suggestedAccount(for: s, in: accounts) { return "acct:\(a.uuid)" }
        return "new:\(folder)"
    }

    private func account(for key: String) -> Account? {
        guard key.hasPrefix("acct:") else { return nil }
        return accounts.first { "acct:\($0.uuid)" == key }
    }

    private func isOwed(_ key: String) -> Bool {
        if let a = account(for: key) { return a.kind == .creditCard || a.kind == .loan }
        return items.first { targets[$0.id] == key }?.statement?.isCard ?? false
    }

    private func label(for key: String) -> String {
        if let a = account(for: key) { return a.name }
        if key.hasPrefix("new:") { return "New account “\(key.dropFirst(4))”" }
        return "Don't import"
    }

    /// Distinct targets in use, in file order.
    private var targetKeys: [String] {
        var seen = Set<String>(), out: [String] = []
        for i in items { if let t = targets[i.id], t != "skip", seen.insert(t).inserted { out.append(t) } }
        return out
    }

    /// Discover's download carries the balance; use it.
    private func prefillChecks() {
        for key in targetKeys where checks[key] == nil {
            var c = Check()
            let files = items.filter { targets[$0.id] == key }.compactMap(\.statement)
            if let latest = files.compactMap(\.latestBalance).max(by: { $0.date < $1.date }) {
                c.on = true
                c.date = latest.date
                c.amount = Cents.plain(latest.cents).replacingOccurrences(of: ",", with: "")
            } else if let last = files.compactMap(\.dateRange?.upperBound).max() {
                c.date = last
            }
            checks[key] = c
        }
    }

    private func replan() {
        var out: [UUID: BankImporter.FilePlan] = [:]
        let importer = BankImporter(context: context)
        for key in targetKeys {
            let group = items.filter { targets[$0.id] == key && $0.statement != nil }
            let p = importer.plan(group.map { (url: $0.url, statement: $0.statement!) }, into: account(for: key))
            for (item, plan) in zip(group, p) { out[item.id] = plan }
        }
        plans = out
    }

    // MARK: Review

    private var review: some View {
        let totalNew = plans.values.reduce(0) { $0 + $1.newRows.count }
        let totalMatched = plans.values.reduce(0) { $0 + $1.matches.count }
        return VStack(spacing: 0) {
            List {
                Section("Files") {
                    ForEach(items) { item in fileRow(item) }
                }
                if !targetKeys.isEmpty {
                    Section {
                        ForEach(targetKeys, id: \.self) { key in checkRow(key) }
                    } header: {
                        Text("Balance check (optional)")
                    } footer: {
                        Text("Enter the balance from a statement and MacMoney adds one correction so the account matches the bank from then on. For a new account it sets the opening balance instead.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
            Divider()
            HStack {
                Button("Add Files…") { choose() }
                Button("Clear") { items = []; targets = [:]; checks = [:]; plans = [:] }
                if let error { Text(error).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(totalNew + totalMatched == 0 ? "Nothing New to Import" : "Import \(totalNew) New Transactions") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(totalNew + totalMatched == 0)
            }
            .padding()
        }
    }

    private func fileRow(_ item: Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.failure == nil ? "doc.text" : "exclamationmark.triangle")
                .foregroundStyle(item.failure == nil ? Color.secondary : Color.orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if let s = item.statement {
                    let range = s.dateRange.map { "\(Day.string($0.lowerBound)) – \(Day.string($0.upperBound))" } ?? ""
                    Text("\(item.folder) · \(s.format.rawValue) · \(s.rows.count) rows · \(range)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(item.failure ?? "").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let p = plans[item.id] { counts(p) }
            if item.statement != nil {
                Picker("", selection: Binding(get: { targets[item.id] ?? "skip" }, set: { new in
                    // Move the whole folder together; it's almost always one account.
                    for other in items where other.folder == item.folder && other.statement != nil { targets[other.id] = new }
                    prefillChecks()
                    replan()
                })) {
                    let openAccounts = accounts.filter { !$0.isClosed }, closed = accounts.filter(\.isClosed)
                    ForEach(openAccounts) { Text($0.name).tag("acct:\($0.uuid)") }
                    if !closed.isEmpty {
                        Divider()
                        ForEach(closed) { Text("\($0.name) (closed — reopen)").tag("acct:\($0.uuid)") }
                    }
                    Divider()
                    Text("New account “\(item.folder)”").tag("new:\(item.folder)")
                    Text("Don't import").tag("skip")
                }
                .labelsHidden()
                .frame(width: 250)
            }
        }
        .padding(.vertical, 2)
    }

    private func counts(_ p: BankImporter.FilePlan) -> some View {
        HStack(spacing: 10) {
            Text("\(p.newRows.count) new").foregroundStyle(p.newRows.isEmpty ? Color.secondary : Color.green)
            if !p.matches.isEmpty {
                Text("\(p.matches.count) matched").foregroundStyle(.blue)
                    .help("Already in the account (for example a payment entered in checking); linked instead of added")
            }
            if p.duplicates > 0 {
                Text("\(p.duplicates) already imported").foregroundStyle(.secondary)
            }
        }
        .font(.caption).monospacedDigit()
    }

    private func checkRow(_ key: String) -> some View {
        let owed = isOwed(key)
        let c = Binding(get: { checks[key] ?? Check() }, set: { checks[key] = $0 })
        return HStack(spacing: 12) {
            Toggle(label(for: key), isOn: c.on).frame(width: 300, alignment: .leading)
            if c.wrappedValue.on {
                DatePicker("on", selection: Binding(get: { Day.toLocal(c.wrappedValue.date) }, set: { c.wrappedValue.date = Day.normalize($0) }),
                           displayedComponents: .date)
                    .frame(width: 170)
                TextField(owed ? "Balance owed" : "Balance", text: c.amount, prompt: Text(owed ? "Amount owed" : "Balance"))
                    .frame(width: 140).monospacedDigit()
                if owed { Text("owed").foregroundStyle(.secondary) }
            }
            Spacer()
        }
    }

    // MARK: Import

    private func runImport() {
        error = nil
        do {
            try? context.save()
            if FileManager.default.fileExists(atPath: Backup.storeURL.path) { try Backup.make(.beforeImport) }
            let importer = BankImporter(context: context)
            var done: [BankImportBatch] = []
            for key in targetKeys {
                let group = items.filter { targets[$0.id] == key && $0.statement != nil }
                let account: Account
                if let a = self.account(for: key) {
                    account = a
                } else {
                    let s = group.first!.statement!
                    account = Account(name: String(key.dropFirst(4)), kind: s.isCard ? .creditCard : .bank)
                    account.openDate = group.compactMap(\.statement?.dateRange?.lowerBound).min()
                    context.insert(account)
                }
                var balance: BankImporter.BalanceCheck?
                if let c = checks[key], c.on {
                    guard let cents = Cents.parse(c.amount) else { error = "Enter the balance for \(label(for: key))."; return }
                    balance = .init(date: c.date, cents: isOwed(key) ? -abs(cents) : cents)
                }
                let plans = importer.plan(group.map { (url: $0.url, statement: $0.statement!) }, into: account)
                done.append(try importer.apply(plans, to: account, balance: balance))
            }
            results = done
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func resultsView(_ batches: [BankImportBatch]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Imported", systemImage: "checkmark.circle.fill").font(.title2.bold()).foregroundStyle(.green)
            ForEach(batches) { b in
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.accountName).font(.headline)
                    Text(summary(b)).foregroundStyle(.secondary)
                }
            }
            Text("Imported transactions are marked cleared. Anything you change on them — category, business, notes — is kept when you import again.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Import More…") { results = nil; items = []; targets = [:]; checks = [:]; plans = [:] }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func summary(_ b: BankImportBatch) -> String {
        var parts = ["\(b.added) added"]
        if b.matched > 0 { parts.append("\(b.matched) matched to existing") }
        if b.skipped > 0 { parts.append("\(b.skipped) already imported") }
        if b.correctionEntryUUID != nil { parts.append("balance correction added") }
        if b.openingChangeCents != 0 { parts.append("opening balance set") }
        if b.reopenedAccount { parts.append("account reopened") }
        if let f = b.firstDate, let l = b.lastDate { parts.append("\(Day.string(f)) – \(Day.string(l))") }
        return parts.joined(separator: " · ")
    }

    // MARK: History

    private var history: some View {
        Group {
            if batches.isEmpty {
                ContentUnavailableView("No bank imports yet", systemImage: "clock", description: Text("Each import is listed here and can be undone."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(batches) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(b.accountName) — \(b.date.formatted(date: .abbreviated, time: .shortened))")
                            Text(summary(b)).font(.caption).foregroundStyle(.secondary)
                            Text(b.fileNames.replacingOccurrences(of: "\n", with: ", ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Button("Undo…") { undoing = b }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private func undo(_ b: BankImportBatch) {
        do {
            try? context.save()
            try Backup.make(.beforeImport)
            try BankImporter(context: context).undo(b)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
