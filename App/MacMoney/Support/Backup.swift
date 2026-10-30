import Foundation
import AppKit
import SQLite3

/// Point-in-time backups of the MacMoney store.
///
/// A backup is a single self-contained SQLite file (`.macmoneybackup`) made with SQLite's online
/// backup API, so it is consistent even while the app has the store open. Every backup is
/// integrity-checked right after it is written. Restoring is staged: the chosen file is recorded,
/// the app relaunches, and the swap happens before the store is opened (after a safety backup of
/// the current data).
enum Backup {
    static let fileExtension = "macmoneybackup"

    enum Reason: String, CaseIterable {
        case manual = "Manual"
        case automatic = "Automatic"
        case beforeImport = "Before import"
        case beforeRestore = "Before restore"
        /// Manual backups are never pruned; the others share the "keep N copies" pool.
        var isPruned: Bool { self != .manual }
    }

    enum Frequency: String, CaseIterable, Identifiable {
        case everyExit = "Every time MacMoney quits"
        case daily = "Daily (on quit)"
        case weekly = "Weekly (on quit)"
        case monthly = "Monthly (on quit)"
        var id: String { rawValue }
        var interval: TimeInterval {
            switch self {
            case .everyExit: return 0
            case .daily: return 86_400 - 3_600       // a little slack so "daily" doesn't drift
            case .weekly: return 7 * 86_400 - 3_600
            case .monthly: return 30 * 86_400 - 3_600
            }
        }
    }

    struct Info: Identifiable, Hashable {
        let url: URL
        let date: Date
        let reason: Reason
        let size: Int
        let encrypted: Bool
        var id: URL { url }
    }

    /// Where a backup's password comes from.
    enum Encryption {
        /// Encrypt if Settings ▸ Backup says so, with the keychain password.
        case settings
        case none
        case password(String)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Locations & settings

