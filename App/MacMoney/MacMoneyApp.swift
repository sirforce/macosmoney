import SwiftUI
import SwiftData

@main
struct MacMoneyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer
    @State private var index = LedgerIndex()

    init() {
        Backup.registerDefaults()
        Backup.applyPendingRestore()   // must happen before the store is opened
        container = Self.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(index)
                .task {
                    _ = AppSettings.current(in: container.mainContext)   // makes it, moving old preferences in
                    index.start(container.mainContext)
                }
        }
        .modelContainer(container)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Backups…") { NotificationCenter.default.post(name: .showBackups, object: nil) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Check Data File…") { NotificationCenter.default.post(name: .showDataCheck, object: nil) }
            }
            CommandGroup(after: .importExport) {
                Button("Import from Microsoft Money…") {
                    NotificationCenter.default.post(name: .showMoneyImport, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Import Bank Files…") {
                    NotificationCenter.default.post(name: .showBankImport, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find Transactions…") {
                    NotificationCenter.default.post(name: .showFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("Account") {
                Button("Balance Account…") { NotificationCenter.default.post(name: .balanceAccount, object: nil) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Set Balance…") { NotificationCenter.default.post(name: .setBalance, object: nil) }
            }
        }

        Settings { SettingsView() }
    }

    /// The store lives in ~/Library/Application Support/MacMoney/. It is a standard SQLite file.
    static func makeContainer() -> ModelContainer {
        let dir = URL.applicationSupportDirectory.appendingPathComponent("MacMoney", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ModelConfiguration("MacMoney", schema: Schema(Schema1.models),
                                        url: dir.appendingPathComponent("MacMoney.store"),
                                        cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: Schema(Schema1.models), configurations: config)
        } catch {
            fatalError("Could not open data store: \(error)")
        }
    }
}

extension Notification.Name {
    static let showMoneyImport = Notification.Name("showMoneyImport")
    static let showBankImport = Notification.Name("showBankImport")
    static let showFind = Notification.Name("showFind")
    static let showBackups = Notification.Name("showBackups")
    static let showDataCheck = Notification.Name("showDataCheck")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Money-style "back up on exit". SwiftData saves are already on disk, so a snapshot here is complete.
    func applicationWillTerminate(_ notification: Notification) {
        Backup.makeAutomaticIfDue()
    }
}
