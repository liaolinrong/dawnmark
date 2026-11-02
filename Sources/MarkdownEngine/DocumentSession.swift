import AppKit

@MainActor public final class DocumentSession {
    public private(set) var source: String
    public private(set) var revision: UInt64 = 0
    public let undoManager: UndoManager
    public var canEdit = true {
        didSet {
            guard canEdit != oldValue else { return }
            for handler in Array(editabilityObservers.values) { handler(self) }
        }
    }
    public var selectedSourceRange = NSRange(location: 0, length: 0)
    public var onChange: ((DocumentSession) -> Void)?
    public var onRender: ((DocumentSession) -> Void)?
    public private(set) var renderSnapshot: RenderSnapshot?
    public var sourceMap: SourceMap? { renderSnapshot?.sourceMap }
    public var debounceNanoseconds: UInt64 = 40_000_000
    private var parseTask: Task<Void, Never>?
    private var observers: [UUID: (DocumentSession) -> Void] = [:]
    private var renderObservers: [UUID: (DocumentSession) -> Void] = [:]
    private var editabilityObservers: [UUID: (DocumentSession) -> Void] = [:]

    public init(source: String = "", undoManager: UndoManager = UndoManager()) {
        self.source = source
        self.undoManager = undoManager
        scheduleParse()
    }

    @discardableResult public func observeChanges(_ handler: @escaping (DocumentSession) -> Void) -> UUID {
        let token = UUID(); observers[token] = handler; return token
    }
    @discardableResult public func observeRendering(_ handler: @escaping (DocumentSession) -> Void) -> UUID {
        let token = UUID(); renderObservers[token] = handler; return token
    }
    @discardableResult public func observeEditability(_ handler: @escaping (DocumentSession) -> Void) -> UUID {
        let token = UUID(); editabilityObservers[token] = handler; return token
    }
    public func removeObserver(_ token: UUID) { observers[token] = nil; renderObservers[token] = nil; editabilityObservers[token] = nil }

    deinit { parseTask?.cancel() }

    @discardableResult public func replaceSource(in range: NSRange, with replacement: String) -> Bool {
        apply([SourcePatch(range: range, replacement: replacement)])
    }

    @discardableResult public func apply(_ patches: [SourcePatch], selectionAfter: NSRange? = nil) -> Bool {
        guard canEdit, !patches.isEmpty else { return false }
        let sorted = patches.sorted { $0.range.location < $1.range.location }
        var previousEnd = 0
        for patch in sorted {
            guard patch.range.location >= previousEnd, Range(patch.range, in: source) != nil else { return false }
            previousEnd = NSMaxRange(patch.range)
        }
        guard perform(sorted) else { return true }
        selectedSourceRange = selectionAfter ?? NSRange(location: sorted[0].range.location + sorted[0].replacement.utf16.count, length: 0)
        clampSelection()
        changed()
        return true
    }

    /// Applies sorted, non-overlapping patches and registers only their inverse for undo.
    private func perform(_ sorted: [SourcePatch]) -> Bool {
        let buffer = NSMutableString(string: source)
        var inverse: [SourcePatch] = []
        var delta = 0
        for patch in sorted {
            let removed = buffer.substring(with: NSRange(location: patch.range.location + delta, length: patch.range.length))
            guard removed != patch.replacement else { continue }
            let length = patch.replacement.utf16.count
            inverse.append(SourcePatch(range: NSRange(location: patch.range.location + delta, length: length), replacement: removed))
            buffer.replaceCharacters(in: NSRange(location: patch.range.location + delta, length: patch.range.length), with: patch.replacement)
            delta += length - patch.range.length
        }
        guard !inverse.isEmpty else { return false }
        let previousSelection = selectedSourceRange
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.revert(inverse, selection: previousSelection) }
        }
        var next = buffer as String
        // Bridged NSString storage makes UTF-8/Character access in the renderer quadratic.
        next.makeContiguousUTF8()
        source = next
        return true
    }

    @discardableResult public func editRendered(range: NSRange, replacement: String) -> Bool {
        guard let snapshot = renderSnapshot, snapshot.source == source,
              let patches = snapshot.sourceMap.patches(forDisplayedRange: range, replacement: replacement, source: source) else { return false }
        return apply(patches)
    }

    public func renderNow() {
        parseTask?.cancel()
        accept(MarkdownRenderer.snapshot(source: source), revision: revision)
    }

    public func waitForRendering() async { await parseTask?.value }

    private func revert(_ inverse: [SourcePatch], selection: NSRange) {
        guard canEdit, perform(inverse) else { return }
        selectedSourceRange = selection; clampSelection(); changed()
    }
    private func clampSelection() {
        let start = min(max(0, selectedSourceRange.location), source.utf16.count)
        selectedSourceRange = NSRange(location: start, length: min(selectedSourceRange.length, source.utf16.count - start))
    }
    private func changed() {
        revision &+= 1
        scheduleParse()
        onChange?(self)
        for handler in Array(observers.values) { handler(self) }
    }
    private func scheduleParse() {
        parseTask?.cancel()
        let value = source
        let generation = revision
        let delay = debounceNanoseconds
        parseTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) { MarkdownRenderer.snapshot(source: value) }.value
            guard !Task.isCancelled else { return }
            self?.accept(snapshot, revision: generation)
        }
    }
    private func accept(_ snapshot: RenderSnapshot, revision generation: UInt64) {
        guard generation == revision, snapshot.source == source else { return }
        renderSnapshot = snapshot
        onRender?(self)
        for handler in Array(renderObservers.values) { handler(self) }
    }
}