import AppKit
import DawnMarkSupport
import DocumentWorkspace
import EditorKit
import UniformTypeIdentifiers

@MainActor extension AppDelegate {
    var activeDocument: MarkdownDocument? {
        (NSApp.keyWindow?.windowController?.document as? MarkdownDocument) ?? (NSApp.mainWindow?.windowController?.document as? MarkdownDocument)
    }

    @objc func newDocument(_ sender: Any?) {
        guard commerce.canEdit else { showPurchase(); return }
        guard let request = destinationRequest(title: .newDocument, suggestedName: L10n.text(.untitled)) else { return }
        let access = request.parent.startAccessingSecurityScopedResource()
        defer { if access { request.parent.stopAccessingSecurityScopedResource() } }
        do {
            guard commerce.canEdit else { return }
            let location = try DocumentStore().create(name: request.name, in: request.parent)
            let document = displayDocument(location, source: "")
            document.retainAccess(to: request.parent)
            try SecurityScopedBookmarks.shared.remember(request.parent)
            try SecurityScopedBookmarks.shared.remember(location.directoryURL)
        } catch { showError(error) }
    }

    @objc func open(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!, UTType(filenameExtension: "markdown")!]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openDocument(url) }
    }

    func openDocument(_ requestedURL: URL) {
        let directory = SecurityScopedBookmarks.shared.resolveDirectory(containing: requestedURL)
        let url = SecurityScopedBookmarks.shared.resolveFile(requestedURL) ?? requestedURL
        if let existing = NSDocumentController.shared.documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            existing.showWindows()
            return
        }
        let directoryAccess = directory?.startAccessingSecurityScopedResource() == true
        defer { if directoryAccess { directory?.stopAccessingSecurityScopedResource() } }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let location = DocumentLocation(markdownURL: url)
            let document = displayDocument(location, source: try DocumentStore().read(location))
            document.retainAccess(to: url)
            if let directory { document.retainAccess(to: directory) }
            try SecurityScopedBookmarks.shared.remember(url)
        } catch { showError(error) }
    }

    @discardableResult func displayDocument(_ location: DocumentLocation, source: String) -> MarkdownDocument {
        let document = MarkdownDocument(location: location, source: source, commerce: commerce)
        document.editor.linkMenu = { [weak self, weak document] link in
            guard let self, let document else { return nil }
            return self.makeLinkMenu(document: document, link: link)
        }
        document.editor.tableMenu = { [weak self, weak document] range in
            guard let self, let document else { return nil }
            return self.makeTableMenu(document: document, sourceRange: range)
        }
        NSDocumentController.shared.addDocument(document)
        NSDocumentController.shared.noteNewRecentDocumentURL(location.markdownURL)
        let snapshot = MarkdownRenderer.snapshot(source: source)
        if snapshot.runs.contains(where: { run in
            guard let path = run.imagePath else { return false }
            return URLComponents(string: path)?.scheme == nil && !path.hasPrefix("//")
        }) {
            _ = document.authorizeDirectory()
        }
        document.makeWindowControllers()
        document.showWindows()
        auxiliaryWindows["welcome"]?.close()
        auxiliaryWindows["welcome"] = nil
        return document
    }

    @objc func save(_ sender: Any?) { activeDocument?.save(sender) }

    @objc func saveAs(_ sender: Any?) {
        guard let document = activeDocument, commerce.canEdit else { return }
        guard document.authorizeDirectory(),
              let request = destinationRequest(title: .saveAs, suggestedName: document.location.directoryURL.lastPathComponent), commerce.canEdit else { return }
        let access = request.parent.startAccessingSecurityScopedResource()
        defer { if access { request.parent.stopAccessingSecurityScopedResource() } }
        do {
            let destination = try DocumentStore().duplicate(document.location, source: document.session.source, name: request.name, in: request.parent)
            let copy = displayDocument(destination, source: try DocumentStore().read(destination))
            copy.retainAccess(to: request.parent)
            try SecurityScopedBookmarks.shared.remember(request.parent)
            try SecurityScopedBookmarks.shared.remember(destination.directoryURL)
        } catch { showError(error) }
    }

    private func destinationRequest(title: TextKey, suggestedName: String) -> (parent: URL, name: String)? {
        let field = NSTextField(string: suggestedName)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = L10n.text(.documentName)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text(.chooseFolder))
        alert.addButton(withTitle: L10n.text(.cancel))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.title = L10n.text(title)
        panel.prompt = L10n.text(.create)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return nil }
        return (parent, field.stringValue)
    }

    @objc func showInFinder(_ sender: Any?) {
        if let url = activeDocument?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func changeMode(_ sender: NSMenuItem) {
        activeDocument?.editor.mode = sender.tag == 1 ? .source : .richText
    }

    @objc func formatCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? FormatBox, let document = activeDocument else { return }
        if !document.editor.perform(box.command) {
            let message: String
            if document.editor.mode == .richText, case .indent = box.command {
                message = L10n.format(.listIndentOnly, L10n.text(.richMode), L10n.text(.sourceMode))
            } else {
                message = L10n.text(.unsupportedEdit)
            }
            let alert = NSAlert(); alert.messageText = message; alert.runModal()
        }
    }

    @objc func insertLink(_ sender: Any?) {
        guard let document = activeDocument, commerce.canEdit else { return }
        showLinkEditor(document: document, link: document.editor.currentLink)
    }

    func showLinkEditor(document: MarkdownDocument, link: MarkdownLinkContext?) {
        guard commerce.canEdit, document.editor.canEdit,
              document.editor.textView?.isComposing != true, document.editor.textView?.hasMarkedText() != true else { return }
        let originalSource = document.session.source
        let range = link?.sourceRange ?? document.editor.selectedSourceRange()
        let form = LinkInsertionForm(editor: document.editor, link: link)
        let selected = form.displayTextField.stringValue
        let alert = NSAlert()
        alert.messageText = L10n.text(link == nil ? .link : .editLink)
        alert.accessoryView = form
        alert.addButton(withTitle: L10n.text(link == nil ? .confirm : .save)); alert.addButton(withTitle: L10n.text(.cancel))
        alert.window.initialFirstResponder = selected.isEmpty ? form.displayTextField : form.addressField
        guard alert.runModal() == .alertFirstButtonReturn,
              document.session.source == originalSource,
              !form.addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let label = !selected.isEmpty && form.displayTextField.stringValue == selected ? nil : form.displayTextField.stringValue
        _ = document.editor.updateLink(in: range, destination: form.addressField.stringValue, label: label)
    }

    func makeLinkMenu(document: MarkdownDocument, link: MarkdownLinkContext) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let context = LinkMenuContext(document: document, link: link)
        let actions: [(TextKey, Selector)] = [(.editLink, #selector(editLinkFromMenu(_:))), (.openLink, #selector(openLinkFromMenu(_:))),
                                             (.copyLinkAddress, #selector(copyLinkFromMenu(_:))), (.removeLink, #selector(removeLinkFromMenu(_:)))]
        for (key, action) in actions {
            let item = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = context
            if key == .editLink || key == .removeLink { item.isEnabled = commerce.canEdit && document.editor.canEdit }
            menu.addItem(item)
        }
        return menu
    }

    @objc func editLinkFromMenu(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? LinkMenuContext,
              let document = context.document, document.session.source == context.source else { return }
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        showLinkEditor(document: document, link: context.link)
    }

    @objc func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? LinkMenuContext,
              let document = context.document, let url = URL(string: context.link.destination, relativeTo: document.fileURL)?.absoluteURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? LinkMenuContext else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(context.link.destination, forType: .string)
    }

    @objc func removeLinkFromMenu(_ sender: NSMenuItem) {
        guard commerce.canEdit, let context = sender.representedObject as? LinkMenuContext,
              let document = context.document, document.session.source == context.source else { return }
        _ = document.editor.removeLink(in: context.link.sourceRange)
    }

    func makeTableMenu(document: MarkdownDocument, sourceRange: NSRange) -> NSMenu {
        let menu = NSMenu(title: L10n.text(.tableActions))
        menu.autoenablesItems = false
        for (index, commands) in tableCommandGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for (key, command) in commands {
                let item = NSMenuItem(title: L10n.text(key), action: #selector(tableCommandFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = TableMenuContext(document: document, sourceRange: sourceRange, command: command)
                item.isEnabled = commerce.canEdit && document.editor.canEdit
                    && !document.editor.textView.isComposing && !document.editor.textView.hasMarkedText()
                    && document.session.formattingState(command, in: sourceRange) != .unavailable
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc func tableCommandFromMenu(_ sender: NSMenuItem) {
        guard commerce.canEdit, let context = sender.representedObject as? TableMenuContext,
              let document = context.document, document.session.source == context.source else { return }
        _ = document.editor.perform(context.command, inSourceRange: context.sourceRange)
    }

    @objc func insertImage(_ sender: Any?) {
        guard let document = activeDocument, commerce.canEdit else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        document.importImages(urls: panel.urls, data: nil)
    }

    @objc func insertTable(_ sender: Any?) {
        guard let document = activeDocument, commerce.canEdit else { return }
        let columns = NSTextField(string: "2")
        let rows = NSTextField(string: "2")
        columns.widthAnchor.constraint(equalToConstant: 80).isActive = true
        rows.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let stack = NSStackView(views: [NSTextField(labelWithString: L10n.text(.columns)), columns, NSTextField(labelWithString: L10n.text(.rows)), rows])
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 30)
        let alert = NSAlert(); alert.messageText = L10n.text(.table); alert.accessoryView = stack
        alert.addButton(withTitle: L10n.text(.confirm)); alert.addButton(withTitle: L10n.text(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = document.editor.perform(.insertTable(columns: max(1, min(16, columns.integerValue)), rows: max(1, min(100, rows.integerValue))))
    }

    @objc func showFind(_ sender: NSMenuItem) {
        let item = NSMenuItem(); item.tag = sender.tag
        activeDocument?.editor.textView?.usesFindBar = true
        activeDocument?.editor.textView?.performFindPanelAction(item)
    }

    @objc func undo(_ sender: Any?) { if commerce.canEdit { activeDocument?.session.undoManager.undo() } }
    @objc func redo(_ sender: Any?) { if commerce.canEdit { activeDocument?.session.undoManager.redo() } }
    @objc func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { openDocument(url) } }
    @objc func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(sender) }

    func showError(_ error: Error) {
        let key: TextKey
        switch error as? DocumentStoreError {
        case .invalidName: key = .invalidName
        case .alreadyExists: key = .alreadyExists
        case .invalidImage: key = .invalidImage
        case .imageTooLarge: key = .imageTooLarge
        case .externalRemoteResource: key = .resourceWarning
        case .unsafePath: key = .unsafePath
        default: key = .operationFailed
        }
        let alert = NSAlert(); alert.messageText = L10n.text(.errorTitle); alert.informativeText = L10n.text(key); alert.runModal()
    }
}

@MainActor final class FormatBox: NSObject {
    let command: FormattingCommand
    init(_ command: FormattingCommand) { self.command = command }
}

@MainActor final class TableMenuContext: NSObject {
    weak var document: MarkdownDocument?
    let sourceRange: NSRange
    let command: FormattingCommand
    let source: String

    init(document: MarkdownDocument, sourceRange: NSRange, command: FormattingCommand) {
        self.document = document
        self.sourceRange = sourceRange
        self.command = command
        source = document.session.source
    }
}

@MainActor final class LinkMenuContext: NSObject {
    weak var document: MarkdownDocument?
    let link: MarkdownLinkContext
    let source: String

    init(document: MarkdownDocument, link: MarkdownLinkContext) {
        self.document = document
        self.link = link
        source = document.session.source
    }
}

@MainActor final class LinkInsertionForm: NSStackView {
    let displayTextField: NSTextField
    let addressField = NSTextField(string: "https://")

    convenience init(editor: MarkdownEditorController, link: MarkdownLinkContext?) {
        let textView = editor.textView!
        let selected = link?.displayText ?? (textView.string as NSString).substring(with: textView.selectedRange())
        self.init(displayText: selected, textLabel: L10n.text(.linkText), addressLabel: L10n.text(.linkAddress))
        addressField.stringValue = link?.destination ?? "https://"
    }

    init(displayText: String, textLabel: String, addressLabel: String) {
        displayTextField = NSTextField(string: displayText)
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 112))
        orientation = .vertical
        alignment = .leading
        spacing = 6
        widthAnchor.constraint(equalToConstant: 360).isActive = true
        for (title, field) in [(textLabel, displayTextField), (addressLabel, addressField)] {
            let label = NSTextField(labelWithString: title)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            field.setAccessibilityLabel(title)
            addArrangedSubview(label)
            addArrangedSubview(field)
            label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            field.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        displayTextField.nextKeyView = addressField
        frame.size.height = fittingSize.height
    }

    required init?(coder: NSCoder) { fatalError() }
}