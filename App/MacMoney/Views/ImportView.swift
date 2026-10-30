import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ImportRecord.date, order: .reverse) private var history: [ImportRecord]

    @State private var picking = false
    @State private var running = false
    @State private var summary: MoneyImporter.Summary?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Microsoft Money").font(.title2.bold())
            Text("Choose your .mny file. It is copied and read — never modified. You can re-import as often as you like while you run Money side by side: records are updated in place, and anything you add here (that isn't from Money) is kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if running {
                ProgressView("Reading Money file…")
            } else if let summary {
                result(summary)
            } else if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }

            if let last = history.first {
                Text("Last import: \(last.fileName), \(last.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(summary == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose .mny File…") { picking = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
        .padding(24)
        .frame(width: 640)
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "mny") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            run(url)
        }
    }

    private func result(_ s: MoneyImporter.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(s.text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Account").gridColumnAlignment(.leading)
                    Text("Balance")
                    Text("Reconciled total")
                    Text("Money's last reconcile")
                }
                .font(.caption.bold())
                ForEach(s.accountBalances, id: \.name) { a in
                    GridRow {
                        Text(a.name).gridColumnAlignment(.leading)
                        Text(Cents.string(a.balanceCents)).monospacedDigit()
                        Text(Cents.string(a.reconciledCents)).monospacedDigit()
                        HStack(spacing: 4) {
                            Text(a.moneyReconciledCents.map(Cents.string) ?? "—").monospacedDigit()
                            if let m = a.moneyReconciledCents {
                                Image(systemName: m == a.reconciledCents ? "checkmark.circle" : "exclamationmark.triangle")
                                    .foregroundStyle(m == a.reconciledCents ? .green : .orange)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func run(_ url: URL) {
        running = true
        error = nil
        summary = nil
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                // Safety net: a re-import replaces Money-owned records, so snapshot first.
                try? context.save()
                if FileManager.default.fileExists(atPath: Backup.storeURL.path) {
                    try Backup.make(.beforeImport)
                }
                summary = try await MoneyImporter(context: context).importMny(at: url)
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}
