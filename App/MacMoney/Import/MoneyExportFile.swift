import Foundation

/// The JSON produced by tools/mny-export (format "macmoney-export", version 1).
struct MoneyExportFile: Decodable {
    struct Source: Decodable {
        var fileName: String
        var fileSize: Int
        var modified: String
        var sha256: String
    }

    struct Account: Decodable {
        var moneyId: Int
        var name: String?
        var kind: String
        var closed: Bool
        var openingBalance: String?
        var openDate: String?
        var lastReconciledDate: String?
        var lastReconciledBalance: String?
        var accountNumber: String?
        var comment: String?
        var isBusiness: Bool
    }

    struct Category: Decodable {
        var moneyId: Int
        var parentId: Int?
        var name: String?
        var level: Int?
        var kind: String
        var isTaxRelated: Bool
        var isBusiness: Bool
        var hidden: Bool
        var comment: String?
    }

    struct Payee: Decodable {
        var moneyId: Int
        var parentId: Int?
        var name: String?
        var hidden: Bool
        var accountNumber: String?
        var website: String?
        var comment: String?
    }

    struct Transaction: Decodable {
        var moneyId: Int
        var accountId: Int?
        var date: String
        var amount: String?
        var number: String?
        var payeeId: Int?
        var categoryId: Int?
        var memo: String?
        var status: String
        var dateCleared: String?
        var isVoid: Bool
        var flagged: Bool?
        var flagNote: String?
        var flagDate: String?
        var splitParentId: Int?
        var splitOrder: Int?
        var isSplitParent: Bool
        var transferPeerId: Int?
        var transferAccountId: Int?
        var billSeriesId: Int?
        var billOccurrence: Int?
    }

    struct Frequency: Decodable {
        var unit: String
        var every: Int
    }

    struct Split: Decodable {
        var categoryId: Int?
        var amount: String?
        var memo: String?
    }

    struct Bill: Decodable {
        var seriesId: Int
        var accountId: Int?
        var payeeId: Int?
        var categoryId: Int?
        var amount: String?
        var memo: String?
        var number: String?
        var transferAccountId: Int?
        var frequency: Frequency
        var startDate: String?
        var nextDue: String
        var nextOccurrence: Int
        var maxOccurrences: Int?
        var endDate: String?
        var moneyStatus: Int?
        var finished: Bool
        var splits: [Split]
    }

    var format: String
    var version: Int
    var source: Source
    var accounts: [Account]
    var categories: [Category]
    var payees: [Payee]
    var transactions: [Transaction]
    var bills: [Bill]
}

enum MoneyExportRunner {
    enum Failure: LocalizedError {
        case javaNotFound
        case exporterMissing
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .javaNotFound: "Java is required to read .mny files but wasn't found. Install a JDK (e.g. `brew install openjdk`)."
            case .exporterMissing: "The bundled mny-export.jar is missing from the app."
            case .exportFailed(let msg): "Reading the Money file failed:\n\(msg)"
            }
        }
    }

    /// Converts a .mny file to the export JSON. The .mny is first copied to a temp folder so the
    /// original is never opened by anything but a file copy.
    static func export(mnyURL: URL, password: String? = nil) throws -> URL {
        guard let jar = Bundle.main.url(forResource: "mny-export", withExtension: "jar") else { throw Failure.exporterMissing }
        let java = try findJava()

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacMoneyImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let copy = work.appendingPathComponent("source.mny")
        try FileManager.default.copyItem(at: mnyURL, to: copy)
        let out = work.appendingPathComponent("export.json")

        let p = Process()
        p.executableURL = java
        p.arguments = ["-jar", jar.path, copy.path, out.path] + (password.map { [$0] } ?? [])
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: copy)
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.exportFailed(msg.split(separator: "\n").prefix(8).joined(separator: "\n"))
        }
        return out
    }

    static func findJava() throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let home = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let java = URL(fileURLWithPath: home).appendingPathComponent("bin/java")
            if p.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: java.path) { return java }
        }
        for path in ["/opt/homebrew/opt/openjdk/bin/java", "/usr/local/opt/openjdk/bin/java"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw Failure.javaNotFound
    }
}
