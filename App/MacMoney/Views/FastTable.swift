import SwiftUI
import AppKit

/// A native NSTableView for large lists (registers, search results, reports).
///
/// SwiftUI's `Table` measures every inserted row (automatic row heights), which stalls the main
/// thread for thousands of rows. This uses fixed-height rows and only creates views for what's on
/// screen, so 10,000+ rows scroll and sort instantly. Columns are sortable by clicking the header,
/// and resizable/reorderable; with `autosave` their widths and order are remembered.
struct FastTable<Row: Identifiable>: NSViewRepresentable where Row.ID: Hashable {
    var rows: [Row]
    var columns: [FastColumn<Row>]
    @Binding var selection: Set<Row.ID>
    var multipleSelection = true
    /// Remembers column widths and order under this name.
    var autosave: String?
    /// Initial header sort (column id, ascending). Nil keeps `rows` in the given order.
    var defaultSort: (column: String, ascending: Bool)?
    /// Start scrolled to the last row (registers), re-applied whenever `scrollKey` changes.
    var scrollToEnd = false
    var scrollKey: AnyHashable?
    var menu: ((Set<Row.ID>) -> [FastMenuItem])?
    var onDoubleClick: ((Row) -> Void)?
    var onDelete: ((Set<Row.ID>) -> Void)?
    /// A plain key (no ⌘/⌃/⌥) pressed with rows selected; return true if handled. Lets lists offer
    /// one-key actions such as B for business.
    var onKey: ((String, Set<Row.ID>) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private var sortKey: String? { autosave.map { "FastTable.\($0).sort" } }

    private var savedSort: (column: String, ascending: Bool)? {
        guard let key = sortKey, let d = UserDefaults.standard.dictionary(forKey: key),
              let column = d["column"] as? String, let ascending = d["ascending"] as? Bool else { return nil }
        return (column, ascending)
    }

    fileprivate func saveSort(_ descriptor: NSSortDescriptor?) {
        guard let key = sortKey else { return }
        if let descriptor, let column = descriptor.key {
            UserDefaults.standard.set(["column": column, "ascending": descriptor.ascending], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let table = FastTableView()
        table.onDelete = { [weak c] in c?.deletePressed() }
        table.onKey = { [weak c] key in c?.keyPressed(key) ?? false }
        table.usesAutomaticRowHeights = false
        table.rowHeight = 22
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = multipleSelection
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 8, height: 0)
        for col in columns {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            tc.title = col.title
            tc.width = col.width
            tc.minWidth = col.minWidth
            tc.maxWidth = col.maxWidth
            tc.headerCell.alignment = col.alignment
            tc.headerToolTip = col.headerHelp
            if col.sort != nil { tc.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: col.firstSortAscending) }
            table.addTableColumn(tc)
        }
        // The sort the user last chose wins over the table's default.
        if let saved = savedSort, columns.contains(where: { $0.id == saved.column && $0.sort != nil }) {
            table.sortDescriptors = [NSSortDescriptor(key: saved.column, ascending: saved.ascending)]
        } else if let d = defaultSort {
            table.sortDescriptors = [NSSortDescriptor(key: d.column, ascending: d.ascending)]
        }
        if let autosave {
            table.autosaveName = "FastTable.\(autosave)"
            table.autosaveTableColumns = true
        }
        table.dataSource = c
        table.delegate = c
        table.target = c
        table.action = #selector(Coordinator.clicked(_:))
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        if menu != nil {
            let m = NSMenu()
            m.delegate = c
            table.menu = m
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        c.table = table
        c.apply(self)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    /// Take all the space offered (an NSScrollView has no intrinsic size, so SwiftUI would otherwise
    /// shrink it to a sliver).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FastTable
        weak var table: NSTableView?
        private var display: [Row] = []
        private var indexByID: [Row.ID: Int] = [:]
        private var columnsByID: [String: FastColumn<Row>] = [:]
        private var syncing = false
        private var reported: Set<Row.ID> = []
        private var lastScrollKey: AnyHashable?
        private var scrolledOnce = false

        init(_ parent: FastTable) { self.parent = parent }

        func apply(_ p: FastTable) {
            parent = p
            columnsByID = Dictionary(p.columns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            guard let table else { return }
            for tc in table.tableColumns {
                if let c = columnsByID[tc.identifier.rawValue], tc.title != c.title { tc.title = c.title }
            }
            resort()
            syncing = true
            table.reloadData()
            let externalChange = p.selection != reported
            selectRows(for: p.selection)
            syncing = false
            reported = p.selection

            let keyChanged = !scrolledOnce || p.scrollKey != lastScrollKey
            lastScrollKey = p.scrollKey
            if keyChanged {
                scrolledOnce = true
                // Wait a turn so the table has its real size before scrolling.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let table = self.table, !self.display.isEmpty else { return }
                    if let first = table.selectedRowIndexes.first { table.scrollRowToVisible(first) }
                    else { table.scrollRowToVisible(p.scrollToEnd ? self.display.count - 1 : 0) }
                }
            } else if externalChange, let first = table.selectedRowIndexes.first {
                table.scrollRowToVisible(first)
            }
        }

        private func resort() {
            if let sd = table?.sortDescriptors.first, let key = sd.key, let cmp = columnsByID[key]?.sort {
                display = sd.ascending ? parent.rows.sorted(by: cmp) : parent.rows.sorted { cmp($1, $0) }
            } else {
                display = parent.rows
            }
            indexByID = Dictionary(display.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        }

        private func selectRows(for ids: Set<Row.ID>) {
            guard let table else { return }
            let wanted = IndexSet(ids.compactMap { indexByID[$0] })
            if wanted != table.selectedRowIndexes { table.selectRowIndexes(wanted, byExtendingSelection: false) }
        }

        private var selectedIDs: Set<Row.ID> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { $0 < display.count ? display[$0].id : nil })
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { display.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < display.count, let col = columnsByID[tableColumn.identifier.rawValue] else { return nil }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FastCell
                ?? FastCell(identifier: tableColumn.identifier)
            let r = display[row]
            cell.configure(text: col.text(r), style: col.style?(r) ?? FastCellStyle(), alignment: col.alignment, monospaced: col.monospaced)
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            parent.saveSort(tableView.sortDescriptors.first)
            let keep = selectedIDs
            resort()
            syncing = true
            tableView.reloadData()
            selectRows(for: keep)
            syncing = false
            if let first = tableView.selectedRowIndexes.first { tableView.scrollRowToVisible(first) }
            else { tableView.scrollRowToVisible(0) }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing else { return }
            let ids = selectedIDs
            reported = ids
            if parent.selection != ids { parent.selection = ids }
        }

        // MARK: Clicks, keys, menu

        @objc func clicked(_ sender: NSTableView) {
            let r = sender.clickedRow, c = sender.clickedColumn
            guard r >= 0, r < display.count, c >= 0, c < sender.tableColumns.count else { return }
            columnsByID[sender.tableColumns[c].identifier.rawValue]?.onClick?(display[r])
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let r = sender.clickedRow
            guard r >= 0, r < display.count else { return }
            if sender.clickedColumn >= 0, columnsByID[sender.tableColumns[sender.clickedColumn].identifier.rawValue]?.onClick != nil { return }
            parent.onDoubleClick?(display[r])
        }

        func keyPressed(_ key: String) -> Bool {
            let ids = selectedIDs
            guard !ids.isEmpty, let handler = parent.onKey else { return false }
            return handler(key, ids)
        }

        func deletePressed() {
            let ids = selectedIDs
            if !ids.isEmpty { parent.onDelete?(ids) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let build = parent.menu else { return }
            let r = table.clickedRow
            guard r >= 0, r < display.count else { return }
            if !table.selectedRowIndexes.contains(r) {
                table.selectRowIndexes([r], byExtendingSelection: false)
            }
            for item in build(selectedIDs) { menu.addItem(item.nsMenuItem()) }
        }
    }
}

/// One column: how to show a row, how to sort it, and an optional single-click action
/// (used for the register's flag and cleared columns).
struct FastColumn<Row> {
    var id: String
    var title: String
    var width: CGFloat
    var minWidth: CGFloat = 20
    var maxWidth: CGFloat = 3000
    var alignment: NSTextAlignment = .left
    var monospaced = false
    var headerHelp: String?
    var firstSortAscending = true
    var text: (Row) -> String
    var style: ((Row) -> FastCellStyle)?
    var sort: ((Row, Row) -> Bool)?
    var onClick: ((Row) -> Void)?

    init(_ title: String, id: String? = nil, width: CGFloat, min: CGFloat = 20, max: CGFloat = 3000,
         align: NSTextAlignment = .left, monospaced: Bool = false, help: String? = nil,
         text: @escaping (Row) -> String, style: ((Row) -> FastCellStyle)? = nil) {
        self.id = id ?? title
        self.title = title
        self.width = width
        self.minWidth = min
        self.maxWidth = max
        self.alignment = align
        self.monospaced = monospaced
        self.headerHelp = help
        self.text = text
        self.style = style
    }

    /// Sort by a comparable value. Strings sort case-insensitively, like Finder.
    func sorted<T: Comparable>(by key: @escaping (Row) -> T, descendingFirst: Bool = false) -> Self {
        var c = self
        c.sort = { key($0) < key($1) }
        c.firstSortAscending = !descendingFirst
        return c
    }

    func sortedText(by key: @escaping (Row) -> String) -> Self {
        var c = self
        c.sort = { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
        return c
    }

    func onClick(_ action: @escaping (Row) -> Void) -> Self {
        var c = self
        c.onClick = action
        return c
    }
}

struct FastCellStyle {
    var color: NSColor?
    var bold = false
    var strikethrough = false
    var dimmed = false
    /// SF Symbol shown instead of the text.
    var symbol: String?
    var tooltip: String?
}

enum FastMenuItem {
    case button(String, enabled: Bool = true, _ action: () -> Void)
    case submenu(String, [FastMenuItem])
    case separator

    func nsMenuItem() -> NSMenuItem {
        switch self {
        case .separator:
            return .separator()
        case .submenu(let title, let items):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach { sub.addItem($0.nsMenuItem()) }
            item.submenu = sub
            return item
        case .button(let title, let enabled, let action):
            let box = MenuAction(action)
            let item = NSMenuItem(title: title, action: enabled ? #selector(MenuAction.run) : nil, keyEquivalent: "")
            item.target = box
            item.representedObject = box   // keeps the target alive
            item.isEnabled = enabled
            return item
        }
    }
}

private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

private final class FastTableView: NSTableView {
    var onDelete: () -> Void = {}
    var onKey: (String) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        // Delete / forward delete
        if event.keyCode == 51 || event.keyCode == 117 { onDelete(); return }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1, onKey(key) { return }
        super.keyDown(with: event)
    }
}

private final class FastCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = Self.symbolConfig
        addSubview(label)
        addSubview(icon)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(text: String, style: FastCellStyle, alignment: NSTextAlignment, monospaced: Bool) {
        if let symbol = style.symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = style.color
            icon.isHidden = false
            label.isHidden = true
        } else {
            icon.isHidden = true
            label.isHidden = false
            let weight: NSFont.Weight = style.bold ? .semibold : .regular
            let size = NSFont.systemFontSize
            label.font = monospaced ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
            label.alignment = alignment
            label.textColor = style.color ?? .labelColor
            if style.strikethrough {
                label.attributedStringValue = NSAttributedString(string: text, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .font: label.font as Any, .foregroundColor: label.textColor as Any,
                ])
            } else {
                label.stringValue = text
            }
        }
        alphaValue = style.dimmed ? 0.5 : 1
        toolTip = style.tooltip
    }
}
