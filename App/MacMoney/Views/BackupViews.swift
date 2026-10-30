import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// File ▸ Backups…: list of point-in-time copies, back up now, restore, reveal in Finder.
struct BackupsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [Backup.Info] = []
    @State private var selection: Backup.Info.ID?
    @State private var restoring: RestoreTarget?
    @State private var deleting: Backup.Info?
    @State private var message: String?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Backups").font(.title2.bold())
                Spacer()
                SettingsLink { Label("Backup Settings…", systemImage: "gearshape") }
            }
            Text("Each backup is a complete, verified copy of your MacMoney data at that moment. Restoring replaces everything with that copy — your current data is saved first as a “Before restore” backup, so a restore can always be undone.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Folder: \(Backup.folder.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Label(Backup.encryptionEnabled ? "New backups are encrypted" : "New backups are not encrypted",
                      systemImage: Backup.encryptionEnabled ? "lock.fill" : "lock.open")
                    .font(.caption).foregroundStyle(Backup.encryptionEnabled ? .green : .secondary)
            }
            if let failure = UserDefaults.standard.string(forKey: Backup.Key.lastError) {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }

            Table(backups, selection: $selection) {
                TableColumn("") { b in
                    if b.encrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Encrypted") }
                }
                .width(16)
                TableColumn("Date") { b in
                    Text(b.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                }
                .width(min: 160, ideal: 190)
                TableColumn("Type") { b in
                    Text(b.reason.rawValue).foregroundStyle(b.reason == .manual ? .primary : .secondary)
                }
                .width(min: 100, ideal: 120)
                TableColumn("Size") { b in
                    Text(ByteCountFormatter.string(fromByteCount: Int64(b.size), countStyle: .file))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(70)
            }
            .contextMenu(forSelectionType: Backup.Info.ID.self) { ids in
                if let url = ids.first {
                    Button("Restore…") { restoring = RestoreTarget(url: url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = backups.first { $0.url == url } }
                }
            } primaryAction: { ids in
                restoring = ids.first.map(RestoreTarget.init)
            }
            .frame(minHeight: 260)

            if let message { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }

            HStack {
                Button { backUp(to: nil) } label: { Label("Back Up Now", systemImage: "externaldrive.badge.plus") }
                    .buttonStyle(.borderedProminent)
                Button("Back Up To…") { chooseDestination() }
                    .help("Save a backup somewhere else, such as an external drive")
                Button("Restore…") { restoring = selection.map(RestoreTarget.init) }.disabled(selection == nil)
                Button("Restore From File…") { chooseRestoreFile() }
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: Backup.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Backup.folder)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
        .onAppear(perform: reload)
        .sheet(item: $restoring) { RestoreSheet(url: $0.url) }
        .confirmationDialog("Delete backup?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { b in
            Button("Move to Trash", role: .destructive) {
                try? FileManager.default.trashItem(at: b.url, resultingItemURL: nil)
                reload()
            }
        } message: { b in
            Text(b.url.lastPathComponent)
        }
    }

    private func reload() { backups = Backup.list() }

    private func backUp(to folder: URL?) {
        error = nil; message = nil; working = true
        try? context.save()
        let target = folder ?? Backup.folder
        // Off the main thread: encrypting (key derivation + verify) takes about a second.
        Task {
            let result = await Task.detached { Result { try Backup.make(.manual, folder: target) } }.value
            working = false
            switch result {
            case .success(let url):
                message = "Backed up to \(url.lastPathComponent)"
                reload()
                selection = url
            case .failure(let e):
                self.error = e.localizedDescription
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        if panel.runModal() == .OK, let url = panel.url { backUp(to: url) }
    }

    private func chooseRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Backup.fileExtension) ?? .data]
        panel.directoryURL = Backup.folder
        panel.prompt = "Restore"
        if panel.runModal() == .OK, let url = panel.url { restoring = RestoreTarget(url: url) }
    }
}

struct RestoreTarget: Identifiable {
    let url: URL
    var id: URL { url }

    /// Shows an Open panel for a backup file anywhere (e.g. iCloud Drive, a USB drive).
    static func choose() -> RestoreTarget? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Backup.fileExtension) ?? .data]
        panel.directoryURL = Backup.iCloudFolder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? Backup.folder
        panel.prompt = "Choose"
        panel.message = "Choose a MacMoney backup (.macmoneybackup)"
        return panel.runModal() == .OK ? panel.url.map(RestoreTarget.init) : nil
    }
}

