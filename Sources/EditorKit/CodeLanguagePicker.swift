import AppKit

@MainActor private final class CodeLanguageInputCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let drawing = super.drawingRect(forBounds: rect)
        guard let font, drawing.height > 0 else { return drawing }
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let height = min(drawing.height, ceil(lineHeight) + 2)
        return NSRect(x: drawing.minX, y: rect.midY - height / 2, width: drawing.width, height: height)
    }
}

@MainActor public final class CodeLanguagePicker: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public let input = NSTextField()
    public var onCommit: ((CodeLanguagePicker) -> Void)?
    private let disclosure = NSButton()
    private let popover = NSPopover()
    let suggestionTable = NSTableView()
    private let scroll = NSScrollView()
    private let panel = NSView()
    private let inline: Bool
    private let rowHeight: CGFloat = 28
    private var choices: [(label: String, title: String)] = []
    private var suggestions: [(label: String, title: String)] = []
    private var displayedValue: (label: String, title: String)?
    private var noLanguage: String?

    public override var intrinsicContentSize: NSSize { NSSize(width: inline ? 300 : 144, height: inline ? 218 : 26) }
    public override var isHidden: Bool {
        didSet { if isHidden { popover.close() } }
    }

    public convenience override init(frame: NSRect) { self.init(frame: frame, inline: false) }

    public init(frame: NSRect, inline: Bool) {
        self.inline = inline
        super.init(frame: frame)
        input.cell = CodeLanguageInputCell(textCell: "")
        input.isBezeled = true
        input.bezelStyle = .squareBezel
        input.isEditable = true
        input.font = .systemFont(ofSize: inline ? NSFont.systemFontSize : NSFont.smallSystemFontSize)
        input.usesSingleLineMode = true
        input.delegate = self
        disclosure.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        disclosure.bezelStyle = .rounded
        disclosure.target = self
        disclosure.action = #selector(toggleSuggestions)
        input.translatesAutoresizingMaskIntoConstraints = false
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        addSubview(input)
        addSubview(disclosure)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: leadingAnchor),
            input.topAnchor.constraint(equalTo: topAnchor),
            input.heightAnchor.constraint(equalToConstant: inline ? 30 : 26),
            disclosure.leadingAnchor.constraint(equalTo: input.trailingAnchor, constant: 2),
            disclosure.trailingAnchor.constraint(equalTo: trailingAnchor),
            disclosure.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: inline ? 0 : 24)
        ])
        disclosure.isHidden = inline

        suggestionTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language")))
        suggestionTable.headerView = nil
        suggestionTable.style = .plain
        suggestionTable.rowHeight = rowHeight
        suggestionTable.intercellSpacing = .zero
        suggestionTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        suggestionTable.dataSource = self
        suggestionTable.delegate = self
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = suggestionTable
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8)
        ])
        if inline {
            panel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(panel)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: input.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                panel.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 8),
                panel.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            let content = NSViewController()
            content.view = panel
            popover.contentViewController = content
        }
        suggestionTable.backgroundColor = .clear
        scroll.drawsBackground = false
        if inline {
            panel.wantsLayer = true
            panel.layer?.cornerRadius = 8
            panel.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        }
        popover.behavior = .transient
        popover.animates = false
    }

    required init?(coder: NSCoder) { nil }

    public func configure(original: String, hasAdditionalInfo: Bool, title: String, noLanguage: String) {
        self.noLanguage = hasAdditionalInfo ? nil : noLanguage
        choices = (self.noLanguage.map { [(label: "", title: $0)] } ?? [])
            + MarkdownEditorController.codeBlockLanguages.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        input.placeholderString = self.noLanguage
        let titleForOriginal = CodeLanguage(label: original)?.displayName ?? original
        displayedValue = (original, titleForOriginal)
        input.stringValue = titleForOriginal
        input.toolTip = title
        input.setAccessibilityLabel(title)
        disclosure.toolTip = title
        disclosure.setAccessibilityLabel(title)
        if inline { showSuggestions(matching: "") }
    }

    public var language: String {
        let value = input.currentEditor()?.string ?? input.stringValue
        if value == noLanguage { return "" }
        if let displayedValue, value == displayedValue.title { return displayedValue.label }
        return choices.first { $0.title.caseInsensitiveCompare(value) == .orderedSame }?.label ?? value
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        showSuggestions(matching: input.currentEditor()?.string ?? input.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:)) {
            let row = suggestionTable.selectedRow
            if (inline || popover.isShown), suggestions.indices.contains(row) {
                commit(suggestions[row])
            } else {
                commit((language, textView.string))
            }
            return true
        }
        if command == #selector(NSResponder.cancelOperation(_:)), popover.isShown {
            popover.close()
            return true
        }
        if command == #selector(NSResponder.moveDown(_:)) || command == #selector(NSResponder.moveUp(_:)) {
            if !inline, !popover.isShown { showSuggestions(matching: "") }
            guard (inline || popover.isShown), !suggestions.isEmpty else { return false }
            let step = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(suggestionTable.selectedRow + step, 0), suggestions.count - 1)
            suggestionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suggestionTable.scrollRowToVisible(row)
            return true
        }
        return false
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let button = NSButton(title: suggestions[row].title, target: self, action: #selector(chooseSuggestion(_:)))
        button.tag = row
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.alignment = .left
        button.refusesFirstResponder = true
        return button
    }

    @objc private func toggleSuggestions() {
        if popover.isShown {
            popover.close()
        } else {
            window?.makeFirstResponder(input)
            showSuggestions(matching: "")
        }
    }

    private func showSuggestions(matching prefix: String) {
        let search = prefix.lowercased()
        if search.isEmpty {
            suggestions = choices
        } else {
            let tagMatches = choices.filter { $0.label.lowercased().hasPrefix(search) }
            let titleMatches = choices.filter { !$0.label.lowercased().hasPrefix(search) && $0.title.lowercased().hasPrefix(search) }
            suggestions = tagMatches + titleMatches
        }
        suggestionTable.reloadData()
        suggestionTable.deselectAll(nil)
        guard !suggestions.isEmpty else { popover.close(); return }
        suggestionTable.scrollRowToVisible(0)
        guard !inline, let window, !isHidden else { return }
        let size = NSSize(width: max(bounds.width, 170), height: CGFloat(min(suggestions.count, 7)) * rowHeight + 16)
        panel.setFrameSize(size)
        popover.contentSize = size
        panel.layoutSubtreeIfNeeded()
        if !popover.isShown {
            let selection = input.currentEditor()?.selectedRange
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
            if let selection, input.currentEditor() == nil {
                window.makeKey()
                window.makeFirstResponder(input)
                input.currentEditor()?.selectedRange = selection
            }
        }
    }

    @objc private func chooseSuggestion(_ sender: NSButton) {
        guard suggestions.indices.contains(sender.tag) else { return }
        commit(suggestions[sender.tag])
    }

    private func commit(_ value: (label: String, title: String)) {
        popover.close()
        displayedValue = value
        input.stringValue = value.title
        input.currentEditor()?.string = value.title
        onCommit?(self)
    }
}