import SwiftUI
import SwiftData
import AppKit

/// Attaching receipts (by reference) to purchase items, and finding them again.
@MainActor
enum ReceiptFiles {
    /// Adds each file to each item, skipping ones an item already has.
    static func attach(_ urls: [URL], to items: [PurchaseItem], context: ModelContext) {
        for item in items {
            var have = Set((item.files ?? []).map(\.path))
            for url in urls where have.insert(url.path).inserted {
                let f = PurchaseFile(url: url)
                context.insert(f)
                f.item = item
            }
        }
        try? context.save()
    }

    static func choose(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Opens a Finder window on the file's folder with the file selected.
    static func reveal(_ file: PurchaseFile) -> Bool {
        guard let url = file.locate() else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}

/// The receipts section of the purchase detail panel: zero or more files per item.
struct ReceiptFilesSection: View {
    @Environment(\.modelContext) private var context
    let items: [PurchaseItem]

    private var files: [PurchaseFile] {
        items.count == 1 ? (items[0].files ?? []).sorted { $0.added < $1.added } : []
    }

    var body: some View {
        Section {
            ForEach(files, id: \.uuid) { row($0) }
            HStack {
                Button {
                    let urls = ReceiptFiles.choose(message: items.count == 1
                        ? "Choose receipts or documents for “\(items[0].shortName)”"
                        : "Choose receipts or documents for the \(items.count) selected items")
                    ReceiptFiles.attach(urls, to: items, context: context)
                } label: {
                    Label(items.count == 1 ? "Add Receipt…" : "Add Receipt to \(items.count) Items…", systemImage: "paperclip")
                }
                Spacer()
            }
        } header: {
            Text("Receipts")
        } footer: {
            Text("Files stay where they are; MacMoney remembers where to find them (backups don't include them). You can also drop files here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ file: PurchaseFile) -> some View {
        let url = file.locate()
        return HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(url == nil ? "Can't find it at \(file.path)" : (url!.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(url == nil ? .orange : .secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if url == nil {
                Button("Locate…") { locate(file) }
            } else {
                Button { _ = ReceiptFiles.reveal(file) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let url { NSWorkspace.shared.open(url) } }
        .contextMenu {
            Button("Show in Finder") { _ = ReceiptFiles.reveal(file) }.disabled(url == nil)
            Button("Open") { if let url { NSWorkspace.shared.open(url) } }.disabled(url == nil)
            Button("Locate…") { locate(file) }
            Divider()
            Button("Remove", role: .destructive) {
                context.delete(file)
                try? context.save()
            }
        }
        .help(url == nil ? "Moved or deleted. Right-click ▸ Locate… to point to it again." : "Double-click to open · Show in Finder to see it in its folder")
    }

    private func locate(_ file: PurchaseFile) {
        guard let url = ReceiptFiles.choose(message: "Where is “\(file.name)” now?").first else { return }
        file.path = url.path
        file.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try? context.save()
    }
}