    static var dataFolder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MacMoney", isDirectory: true)
    }
    static var storeURL: URL { dataFolder.appendingPathComponent("MacMoney.store") }
    static var defaultFolder: URL { dataFolder.appendingPathComponent("Backups", isDirectory: true) }
    /// iCloud Drive, if it's turned on for this Mac — an easy off-machine copy.
    static var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("MacMoney Backups", isDirectory: true)
    }

    enum Key {
        static let folder = "backup.folder"
        static let auto = "backup.auto"
        static let frequency = "backup.frequency"
        static let keep = "backup.keep"
        static let last = "backup.lastAutomatic"
        static let pendingRestore = "backup.pendingRestore"
        static let lastRestoreResult = "backup.lastRestoreResult"
        static let pendingRestoreIsStaged = "backup.pendingRestoreIsStaged"
        static let pendingRestoreName = "backup.pendingRestoreName"
        static let encrypt = "backup.encrypt"
        static let lastError = "backup.lastError"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.auto: true,
            Key.frequency: Frequency.everyExit.rawValue,
            Key.keep: 10,
        ])
    }

    static var folder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: Key.folder), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
            return defaultFolder
        }
        set { UserDefaults.standard.set(newValue.path, forKey: Key.folder) }
    }
    static var frequency: Frequency {
        Frequency(rawValue: UserDefaults.standard.string(forKey: Key.frequency) ?? "") ?? .everyExit
    }
    static var keepCount: Int { max(1, UserDefaults.standard.integer(forKey: Key.keep)) }
    static var encryptionEnabled: Bool { UserDefaults.standard.bool(forKey: Key.encrypt) }

    static func password(for encryption: Encryption) throws -> String? {
        switch encryption {
        case .none: return nil
        case .password(let p): return p
        case .settings:
            guard encryptionEnabled else { return nil }
            guard let p = BackupKeychain.password() else {
                throw Failure(message: "Backups are set to be encrypted, but the password isn't in the keychain. Set it again in Settings ▸ Backup.")
            }
            return p
        }
    }

    // MARK: Making backups

    /// Writes a verified snapshot of `store` into `folder` and prunes old automatic copies.
    @discardableResult
    static func make(_ reason: Reason, store: URL = storeURL, folder: URL = folder,
                     keep: Int = keepCount, now: Date = Date(), encryption: Encryption = .settings) throws -> URL {
        let password = try password(for: encryption)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = stampFormatter.string(from: now)
        var dest = folder.appendingPathComponent("MacMoney \(stamp) (\(reason.rawValue)).\(fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("MacMoney \(stamp) (\(reason.rawValue)) \(n).\(fileExtension)")
            n += 1
        }
        if let password {
            try writeEncrypted(from: store, to: dest, password: password)
        } else {
            try snapshot(from: store, to: dest)
            do {
                try verify(dest)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        }
        prune(folder: folder, keep: keep)
        return dest
    }

    /// Snapshot → verify → encrypt → decrypt again and verify. The plaintext only ever exists in a
    /// private temp folder that is removed afterwards.
    static func writeEncrypted(from store: URL, to dest: URL, password: String) throws {
        let work = try privateWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let plain = work.appendingPathComponent("snapshot.sqlite")
        try snapshot(from: store, to: plain)
        try verify(plain)
        try encryptVerified(plain, to: dest, password: password, work: work)
    }

    private static func encryptVerified(_ plain: URL, to dest: URL, password: String, work: URL) throws {
        do {
            try BackupCrypto.encrypt(plain, to: dest, password: password)
            let check = work.appendingPathComponent("check-\(UUID().uuidString).sqlite")
            try BackupCrypto.decrypt(dest, to: check, password: password)
            try verify(check)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    private static func privateWorkFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacMoney-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Encrypts the unencrypted backups in a folder in place. Returns how many were converted.
    @discardableResult
    static func encryptExisting(in folder: URL = folder, password: String) throws -> Int {
        let work = try privateWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        var count = 0
        for b in list(in: folder) where !b.encrypted {
            try verify(b.url)
            let temp = folder.appendingPathComponent(".encrypting-\(UUID().uuidString)")
            try encryptVerified(b.url, to: temp, password: password, work: work)
            _ = try FileManager.default.replaceItemAt(b.url, withItemAt: temp)
            count += 1
        }
        return count
    }

    /// The quit-time hook: backs up if automatic backups are on and one is due.
    static func makeAutomaticIfDue(now: Date = Date()) {
        let d = UserDefaults.standard
        guard d.bool(forKey: Key.auto), FileManager.default.fileExists(atPath: storeURL.path) else { return }
        if let last = d.object(forKey: Key.last) as? Date, now.timeIntervalSince(last) < frequency.interval { return }
        do {
            try make(.automatic, now: now)
            d.set(now, forKey: Key.last)
            d.removeObject(forKey: Key.lastError)
        } catch {
            d.set("Automatic backup on \(now.formatted(date: .abbreviated, time: .shortened)) failed: \(error.localizedDescription)",
                  forKey: Key.lastError)
        }
    }

    /// Lists backups in a folder, newest first.
    static func list(in folder: URL = folder) -> [Info] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == fileExtension }.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let name = url.deletingPathExtension().lastPathComponent
            let reason = Reason.allCases.first { name.contains("(\($0.rawValue))") } ?? .manual
            let date = parseStamp(name) ?? v?.creationDate ?? .distantPast
            return Info(url: url, date: date, reason: reason, size: v?.fileSize ?? 0, encrypted: BackupCrypto.isEncrypted(url))
        }
        .sorted { $0.date > $1.date }
    }

    static func prune(folder: URL, keep: Int) {
        let old = list(in: folder).filter { $0.reason.isPruned }.dropFirst(max(1, keep))
        for b in old { try? FileManager.default.removeItem(at: b.url) }
    }

    // MARK: Restoring

    /// Checks the file and records it; the swap happens on the next launch (see `applyPendingRestore`).
    /// An encrypted backup is decrypted now (with `password`, else the keychain password) into a
    /// staging file next to the data file, which is removed once the restore is done.
    static func scheduleRestore(from url: URL, password: String? = nil, stagingFolder: URL = dataFolder) throws {
        let d = UserDefaults.standard
        if BackupCrypto.isEncrypted(url) {
            guard let pw = password ?? BackupKeychain.password() else { throw BackupCrypto.Failure.passwordNeeded }
            let staged = stagingFolder.appendingPathComponent(".restore-staged-\(UUID().uuidString).sqlite")
            do {
                try BackupCrypto.decrypt(url, to: staged, password: pw)
                try verify(staged)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
            d.set(staged.path, forKey: Key.pendingRestore)
            d.set(true, forKey: Key.pendingRestoreIsStaged)
        } else {
            try verify(url)
            d.set(url.path, forKey: Key.pendingRestore)
            d.set(false, forKey: Key.pendingRestoreIsStaged)
        }
        d.set(url.lastPathComponent, forKey: Key.pendingRestoreName)
    }

    /// Called before the store is opened. Makes a safety backup of the current data, then puts the
    /// chosen backup in place. Returns a message for the user, or nil if nothing was pending.
    @discardableResult
    static func applyPendingRestore(store: URL = storeURL, folder: URL = folder,
                                    encryption: Encryption = .settings) -> String? {
        let d = UserDefaults.standard
        guard let path = d.string(forKey: Key.pendingRestore) else { return nil }
        d.removeObject(forKey: Key.pendingRestore)
        let source = URL(fileURLWithPath: path)
        let name = d.string(forKey: Key.pendingRestoreName) ?? source.lastPathComponent
        let staged = d.bool(forKey: Key.pendingRestoreIsStaged)
        d.removeObject(forKey: Key.pendingRestoreName)
        d.removeObject(forKey: Key.pendingRestoreIsStaged)
        defer { if staged { try? FileManager.default.removeItem(at: source) } }
        let message: String
        do {
            try verify(source)
            if FileManager.default.fileExists(atPath: store.path) {
                try make(.beforeRestore, store: store, folder: folder, encryption: encryption)
            }
            try replaceStore(store, with: source)
            message = "Restored \(name). Your previous data was saved as a “Before restore” backup."
        } catch {
            message = "Restore failed — your data was not changed. \(error.localizedDescription)"
        }
        d.set(message, forKey: Key.lastRestoreResult)
        return message
    }

    /// Copies `source` into a temp file next to the store, then swaps it in, removing the WAL files.
    static func replaceStore(_ store: URL, with source: URL) throws {
        let fm = FileManager.default
        let staged = store.deletingLastPathComponent().appendingPathComponent(".restore-\(UUID().uuidString)")
        try snapshot(from: source, to: staged)
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: store.path + suffix))
        }
        if fm.fileExists(atPath: store.path) {
            _ = try fm.replaceItemAt(store, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: store)
        }
    }

    /// Quits and reopens the app so a staged restore can be applied.
    @MainActor
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: SQLite

    /// Copies a whole database using SQLite's online backup API (safe while the source is in use).
    static func snapshot(from source: URL, to dest: URL) throws {
        var src: OpaquePointer?
        var dst: OpaquePointer?
        defer { sqlite3_close(src); sqlite3_close(dst) }
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw Failure(message: "Couldn't open \(source.lastPathComponent).")
        }
        guard sqlite3_open_v2(dest.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw Failure(message: "Couldn't create \(dest.lastPathComponent).")
        }
        guard let b = sqlite3_backup_init(dst, "main", src, "main") else {
            throw Failure(message: "Backup failed: \(String(cString: sqlite3_errmsg(dst)))")
        }
        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(b, -1)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(50) }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        sqlite3_backup_finish(b)
        guard rc == SQLITE_DONE else { throw Failure(message: "Backup failed: \(String(cString: sqlite3_errmsg(dst)))") }
        sqlite3_close(dst); dst = nil
        // The copy inherits WAL mode; make it a self-contained single file with no -wal/-shm sidecars.
        var db: OpaquePointer?
        if sqlite3_open_v2(dest.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        }
        sqlite3_close(db)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dest.path + suffix) }
    }

    /// Fails unless the file passes SQLite's integrity check and looks like a MacMoney store.
    static func verify(_ url: URL) throws {
        let result = try integrityCheck(url)
        guard result == ["ok"] else {
            throw Failure(message: "\(url.lastPathComponent) is damaged: \(result.prefix(3).joined(separator: "; "))")
        }
        guard try scalar(url, "SELECT count(*) FROM sqlite_master WHERE name = 'ZENTRY'") == 1 else {
            throw Failure(message: "\(url.lastPathComponent) isn't a MacMoney data file.")
        }
    }

    /// Runs `PRAGMA integrity_check`; ["ok"] means healthy.
    static func integrityCheck(_ url: URL) throws -> [String] {
        try query(url, "PRAGMA integrity_check").map { $0 ?? "" }
    }

    static func scalar(_ url: URL, _ sql: String) throws -> Int {
        Int(try query(url, sql).first.flatMap { $0 } ?? "") ?? 0
    }

    private static func query(_ url: URL, _ sql: String) throws -> [String?] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw Failure(message: "Couldn't open \(url.lastPathComponent).")
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Failure(message: "\(url.lastPathComponent) isn't a readable data file.")
        }
        var out: [String?] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) })
        }
        return out
    }

    // MARK: Names

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    private static func parseStamp(_ name: String) -> Date? {
        // "MacMoney 2026-10-29 213900 (Automatic)"
        let parts = name.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        return stampFormatter.date(from: "\(parts[1]) \(parts[2])")
    }
}
