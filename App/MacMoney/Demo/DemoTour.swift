import SwiftUI
import SwiftData
import ScreenCaptureKit

/// One stop on the screenshot tour: where to go and what to have open.
struct DemoScene {
    var name = ""
    var account: String?
    /// "payees", "depositSources", "bills", "forecast", "find", "purchases", "allBusinesses".
    var page: String?
    var business: String?
    /// "bankImport", "backups", "dataCheck", "balance".
    var sheet: String?
    /// Selects this payee's newest transaction in the register.
    var focusPayee: String?
    /// Opens Purchases on this vendor's newest purchase.
    var purchaseVendor: String?
    /// Initial state for the views that read `DemoTour.preset` ("business.tab", "find.query"…).
    var presets: [String: String] = [:]
    /// Layout preferences set before the scene appears ("forecast.months": 12).
    var defaults: [String: Any] = [:]
}

extension Notification.Name {
    static let demoScene = Notification.Name("demoScene")
}

/// Takes the documentation screenshots: `--demo --demo-tour=<folder>` walks through the app's
/// screens with the sample data and saves a PNG of each. Only this app's own window is captured
/// (through ScreenCaptureKit's current-process content), so nothing else on the screen can end up
/// in a picture. See docs/demo-and-screenshots.md.
@MainActor
enum DemoTour {
    static let folder: URL? = {
        // One argument ("--demo-tour=/path"): AppKit would take a separate path for a document to open.
        let prefix = "--demo-tour="
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return URL(fileURLWithPath: String(arg.dropFirst(prefix.count)), isDirectory: true)
    }()

    static var isOn: Bool { DemoMode.isOn && folder != nil }

    private static var presets: [String: String] = [:]

    /// A value the current scene wants a view to start with. Always nil outside the tour.
    static func preset(_ key: String) -> String? { presets[key] }

    static let scenes: [DemoScene] = [
        DemoScene(name: "register-checking", account: "Joint Checking", focusPayee: "Cascade Power & Light"),
        DemoScene(name: "register-credit-card", account: "Rewards Visa", focusPayee: "Paws & Claws Vet"),
        DemoScene(name: "register-auto-loan", account: "Auto Loan", presets: ["register.filter": RegisterFilter.last12Months.rawValue]),
        DemoScene(name: "balance-account", account: "Joint Checking", sheet: "balance", presets: ["balance.marking": "1"]),
        DemoScene(name: "bank-import", account: "Rewards Visa", sheet: "bankImport"),
        DemoScene(name: "bank-import-history", account: "Rewards Visa", sheet: "bankImport", presets: ["bankImport.tab": "history"]),
        DemoScene(name: "purchases-review", page: "purchases", defaults: ["purchases.show": "Needs review"]),
        DemoScene(name: "purchases-itemized", page: "purchases", purchaseVendor: "Keystone Camera & Video"),
        DemoScene(name: "find-transactions", page: "find", presets: ["find.query": "evergreen"]),
        DemoScene(name: "payees-overview", page: "payees"),
        DemoScene(name: "payees-report", page: "payees", presets: ["payees.preset": "Utilities"]),
        DemoScene(name: "deposit-sources", page: "depositSources", presets: ["payees.preset": "Studio clients"]),
        DemoScene(name: "bills-and-deposits", page: "bills", presets: ["bills.select": "Cascade Auto Finance"]),
        DemoScene(name: "forecast", page: "forecast", defaults: ["forecast.months": 12, "forecast.account": "all", "forecast.scenario": ""]),
        DemoScene(name: "forecast-what-if", page: "forecast", presets: ["forecast.scenarioName": "New roof in the spring"],
                  defaults: ["forecast.months": 12, "forecast.account": "all"]),
        DemoScene(name: "scenarios", page: "forecast", presets: ["forecast.scenarioName": "Lose the retainer client", "forecast.showScenarios": "1"]),
        DemoScene(name: "schedule-c", business: "Juniper Lane Studio", presets: ["business.tab": "Schedule C", "business.lastYear": "1"]),
        DemoScene(name: "profit-and-loss", business: "Juniper Lane Studio", presets: ["business.tab": "Profit & Loss", "business.lastYear": "1"]),
        DemoScene(name: "tag-transactions", business: "Tidepool Prints", presets: ["business.tab": "Tag Transactions"]),
        DemoScene(name: "vehicles-and-mileage", business: "Juniper Lane Studio", presets: ["business.tab": "Vehicles & Mileage"]),
        DemoScene(name: "assets", business: "Juniper Lane Studio", presets: ["business.tab": "Assets", "business.lastYear": "1"]),
        DemoScene(name: "tax-line-setup", business: "Juniper Lane Studio", presets: ["business.tab": "Tax Line Setup"]),
        DemoScene(name: "all-businesses", page: "allBusinesses", presets: ["business.lastYear": "1"]),
        DemoScene(name: "backups", account: "Joint Checking", sheet: "backups"),
        DemoScene(name: "check-data-file", account: "Joint Checking", sheet: "dataCheck"),
    ]

    static func run(context: ModelContext) async {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let listed = ProcessInfo.processInfo.environment["MACMONEY_TOUR_ONLY"]?.split(separator: ",").map(String.init) ?? []
        let only = listed.isEmpty ? nil : listed
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
        window.setFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        NSApp.activate()
        try? await Task.sleep(for: .seconds(1))

        var report: [String] = []
        let empty = ((try? context.fetchCount(FetchDescriptor<Account>())) ?? 0) == 0
        if empty {
            report.append(await capture(window, to: folder, name: "welcome"))
        } else {
            _ = try? Backup.make(.manual)
            for scene in scenes where only?.contains(scene.name) ?? true {
                presets = [:]
                NotificationCenter.default.post(name: .demoScene, object: DemoScene())
                try? await Task.sleep(for: .milliseconds(400))
                presets = scene.presets
                for (key, value) in scene.defaults { UserDefaults.standard.set(value, forKey: key) }
                NotificationCenter.default.post(name: .demoScene, object: scene)
                try? await Task.sleep(for: .milliseconds(scene.sheet == nil ? 1500 : 2300))
                // In front for the picture, so the window is drawn as the active one.
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(400))
                report.append(await capture(window, to: folder, name: scene.name))
                for sheet in window.sheets { window.endSheet(sheet) }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        try? report.joined(separator: "\n").appending("\n").write(to: folder.appendingPathComponent("tour.log"), atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Saves a picture of the window and anything attached to it (sheets, popovers).
    private static func capture(_ window: NSWindow, to folder: URL, name: String) async -> String {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                return "\(name): window not found"
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.includeChildWindows = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { return "\(name): could not encode" }
            try png.write(to: folder.appendingPathComponent("\(name).png"))
            return "\(name): ok \(image.width)x\(image.height)"
        } catch {
            return "\(name): \(error.localizedDescription)"
        }
    }
}
