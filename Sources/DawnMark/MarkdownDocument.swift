import AppKit
import CommerceCore
import DawnMarkSupport
import DocumentWorkspace
import EditorKit
import ImageIO

@MainActor final class MarkdownDocument: NSDocument, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private static let horizontalRuleItem = NSToolbarItem.Identifier("DawnMark.InsertHorizontalRule")
    let session: DocumentSession
    let commerce: CommerceController
    let editor: MarkdownEditorController
    private let status = NSTextField(labelWithString: "")
    private var scopes: [URL] = []
    private let cachedImages = NSCache<NSString, NSImage>()
    private var displayedImages: [String: WeakImage] = [:]
    private var loadingImages: Set<String> = []
    private var unavailableImages: Set<String> = []
    private var savedSource: String
    var location: DocumentLocation { DocumentLocation(markdownURL: fileURL!) }

    init(location: DocumentLocation, source: String, commerce: CommerceController) {
        self.commerce = commerce
        self.session = DocumentSession(source: source)
        self.editor = MarkdownEditorController(session: session)
        self.savedSource = source
        super.init()
        cachedImages.totalCostLimit = 24 * 1024 * 1024
        cachedImages.countLimit = 24
        fileURL = location.markdownURL
        fileType = "net.daringfireball.markdown"
        editor.mode = UserDefaults.standard.string(forKey: "defaultMode") == "source" ? .source : .richText
        editor.canEdit = commerce.canEdit
        editor.sourceUpdated = { [weak self] _ in
            guard let self else { return }
            self.updateChangeCount(.changeDone)
            self.updateStatus()
        }
        editor.imageProvider = { [weak self] path in self?.image(path: path) }
        editor.onImportImages = { [weak self] urls, data in self?.importImages(urls: urls, data: data) }
        updateOutlineLocalization()
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        window.delegate = self
        let root = NSView()
        let editorView = editor.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        root.addSubview(editorView)
        root.addSubview(status)
        NSLayoutConstraint.activate([
            editorView.leadingAnchor.constraint(equalTo: root.leadingAnchor), editorView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: root.topAnchor), editorView.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6), status.heightAnchor.constraint(equalToConstant: 16)
        ])
        window.contentView = root
        let toolbar = NSToolbar(identifier: "DawnMark.Editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        let controller = NSWindowController(window: window)
        addWindowController(controller)
        applyPreferences()
        updateStatus()
        window.makeFirstResponder(editor.textView)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.horizontalRuleItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.horizontalRuleItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.horizontalRuleItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = L10n.text(.rule)
        item.paletteLabel = item.label
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: "minus", accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(insertHorizontalRule(_:))
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        editor.canEdit && editor.textView?.isComposing != true && editor.textView?.hasMarkedText() != true
    }

    @objc private func insertHorizontalRule(_ sender: Any?) {
        guard editor.perform(.horizontalRule) else { return }
        windowControllers.first?.window?.makeFirstResponder(editor.textView)
    }

    override func data(ofType typeName: String) throws -> Data { Data(session.source.utf8) }

    override func write(to url: URL, ofType typeName: String) throws {
        let snapshot = onMain { self.session.source }
        try Data(snapshot.utf8).write(to: url, options: .atomic)
        onMain {
            self.savedSource = snapshot
            self.updateStatus()
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let source = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        onMain {
            let wasEditable = self.session.canEdit
            self.session.canEdit = true
            _ = self.session.replaceSource(in: NSRange(location: 0, length: self.session.source.utf16.count), with: source)
            self.session.undoManager.removeAllActions()
            self.session.canEdit = wasEditable
            self.savedSource = source
            self.updateChangeCount(.changeCleared)
        }
    }

    override var undoManager: UndoManager? {
        get { session.undoManager }
        set {}
    }

    func updateAccess() {
        editor.canEdit = commerce.canEdit
        updateStatus()
    }

    func updateOutlineLocalization() {
        editor.outlineSidebar.title = L10n.text(.outline)
        editor.outlineSidebar.untitledHeading = L10n.text(.untitledHeading)
    }

    func applyPreferences() {
        editor.textView?.isContinuousSpellCheckingEnabled = UserDefaults.standard.bool(forKey: "spellcheck")
        updateStatus()
    }

    func updateStatus() {
        status.stringValue = L10n.format(.documentStatus, fileURL?.lastPathComponent ?? "DawnMark", commerce.canEdit ? (session.source == savedSource ? "" : L10n.text(.edited)) : L10n.text(.readonly))
    }

    func retainAccess(to url: URL) {
        if url.startAccessingSecurityScopedResource() { scopes.append(url) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }

    func confirmClose() -> Bool {
        guard session.source != savedSource else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.text(.unsavedChanges)
        alert.addButton(withTitle: L10n.text(.saveChanges))
        alert.addButton(withTitle: L10n.text(.cancel))
        alert.addButton(withTitle: L10n.text(.discard))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do { try DocumentStore().save(session.source, to: location); savedSource = session.source; updateChangeCount(.changeCleared); return true }
            catch { (NSApp.delegate as? AppDelegate)?.showError(error); return false }
        case .alertThirdButtonReturn:
            savedSource = session.source
            updateChangeCount(.changeCleared)
            return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        for url in scopes { url.stopAccessingSecurityScopedResource() }
        scopes.removeAll()
        close()
    }

    func authorizeDirectory() -> Bool {
        let directory = location.directoryURL
        if FileManager.default.isWritableFile(atPath: directory.path),
           (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) != nil { return true }
        if let url = BookmarkStore.resolve(directory) {
            retainAccess(to: url)
            if FileManager.default.isWritableFile(atPath: directory.path) { return true }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = directory
        panel.message = L10n.text(.folderPermission)
        panel.prompt = L10n.text(.authorizeFolder)
        guard panel.runModal() == .OK, let selected = panel.url,
              selected.standardizedFileURL == directory.standardizedFileURL else { return false }
        retainAccess(to: selected)
        BookmarkStore.remember(selected)
        return true
    }

    func importImages(urls: [URL], data: Data?) {
        guard commerce.canEdit, authorizeDirectory() else { return }
        let selection = editor.selectedSourceRange()
        let anchor = SourceAnchor(session: session, range: selection)
        for url in urls { retainAccess(to: url) }
        Task { [weak self] in
            defer { anchor.stop() }
            do {
                let payloads = try await Task.detached(priority: .userInitiated) {
                    if !urls.isEmpty { return try urls.map { try Data(contentsOf: $0, options: .mappedIfSafe) } }
                    return data.map { [$0] } ?? []
                }.value
                guard let self, self.commerce.canEdit, self.windowControllers.contains(where: { $0.window?.isVisible == true }) else { return }
                guard anchor.range != nil else { self.showImportCancelled(); return }
                let location = self.location
                let images = try await Task.detached(priority: .userInitiated) {
                    try payloads.map { try DocumentStore().importImage(data: $0, into: location) }
                }.value
                guard self.commerce.canEdit, self.windowControllers.contains(where: { $0.window?.isVisible == true }) else { return }
                guard let range = anchor.range else { self.showImportCancelled(); return }
                _ = self.session.replaceSource(in: range, with: images.map(\.markdown).joined(separator: "\n"))
            } catch { (NSApp.delegate as? AppDelegate)?.showError(error) }
        }
    }

    private func image(path: String) -> NSImage? {
        if let image = cachedImages.object(forKey: path as NSString) { return image }
        if let image = displayedImages[path]?.value { return image }
        guard !loadingImages.contains(path), !unavailableImages.contains(path),
              let decoded = path.removingPercentEncoding,
              let url = try? location.resourceURL(relativePath: decoded) else { return nil }
        loadingImages.insert(path)
        Task { [weak self] in
            let thumbnail = await ThumbnailDecoder.shared.decode(url)
            guard let self else { return }
            self.loadingImages.remove(path)
            guard let thumbnail else { self.unavailableImages.insert(path); return }
            let scale = min(1, 720 / CGFloat(thumbnail.width))
            let image = NSImage(cgImage: thumbnail, size: NSSize(width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale))
            self.cachedImages.setObject(image, forKey: path as NSString, cost: thumbnail.bytesPerRow * thumbnail.height)
            self.displayedImages[path] = WeakImage(image)
            self.editor.imageProvider = { [weak self] path in self?.image(path: path) }
        }
        return nil
    }

    private func showImportCancelled() {
        let alert = NSAlert()
        alert.messageText = L10n.text(.imageImportCancelled)
        alert.runModal()
    }
}

private actor ThumbnailDecoder {
    static let shared = ThumbnailDecoder()

    func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }
}

@MainActor private final class WeakImage {
    weak var value: NSImage?
    init(_ image: NSImage) { value = image }
}

private nonisolated func onMain<Value: Sendable>(_ action: @MainActor @Sendable () -> Value) -> Value {
    if Thread.isMainThread { return MainActor.assumeIsolated(action) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(action) }
}

@MainActor enum BookmarkStore {
    static func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var bookmarks = UserDefaults.standard.dictionary(forKey: "directoryBookmarks") as? [String: Data] ?? [:]
        bookmarks[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(bookmarks, forKey: "directoryBookmarks")
    }

    static func resolve(_ url: URL) -> URL? {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: "directoryBookmarks") as? [String: Data],
              let data = bookmarks[url.standardizedFileURL.path] else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { remember(resolved) }
        return resolved
    }
}