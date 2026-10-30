import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// File ▸ Backups…: list of point-in-time copies, back up now, restore, reveal in Finder.
struct BackupsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [Backup.Info] = []
    @State private var selection: Backup.Info.ID?
    @State private var restoring: URL?
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
            Text("Folder: \(Backup.folder.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

            Table(backups, selection: $selection) {
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
                    Button("Restore…") { restoring = url }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = backups.first { $0.url == url } }
                }
            } primaryAction: { ids in
                restoring = ids.first
            }
            .frame(minHeight: 260)

            if let message { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }

            HStack {
                Button { backUp(to: nil) } label: { Label("Back Up Now", systemImage: "externaldrive.badge.plus") }
                    .buttonStyle(.borderedProminent)
                Button("Back Up To…") { chooseDestination() }
                    .help("Save a backup somewhere else, such as an external drive")
                Button("Restore…") { restoring = selection }.disabled(selection == nil)
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
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            presenting: restoring) { url in
            Button("Restore and Relaunch", role: .destructive) { restore(url) }
        } message: { url in
            Text("MacMoney will quit, replace all current data with “\(url.lastPathComponent)”, and reopen. Your current data is backed up first.")
        }
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
        do {
            let url = try Backup.make(.manual, folder: folder ?? Backup.folder)
            message = "Backed up to \(url.lastPathComponent)"
            reload()
            selection = url
        } catch {
            self.error = error.localizedDescription
        }
        working = false
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
        if panel.runModal() == .OK, let url = panel.url { restoring = url }
    }

    private func restore(_ url: URL) {
        error = nil
        try? context.save()
        do {
            try Backup.scheduleRestore(from: url)
            Backup.relaunch()
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
        }
    }
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
