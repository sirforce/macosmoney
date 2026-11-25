import Foundation

/// Sample-data mode, for trying the app and for taking screenshots without showing anyone's
/// real finances. Launch with `--demo`:
///
///     open MacMoney.app --args --demo
///
/// The demo has its own data folder (`~/Library/Application Support/MacMoney Demo/`, or
/// `MACMONEY_DEMO_DIR`), so the real data file is never opened, backed up or restored over.
/// `--demo-reset` starts over with fresh sample data; `--demo-empty` starts with no data at all
/// (the Welcome screen).
enum DemoMode {
    private static let arguments = Set(CommandLine.arguments.dropFirst())

    static let startsEmpty = arguments.contains("--demo-empty")
    static let isOn = arguments.contains("--demo") || startsEmpty || arguments.contains("--demo-reset")
        || arguments.contains { $0.hasPrefix("--demo-tour=") }
    static var resets: Bool { arguments.contains("--demo-reset") || startsEmpty }

    private static let realFolder = URL.applicationSupportDirectory.appendingPathComponent("MacMoney", isDirectory: true)

    static let dataFolder: URL = {
        let standard = URL.applicationSupportDirectory.appendingPathComponent("MacMoney Demo", isDirectory: true)
        guard let p = ProcessInfo.processInfo.environment["MACMONEY_DEMO_DIR"], !p.isEmpty else { return standard }
        let custom = URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL
        // Never let the demo point at the real data folder.
        return custom.path == realFolder.standardizedFileURL.path ? standard : custom
    }()

    /// Bank and card downloads written with the sample data, for trying Import Bank Files.
    static var downloadsFolder: URL { dataFolder.appendingPathComponent("Sample Downloads", isDirectory: true) }

    /// Called before the store is opened.
    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        guard resets else { return }
        for name in ["MacMoney.store", "MacMoney.store-shm", "MacMoney.store-wal", "Sample Downloads", "Backups"] {
            try? fm.removeItem(at: dataFolder.appendingPathComponent(name))
        }
    }
}
