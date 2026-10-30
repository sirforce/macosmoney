import SwiftUI
import SwiftData

enum SidebarItem: Hashable {
    case account(PersistentIdentifier)
    case payees
    case depositSources
    case bills
    case forecast
    case find
    case business(PersistentIdentifier)
    case allBusinesses
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var selection: SidebarItem?
    @State private var showImport = false
    @State private var showBackups = false
    @State private var showDataCheck = false
    @State private var restoreResult: String?
    @State private var showClosed = false
    @State private var focusEntry: PersistentIdentifier?
    @Query(sort: \Business.name) private var businesses: [Business]
    @State private var editingAccount: Account?
    @State private var showNewAccount = false
    @State private var deletingAccount: Account?
    @State private var showNewBusiness = false

    private var openAccounts: [Account] { accounts.filter { !$0.isClosed } }
    private var closedAccounts: [Account] { accounts.filter { $0.isClosed } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Accounts") {
                    ForEach(openAccounts) { accountRow($0) }
                }
                if !closedAccounts.isEmpty {
                    Section(isExpanded: $showClosed) {
                        ForEach(closedAccounts) { accountRow($0) }
                    } header: {
                        Text("Closed Accounts")
                    }
                }
                Section("Lists") {
                    Label("Find Transactions", systemImage: "magnifyingglass").tag(SidebarItem.find)
                    Label("Payees", systemImage: "person.2").tag(SidebarItem.payees)
                    Label("Deposit Sources", systemImage: "arrow.down.circle").tag(SidebarItem.depositSources)
                    Label("Bills & Deposits", systemImage: "calendar.badge.clock").tag(SidebarItem.bills)
                }
                Section("Planning") {
                    Label("Forecast", systemImage: "chart.xyaxis.line").tag(SidebarItem.forecast)
                }
                Section("Business") {
                    ForEach(businesses) { b in
                        Label(b.name, systemImage: "briefcase").tag(SidebarItem.business(b.persistentModelID))
                    }
                    if businesses.count > 1 {
                        Label("All Businesses", systemImage: "briefcase.circle").tag(SidebarItem.allBusinesses)
                    }
                    Button { showNewBusiness = true } label: { Label("Add Business…", systemImage: "plus") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button { showNewAccount = true } label: { Label("New Account", systemImage: "plus") }
                        .help("Add an account")
                }
                ToolbarItem {
                    Button { showImport = true } label: { Label("Import from Money", systemImage: "square.and.arrow.down") }
                        .help("Import or re-import a Microsoft Money .mny file")
                }
            }
        } detail: {
            detail
        }
        .sheet(isPresented: $showImport) { ImportView() }
        .sheet(isPresented: $showBackups) { BackupsView() }
        .sheet(isPresented: $showDataCheck) { DataCheckView() }
        .sheet(isPresented: $showNewAccount) {
            AccountEditor(account: nil) { selection = .account($0.persistentModelID) }
        }
        .sheet(item: $editingAccount) { AccountEditor(account: $0) }
        .sheet(isPresented: $showNewBusiness) {
            BusinessEditor(business: nil) { selection = .business($0.persistentModelID) }
        }
        .confirmationDialog("Delete account?", isPresented: Binding(get: { deletingAccount != nil }, set: { if !$0 { deletingAccount = nil } }),
                            presenting: deletingAccount) { a in
            Button("Delete \(a.name) and its \((a.entries ?? []).count) transactions", role: .destructive) {
                if case .account(let id) = selection, id == a.persistentModelID { selection = nil }
                context.delete(a)
                try? context.save()
            }
        } message: { a in
            Text(a.moneyId != nil
                 ? "This account came from Money and will come back on the next re-import. Consider closing it instead."
                 : "This can't be undone. Closing the account keeps its history instead.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showMoneyImport)) { _ in showImport = true }
        .onReceive(NotificationCenter.default.publisher(for: .showFind)) { _ in selection = .find }
        .onReceive(NotificationCenter.default.publisher(for: .showBackups)) { _ in showBackups = true }
        .onReceive(NotificationCenter.default.publisher(for: .showDataCheck)) { _ in showDataCheck = true }
        .alert("Restore", isPresented: Binding(get: { restoreResult != nil }, set: { if !$0 { restoreResult = nil } })) {
            Button("OK") {}
        } message: { Text(restoreResult ?? "") }
        .task {
            if let msg = UserDefaults.standard.string(forKey: Backup.Key.lastRestoreResult) {
                UserDefaults.standard.removeObject(forKey: Backup.Key.lastRestoreResult)
                restoreResult = msg
            }
        }
        .onAppear {
            if selection == nil, let first = openAccounts.first { selection = .account(first.persistentModelID) }
        }
    }

    private func accountRow(_ a: Account) -> some View {
        AccountRow(account: a)
            .tag(SidebarItem.account(a.persistentModelID))
            .contextMenu {
                Button("Edit Account…") { editingAccount = a }
                Button(a.isClosed ? "Reopen Account" : "Close Account") {
                    a.isClosed.toggle()
                    try? context.save()
                }
                Divider()
                Button("Delete Account…", role: .destructive) { deletingAccount = a }
            }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .account(let id):
            if let account = accounts.first(where: { $0.persistentModelID == id }) {
                RegisterView(account: account, focusEntry: $focusEntry).id(id)
            }
        case .payees:
            PayeesView().id("payees")
        case .depositSources:
            PayeesView(mode: .depositSources).id("deposits")
        case .bills:
            BillsView()
        case .forecast:
            ForecastView { entryID, accountID in
                focusEntry = entryID
                selection = .account(accountID)
            }
        case .find:
            FindView { entryID, accountID in
                focusEntry = entryID
                selection = .account(accountID)
            }
        case .business(let id):
            if let b = businesses.first(where: { $0.persistentModelID == id }) {
                BusinessView(business: b).id(id)
            }
        case .allBusinesses:
            AllBusinessesView()
        case nil:
            if accounts.isEmpty {
                ContentUnavailableView {
                    Label("No data yet", systemImage: "banknote")
                } description: {
                    Text("Import your Microsoft Money file to bring in all of your history.")
                } actions: {
                    Button("Import from Money…") { showImport = true }.buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("Select an account", systemImage: "building.columns")
            }
        }
    }
}

struct AccountRow: View {
    @Environment(LedgerIndex.self) private var index
    let account: Account

    private var balance: Int { index.totals[account.persistentModelID]?.current ?? account.openingBalanceCents }

    var body: some View {
        HStack {
            Label(account.name, systemImage: icon)
            if let b = account.business {
                Image(systemName: "briefcase.fill").font(.caption2).foregroundStyle(.secondary).help("Business account: \(b.name)")
            }
            Spacer()
            Text(Cents.string(balance))
                .monospacedDigit()
                .foregroundStyle(balance < 0 ? .red : .secondary)
                .font(.callout)
        }
    }

    private var icon: String {
        switch account.kind {
        case .bank: "building.columns"
        case .creditCard: "creditcard"
        case .loan: "doc.text"
        case .investment: "chart.line.uptrend.xyaxis"
        case .other: "folder"
        }
    }
}

extension Account {
    /// Balance including everything entered, future-dated entries too (Money's "Ending Balance").
    var currentBalanceCents: Int {
        openingBalanceCents + (entries ?? []).reduce(0) { $0 + $1.balanceEffectCents }
    }

    /// Balance as of a given day (inclusive).
    func balance(asOf day: Date) -> Int {
        openingBalanceCents + (entries ?? []).filter { $0.date <= day }.reduce(0) { $0 + $1.balanceEffectCents }
    }
}