/// Confirms a restore and, for an encrypted backup this Mac doesn't have the password for, asks for it.
struct RestoreSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var password = ""
    @State private var needsPassword = false
    @State private var remember = true
    @State private var error: String?
    @State private var working = false

    private var encrypted: Bool { BackupCrypto.isEncrypted(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Restore Backup", systemImage: encrypted ? "lock.fill" : "clock.arrow.circlepath").font(.title2.bold())
            Text(url.lastPathComponent).font(.callout.monospaced()).textSelection(.enabled)
            Text("MacMoney will quit, replace all current data with this backup, and reopen. Your current data is saved first as a “Before restore” backup, so this can be undone.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if needsPassword {
                Divider()
                Text("This backup is encrypted. Enter the backup password that was set in MacMoney when it was made — not your Mac login password.").font(.callout).fixedSize(horizontal: false, vertical: true)
                SecureField("Backup password", text: $password).textFieldStyle(.roundedBorder).onSubmit(restore)
                Toggle("Remember this password on this Mac and encrypt new backups with it", isOn: $remember)
                    .toggleStyle(.checkbox).font(.callout)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Decrypting and checking…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore and Relaunch", action: restore)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || (needsPassword && password.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            needsPassword = encrypted && BackupKeychain.password() == nil
            remember = BackupKeychain.password() == nil
        }
    }

    private func restore() {
        error = nil
        working = true
        try? context.save()
        let typed = password.isEmpty ? nil : password
        let url = url
        Task {
            let result = await Task.detached { Result { try Backup.scheduleRestore(from: url, password: typed) } }.value
            working = false
            switch result {
            case .success:
                if let typed, remember {
                    try? BackupKeychain.setPassword(typed)
                    UserDefaults.standard.set(true, forKey: Backup.Key.encrypt)
                }
                Backup.relaunch()
            case .failure(BackupCrypto.Failure.passwordNeeded):
                needsPassword = true
                error = nil
            case .failure(BackupCrypto.Failure.wrongPassword) where typed == nil:
                // The keychain password didn't open it: made with another (older) backup password.
                needsPassword = true
                error = "This backup was made with a different password. Enter it to continue."
            case .failure(BackupCrypto.Failure.wrongPassword):
                needsPassword = true
                error = "That password didn't work."
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }
}

/// Set or change the backup password.
struct BackupPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let changing: Bool
    let save: (String) throws -> Void
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?

    private var problem: String? {
        if password.count < 8 { return "Use at least 8 characters — a passphrase of a few words is best." }
        if password != confirm { return "The passwords don't match." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(changing ? "Change Backup Password" : "Set Backup Password", systemImage: "lock.fill").font(.title3.bold())
            Text("This is its own password, separate from your Mac login.").font(.callout).foregroundStyle(.secondary)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Confirm password", text: $confirm).textFieldStyle(.roundedBorder).onSubmit(commit)
            if let problem, !password.isEmpty { Text(problem).font(.caption).foregroundStyle(.secondary) }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("If you lose this password, encrypted backups can't be opened — by anyone.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Save it in your password manager. You'll need it to restore on a new Mac. On this Mac it's kept in your login keychain, so automatic backups never ask for it.")
                        .foregroundStyle(.secondary)
                    if changing {
                        Text("Backups you already have keep the password they were made with.").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Password", action: commit).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func commit() {
        guard problem == nil else { return }
        do {
            try save(password)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Settings ▸ Backup.
struct BackupSettingsView: View {
    @AppStorage(Backup.Key.auto) private var auto = true
    @AppStorage(Backup.Key.frequency) private var frequency = Backup.Frequency.everyExit.rawValue
    @AppStorage(Backup.Key.keep) private var keep = 10
    @AppStorage(Backup.Key.folder) private var folderPath = ""
    @AppStorage(Backup.Key.encrypt) private var encrypt = false
    @State private var settingPassword = false
    @State private var hasPassword = BackupKeychain.password() != nil
    @State private var encryptStatus: String?
    @State private var encrypting = false

    var body: some View {
        Form {
            Section {
                Toggle("Back up automatically when MacMoney quits", isOn: $auto)
                Picker("How often", selection: $frequency) {
                    ForEach(Backup.Frequency.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .disabled(!auto)
                Stepper("Keep the \(keep) most recent automatic backups", value: $keep, in: 1...100)
                Text("Backups taken before imports and restores count toward this limit. Manual backups are never deleted automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Encryption") {
                Toggle("Encrypt backups with a password", isOn: Binding(get: { encrypt }, set: { on in
                    if on && !hasPassword { settingPassword = true } else { encrypt = on }
                }))
                Text("AES-256 encryption. The password is kept in your login keychain so automatic backups never ask; you'll need to type it only to restore on another Mac. If it's lost, encrypted backups can't be recovered.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(hasPassword ? "Change Password…" : "Set Password…") { settingPassword = true }
                    let plain = Backup.list().filter { !$0.encrypted }.count
                    Button("Encrypt \(plain) Existing Backup\(plain == 1 ? "" : "s")") { encryptExisting() }
                        .disabled(!encrypt || !hasPassword || plain == 0 || encrypting)
                        .help("Converts the unencrypted backups in the backup folder")
                    if encrypting { ProgressView().controlSize(.small) }
                }
                if let encryptStatus { Text(encryptStatus).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Location") {
                Text(Backup.folder.path).font(.callout).textSelection(.enabled).lineLimit(2)
                HStack {
                    Button("Choose…") { choose() }
                    if let cloud = Backup.iCloudFolder {
                        Button("Use iCloud Drive") { folderPath = cloud.path }
                            .help("Keeps copies off this Mac and visible on your other Macs")
                    }
                    Button("Use Default") { folderPath = "" }.disabled(folderPath.isEmpty)
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: Backup.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Backup.folder)
                    }
                }
                Text("Existing backups stay where they are when you change the folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
        .sheet(isPresented: $settingPassword) {
            BackupPasswordSheet(changing: hasPassword) { pw in
                try BackupKeychain.setPassword(pw)
                hasPassword = true
                encrypt = true
            }
        }
    }

    private func encryptExisting() {
        guard let pw = BackupKeychain.password() else { return }
        encrypting = true
        encryptStatus = nil
        Task {
            let result = await Task.detached { Result { try Backup.encryptExisting(password: pw) } }.value
            encrypting = false
            switch result {
            case .success(let n): encryptStatus = "Encrypted \(n) backup\(n == 1 ? "" : "s")."
            case .failure(let e): encryptStatus = "Stopped: \(e.localizedDescription)"
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Backup.folder
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            BackupSettingsView().tabItem { Label("Backup", systemImage: "externaldrive") }
            AboutSettingsView().tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    static var icon: NSImage { NSApp.applicationIconImage ?? NSImage() }
}

/// Settings ▸ About: icon, version, where the data lives, license.
struct AboutSettingsView: View {
    @State private var showLicense = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: AppInfo.icon).resizable().interpolation(.high).frame(width: 128, height: 128)
            VStack(spacing: 4) {
                Text("MacMoney").font(.largeTitle.bold())
                Text("Version \(AppInfo.version) (build \(AppInfo.build))").foregroundStyle(.secondary).textSelection(.enabled)
                Text("A native Mac home for your Microsoft Money history.").font(.callout)
            }
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    location("Data file", Backup.storeURL)
                    location("Backups", Backup.folder)
                }
                .padding(4)
            }
            .frame(width: 500)
            HStack {
                Button("License…") { showLicense = true }
                Link("Documentation", destination: URL(string: "https://github.com/sirforce/macosmoney#readme")!)
            }
            VStack(spacing: 2) {
                Text("Copyright © 2026 Brent Ferree · MIT License").font(.caption)
                Text("Not affiliated with or endorsed by Microsoft.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 560)
        .sheet(isPresented: $showLicense) {
            VStack(alignment: .leading, spacing: 12) {
                Text("MIT License").font(.title3.bold())
                ScrollView { Text(Self.license).font(.callout.monospaced()).textSelection(.enabled) }
                HStack { Spacer(); Button("Done") { showLicense = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
            .frame(width: 560, height: 420)
        }
    }

    private func location(_ title: String, _ url: URL) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(url.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
    }

    static let license = """
    Copyright (c) 2026 Brent Ferree

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

/// File ▸ Check Data File…
struct DataCheckView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var result: DataCheck?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check Data File").font(.title2.bold())
            if let r = result {
                Label(r.healthy ? (r.issues.isEmpty ? "No problems found." : "No serious problems found.") : "Problems found — consider restoring a recent backup.",
                      systemImage: r.healthy ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(r.healthy ? .green : .red)
                Text(r.counts.map { "\($0.1.formatted()) \($0.0.lowercased())" }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
                List(r.issues) { issue in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(issue.title, systemImage: icon(issue.severity))
                            .foregroundStyle(color(issue.severity)).font(.body.bold())
                        Text(issue.detail).font(.callout).foregroundStyle(.secondary)
                        ForEach(issue.examples, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 3)
                }
                .overlay { if r.issues.isEmpty { Text("Database integrity, transfers, splits and duplicates all look good.").foregroundStyle(.secondary) } }
            } else {
                ProgressView("Checking…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Check Again") { result = nil; Task { run() } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
        .task { run() }
    }

    private func run() {
        try? context.save()
        result = DataCheck.run(context: context)
    }

    private func icon(_ s: DataCheck.Issue.Severity) -> String {
        switch s { case .problem: "xmark.octagon.fill"; case .warning: "exclamationmark.triangle.fill"; case .info: "info.circle.fill" }
    }
    private func color(_ s: DataCheck.Issue.Severity) -> Color {
        switch s { case .problem: .red; case .warning: .orange; case .info: .blue }
    }
}
