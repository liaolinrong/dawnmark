import AppKit
import MarkdownEngine

@MainActor public final class OutlineSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    public let outlineView = NSOutlineView()
    public private(set) var headings: [OutlineHeading] = []
    public var onNavigate: ((OutlineHeading) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    public var title: String = "" {
        didSet { titleLabel.stringValue = title; outlineView.setAccessibilityLabel(title) }
    }
    public var untitledHeading: String = "" { didSet { outlineView.reloadData() } }
    private let titleLabel = NSTextField(labelWithString: "")
    private var roots: [Node] = []
    private var nodes: [Node] = []
    private var updatingSelection = false

    private final class Node {
        let heading: OutlineHeading
        let key: String
        var children: [Node] = []
        init(heading: OutlineHeading, key: String) { self.heading = heading; self.key = key }
    }

    final class HeadingCell: NSTableCellView {
        var leading: NSLayoutConstraint?
    }
    private var minimumLevel = 1

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 12
        outlineView.style = .sourceList
        outlineView.backgroundColor = .controlBackgroundColor
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(activateSelectedHeading)
        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        for child in [titleLabel, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isHidden = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }

    public func update(headings: [OutlineHeading]) {
        guard self.headings != headings else { return }
        let collapsed = Set(nodes.filter { !$0.children.isEmpty && !outlineView.isItemExpanded($0) }.map(\.key))
        self.headings = headings
        minimumLevel = headings.map(\.level).min() ?? 1
        roots = []
        nodes = []
        var ancestors: [Node] = []
        var occurrences: [String: Int] = [:]
        for heading in headings {
            while let last = ancestors.last, last.heading.level >= heading.level { ancestors.removeLast() }
            let identity = "\(heading.level):\(heading.title)"
            let occurrence = occurrences[identity, default: 0]
            occurrences[identity] = occurrence + 1
            let node = Node(heading: heading, key: "\(identity):\(occurrence)")
            if let parent = ancestors.last { parent.children.append(node) } else { roots.append(node) }
            nodes.append(node)
            ancestors.append(node)
        }
        updatingSelection = true
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        for node in nodes where collapsed.contains(node.key) { outlineView.collapseItem(node) }
        updatingSelection = false
        isHidden = headings.isEmpty
        onVisibilityChanged?(!headings.isEmpty)
    }

    public func selectHeading(atSourceOffset offset: Int) {
        updatingSelection = true
        defer { updatingSelection = false }
        guard let node = nodes.last(where: { $0.heading.sourceRange.location <= offset }) else {
            outlineView.deselectAll(nil)
            return
        }
        let row = outlineView.row(forItem: node)
        if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { outlineView.deselectAll(nil) }
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node)?.children ?? roots)[index]
    }
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !(item as! Node).children.isEmpty
    }
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! Node
        let identifier = NSUserInterfaceItemIdentifier("outlineHeading")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? HeadingCell) ?? HeadingCell()
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            let leading = label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
            cell.leading = leading
            NSLayoutConstraint.activate([
                leading,
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        // The tree nests by ancestry; skipped levels (H1 → H3) still get their own indentation step.
        let skipped = max(0, node.heading.level - minimumLevel - outlineView.level(forItem: node))
        cell.leading?.constant = 2 + CGFloat(skipped) * outlineView.indentationPerLevel
        cell.textField?.stringValue = node.heading.title.isEmpty ? untitledHeading : node.heading.title
        cell.toolTip = cell.textField?.stringValue
        return cell
    }
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        activateSelectedHeading()
    }

    @objc private func activateSelectedHeading() {
        guard !updatingSelection, let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return }
        onNavigate?(node.heading)
    }
}