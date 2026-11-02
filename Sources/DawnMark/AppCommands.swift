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
            BookmarkStore.remember(request.parent)
            BookmarkStore.remember(location.directoryURL)
        } catch { showError(error) }
    }

    @objc func open(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!, UTType(filenameExtension: "markdown")!]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openDocument(url) }
    }

    func openDocument(_ url: URL) {
        if let existing = NSDocumentController.shared.documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            existing.showWindows()
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let location = DocumentLocation(markdownURL: url)
            let document = displayDocument(location, source: try DocumentStore().read(location))
            document.retainAccess(to: url)
            if let directory = BookmarkStore.resolve(location.directoryURL) { document.retainAccess(to: directory) }
        } catch { showError(error) }
    }

    @discardableResult func displayDocument(_ location: DocumentLocation, source: String) -> MarkdownDocument {
        let document = MarkdownDocument(location: location, source: source, commerce: commerce)
        NSDocumentController.shared.addDocument(document)
        NSDocumentController.shared.noteNewRecentDocumentURL(location.markdownURL)
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
            BookmarkStore.remember(request.parent)
            BookmarkStore.remember(destination.directoryURL)
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
        let field = NSTextField(string: "https://")
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        let alert = NSAlert()
        alert.messageText = L10n.text(.linkAddress)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text(.confirm)); alert.addButton(withTitle: L10n.text(.cancel))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        _ = document.editor.perform(.insertLink(destination: field.stringValue))
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