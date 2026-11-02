import AppKit
@_exported import MarkdownEngine

@MainActor public final class MarkdownEditorController: NSViewController, NSTextViewDelegate {
    public let session: DocumentSession
    public private(set) var pendingStyles: Set<PendingFormattingStyle> = []
    private var pendingStyleSelection: NSRange?
    public private(set) var textView: MarkdownTextView!
    public let outlineSidebar = OutlineSidebar(frame: .zero)
    public var sourceUpdated: ((String) -> Void)?
    public var onImportImages: (([URL], Data?) -> Void)? { didSet { textView?.onImportImages = onImportImages } }
    public var imageProvider: ((String) -> NSImage?)? { didSet { imagesChanged = true; refresh() } }
    public var canEdit: Bool {
        get { session.canEdit }
        set { session.canEdit = newValue; textView?.isEditable = newValue }
    }
    public var mode: EditorMode {
        get { currentMode }
        set {
            guard newValue != currentMode else { return }
            if textView?.isComposing == true || textView?.hasMarkedText() == true { pendingMode = newValue; return }
            if isViewLoaded {
                session.selectedSourceRange = selectedSourceRange()
                modeViewportAnchor = captureViewportAnchor()
            }
            currentMode = newValue
            refresh()
        }
    }
    private var currentMode: EditorMode = .richText
    private var pendingMode: EditorMode?
    private struct ViewportAnchor {
        let sourceOffset: Int
        let lineFraction: CGFloat
        let atTop: Bool
    }
    private var modeViewportAnchor: ViewportAnchor?
    private var map: SourceMap?
    private var displayedSource = ""
    private var displayedMode: EditorMode?
    private var renderedSnapshotSource: String?
    private var imagesChanged = true
    private var applyingNativeEdit = false
    private var refreshing = false
    private var pendingRender = false
    private var compositionText: String?
    private var compositionSource: String?
    private var compositionMap: SourceMap?
    private var changeToken: UUID?
    private var renderToken: UUID?
    private var editabilityToken: UUID?

    public init(session: DocumentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        changeToken = session.observeChanges { [weak self] value in
            guard let self else { return }
            if !self.applyingNativeEdit { self.clearPendingStyles() }
            self.sourceUpdated?(value.source)
            self.textView?.isEditable = value.canEdit
            if !self.applyingNativeEdit { self.refresh() }
        }
        renderToken = session.observeRendering { [weak self] _ in self?.refresh() }
        editabilityToken = session.observeEditability { [weak self] value in
            guard let self else { return }
            if !value.canEdit { self.clearPendingStyles() }
            if !value.canEdit && self.textView?.isComposing == true { self.textView.cancelComposition() }
            self.textView?.isEditable = value.canEdit
            self.refresh()
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        let session = session
        let tokens = [changeToken, renderToken, editabilityToken].compactMap { $0 }
        Task { @MainActor in for token in tokens { session.removeObserver(token) } }
    }

    public override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let storage = NSTextStorage()
        let layout = TableLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let editor = MarkdownTextView(frame: .zero, textContainer: container)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isEditable = canEdit
        editor.documentSession = session
        editor.delegate = self
        editor.onImportImages = onImportImages
        editor.onCopyMarkdown = { [weak self] range in
            guard let self, self.mode == .richText, !self.textView.isComposing, !self.textView.hasMarkedText() else { return nil }
            if self.session.renderSnapshot?.source != self.session.source {
                self.session.renderNow()
                self.textView.setSelectedRange(range)
            }
            guard let snapshot = self.session.renderSnapshot else { return nil }
            return ClipboardMarkdown.extract(snapshot: snapshot, displayedRange: range)
        }
        editor.onPasteMarkdown = { [weak self] markdown in
            guard let self, self.mode == .richText else { return false }
            return self.structuralEdit {
                self.session.replaceSource(in: self.selectedSourceRange(), with: markdown)
            }
        }
        editor.editingAllowed = { [weak self] in self?.canEdit == true }
        editor.onCompositionStart = { [weak self] in self?.beginComposition() }
        editor.onCompositionEnd = { [weak self] in self?.endComposition() }
        editor.onToggleCheckbox = { [weak self] in self?.toggleCheckbox(atDisplayedOffset: $0) == true }
        editor.onListNewline = { [weak self] in
            guard let self, self.mode == .richText else { return false }
            return self.structuralEdit { self.session.continueList(in: self.selectedSourceRange()) }
        }
        editor.onListIndent = { [weak self] outdent in
            guard let self, self.mode == .richText else { return false }
            return self.structuralEdit {
                self.session.indentList(in: self.selectedSourceRange(), outdent: outdent)
            }
        }
        scroll.documentView = editor
        textView = editor
        let root = EditorSplitView(sidebar: outlineSidebar, editor: scroll)
        outlineSidebar.onNavigate = { [weak self] heading in self?.navigate(to: heading) }
        view = root
        editor.registerForDraggedTypes(editor.readablePasteboardTypes)
        refresh()
    }

    public func selectedSourceRange() -> NSRange {
        guard isViewLoaded else { return session.selectedSourceRange }
        let selection = textView.selectedRange()
        if mode == .richText, selection.length == 0,
           let decoration = map?.segments.last(where: { $0.kind == .decoration && NSMaxRange($0.displayedNSRange) == selection.location }),
           let first = (textView.string as NSString).substring(with: decoration.displayedNSRange).first,
           first == "\u{2022}" || first == "\u{2610}" || first == "\u{2611}" || first.isNumber {
            return NSRange(location: NSMaxRange(decoration.sourceNSRange), length: 0)
        }
        return mode == .source ? selection : map?.sourceRange(forDisplayedRange: selection) ?? session.selectedSourceRange
    }

    @discardableResult public func navigate(to heading: OutlineHeading) -> Bool {
        guard isViewLoaded, !textView.isComposing, !textView.hasMarkedText(),
              let snapshot = session.renderSnapshot, snapshot.source == session.source,
              snapshot.headings.contains(heading) else { return false }
        clearPendingStyles()
        let range = mode == .source ? heading.sourceRange : heading.displayedRange
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        session.selectedSourceRange = selectedSourceRange()
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
        outlineSidebar.selectHeading(atSourceOffset: heading.sourceRange.location)
        return true
    }

    @discardableResult public func insertMarkdown(_ markdown: String) -> Bool {
        guard canEdit, textView?.isComposing != true, textView?.hasMarkedText() != true else { return false }
        clearPendingStyles()
        return session.replaceSource(in: selectedSourceRange(), with: markdown)
    }

    public func formattingState(_ command: FormattingCommand) -> FormattingState {
        let selection = selectedSourceRange()
        let state = session.formattingState(command, in: selection)
        guard canEdit, state != .unavailable else { return .unavailable }
        if let style = PendingFormattingStyle(command: command), pendingStyleSelection == selection,
           pendingStyles.contains(style) { return .on }
        return state
    }

    @discardableResult public func perform(_ command: FormattingCommand) -> Bool {
        guard canEdit, textView?.isComposing != true, textView?.hasMarkedText() != true else { return false }
        let selection = selectedSourceRange()
        let state = session.formattingState(command, in: selection)
        guard state != .unavailable else { return false }
        if selection.length == 0, let style = PendingFormattingStyle(command: command) {
            if pendingStyleSelection != selection { clearPendingStyles() }
            if pendingStyles.contains(style) {
                pendingStyles.remove(style)
                if pendingStyles.isEmpty { pendingStyleSelection = nil }
                return true
            }
            if state != .on {
                if style == .inlineCode { clearPendingStyles() }
                else { pendingStyles.remove(.inlineCode) }
                pendingStyles.insert(style)
                pendingStyleSelection = selection
                return true
            }
        }
        clearPendingStyles()
        if mode == .richText, case .indent = command { return structuralEdit { session.indentList(in: selectedSourceRange(), outdent: false) } }
        return structuralEdit { session.perform(command, in: selectedSourceRange()) }
    }

    private func clearPendingStyles() {
        pendingStyles.removeAll()
        pendingStyleSelection = nil
    }

    private func applyPendingStyles(to text: String, in range: NSRange) -> Bool {
        guard !pendingStyles.isEmpty, pendingStyleSelection == range, range.length == 0,
              !text.isEmpty else { return false }
          guard !text.contains(where: { $0.isNewline }),
              let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace }) else {
            clearPendingStyles()
            return false
          }
        let styles = pendingStyles
          let content = String(text[first...last])
          let prefix = String(text[..<first])
          let suffix = String(text[text.index(after: last)...])
          let value = styles.contains(.inlineCode) ? content : SourceMap.escapeText(content)
        let insertion = DocumentSession(source: value)
        insertion.selectedSourceRange = NSRange(location: 0, length: value.utf16.count)
        for style in [PendingFormattingStyle.italic, .bold, .strikethrough, .inlineCode] where styles.contains(style) {
            guard insertion.perform(style.command) else { return false }
        }
        let replacement = prefix + insertion.source + suffix
        let caret = suffix.isEmpty ? prefix.utf16.count + NSMaxRange(insertion.selectedSourceRange) : replacement.utf16.count
        clearPendingStyles()
        return structuralEdit {
            session.apply([SourcePatch(range: range, replacement: replacement)], selectionAfter: NSRange(location: range.location + caret, length: 0))
        }
    }

    @discardableResult public func toggleCheckbox(atDisplayedOffset offset: Int) -> Bool {
        guard isViewLoaded, mode == .richText, displayedSource == session.source, let map,
              offset >= 0, offset < textView.string.utf16.count,
              let segment = map.segments.first(where: { $0.kind == .decoration && $0.displayedNSRange.location == offset }),
              [0x2610, 0x2611].contains((textView.string as NSString).character(at: offset)) else { return false }
        let raw = (session.source as NSString).substring(with: segment.sourceNSRange) as NSString
        let unchecked = raw.range(of: "[ ]")
        let checked = raw.range(of: "[x]", options: .caseInsensitive)
        let marker = unchecked.location != NSNotFound ? unchecked : checked
        guard marker.location != NSNotFound else { return false }
        return structuralEdit { session.toggleTaskCheckbox(atSourceOffset: segment.sourceNSRange.location + marker.location) }
    }

    private func structuralEdit(_ edit: () -> Bool) -> Bool {
        guard canEdit, textView?.isComposing != true, textView?.hasMarkedText() != true else { return false }
        applyingNativeEdit = true
        let accepted = edit()
        applyingNativeEdit = false
        if accepted { session.renderNow() }
        return accepted
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if self.textView.isCancellingComposition { return true }
        guard canEdit, !refreshing else { return false }
        if self.textView.isComposing || textView.hasMarkedText() { return true }
        guard let replacementString else { return false }
        let sourceRange = mode == .source ? affectedCharRange : map?.sourceRange(forDisplayedRange: affectedCharRange)
        if let sourceRange, applyPendingStyles(to: replacementString, in: sourceRange) { return false }
        session.selectedSourceRange = selectedSourceRange()
        let patches: [SourcePatch]
        if mode == .source { patches = [SourcePatch(range: affectedCharRange, replacement: replacementString)] }
        else {
            guard displayedSource == session.source, let map,
                  let result = map.patches(forDisplayedRange: affectedCharRange, replacement: replacementString, source: session.source) else { return false }
            patches = result
        }
        let deletingListMarker = mode == .richText && replacementString.isEmpty && map?.segments.contains(where: {
            $0.isListMarker && NSIntersectionRange($0.displayedNSRange, affectedCharRange).length > 0
        }) == true
        let insertingInsideListMarker = mode == .richText && affectedCharRange.length == 0 && !replacementString.isEmpty && map?.segments.contains(where: {
            $0.isListMarker && NSLocationInRange(affectedCharRange.location, $0.displayedNSRange)
        }) == true
                let insertingWhitespace = mode == .richText && !replacementString.isEmpty
                        && replacementString.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        applyingNativeEdit = true
        let accepted = session.apply(patches)
        applyingNativeEdit = false
        if accepted, deletingListMarker || insertingInsideListMarker || insertingWhitespace {
            session.renderNow()
            return false
        }
        if accepted, mode == .richText, let sourceRange,
           patches.first?.replacement != SourceMap.escapeText(replacementString)
            || patches.contains(where: { $0.range.length > 0 && NSIntersectionRange($0.range, sourceRange).length != $0.range.length }) {
            session.renderNow()
            textView.setSelectedRange(NSRange(location: min(affectedCharRange.location + replacementString.utf16.count, textView.string.utf16.count), length: 0))
            session.selectedSourceRange = selectedSourceRange()
            return false
        }
        if accepted {
            renderedSnapshotSource = nil
            if mode == .richText { map = map?.replacing(displayed: affectedCharRange, with: replacementString, patches: patches) }
            displayedSource = session.source
        }
        return accepted
    }

    public func textDidChange(_ notification: Notification) {
        guard !refreshing, !textView.isComposing, !textView.hasMarkedText() else { return }
        session.selectedSourceRange = selectedSourceRange()
        if pendingRender { refresh() }
    }
    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !refreshing, !textView.isComposing else { return }
        session.selectedSourceRange = selectedSourceRange()
        if pendingStyleSelection != session.selectedSourceRange { clearPendingStyles() }
        outlineSidebar.selectHeading(atSourceOffset: session.selectedSourceRange.location)
    }
    public func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard affectedRanges.count == 1, let replacement = replacementStrings?.first else { return false }
        return self.textView(textView, shouldChangeTextIn: affectedRanges[0].rangeValue, replacementString: replacement)
    }

    private func applyCheckboxUpdate(_ result: NSAttributedString) -> Bool {
        let previousSource = displayedSource as NSString
        let updatedSource = session.source as NSString
        guard previousSource.length == updatedSource.length,
              let sourceChange = zip(displayedSource.utf16, session.source.utf16).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset,
              sourceChange > 0, sourceChange + 1 < updatedSource.length,
              previousSource.character(at: sourceChange - 1) == 91,
              previousSource.character(at: sourceChange + 1) == 93,
              [32, 88, 120].contains(previousSource.character(at: sourceChange)),
              [32, 88, 120].contains(updatedSource.character(at: sourceChange)) else { return false }
        let sourceRange = NSRange(location: sourceChange, length: 1)
        guard updatedSource.replacingCharacters(in: sourceRange, with: previousSource.substring(with: sourceRange)) == displayedSource else { return false }
        guard let storage = textView.textStorage, storage.length == result.length,
              let changed = zip(storage.string.utf16, result.string.utf16).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset,
              storage.attribute(.markdownCheckbox, at: changed, effectiveRange: nil) != nil,
              result.attribute(.markdownCheckbox, at: changed, effectiveRange: nil) != nil else { return false }
        let range = NSRange(location: changed, length: 1)
        let previous = storage.string as NSString
        let updated = result.string as NSString
        guard updated.replacingCharacters(in: range, with: previous.substring(with: range)) == storage.string else { return false }
        storage.replaceCharacters(in: range, with: result.attributedSubstring(from: range))
        return true
    }

    private func captureViewportAnchor() -> ViewportAnchor? {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView, !textView.string.isEmpty else { return nil }
        let point = NSPoint(x: container.lineFragmentPadding, y: max(0, clip.bounds.minY - textView.textContainerOrigin.y))
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let character = layout.characterIndexForGlyph(at: lineGlyphs.location)
        let range = NSRange(location: character, length: 0)
        let source = displayedMode == .source ? range : map?.sourceRange(forDisplayedRange: range) ?? range
        return ViewportAnchor(sourceOffset: source.location, lineFraction: (clip.bounds.minY - textView.textContainerOrigin.y - rect.minY) / max(1, rect.height), atTop: clip.bounds.minY <= 0)
    }

    private func restoreViewportAnchor(_ anchor: ViewportAnchor) {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              let scroll = textView.enclosingScrollView, !textView.string.isEmpty else { return }
        let source = NSRange(location: min(anchor.sourceOffset, session.source.utf16.count), length: 0)
        let displayed = displayedMode == .source ? source : map?.displayedRange(forSourceRange: source) ?? source
        layout.ensureLayout(for: container)
        textView.sizeToFit()
        let character = min(displayed.location, textView.string.utf16.count - 1)
        let glyph = layout.glyphIndexForCharacter(at: character)
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let clip = scroll.contentView
        let proposed = anchor.atTop ? 0 : rect.minY + textView.textContainerOrigin.y + anchor.lineFraction * rect.height
        let maximum = max(0, textView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maximum, max(0, proposed))))
        scroll.reflectScrolledClipView(clip)
    }

    private func refresh() {
        guard isViewLoaded else { return }
        guard !textView.isComposing, !textView.hasMarkedText(), !applyingNativeEdit else { pendingRender = true; return }
        let selection = session.selectedSourceRange
        refreshing = true
        defer { refreshing = false }
        textView.isEditable = canEdit
        textView.isRichText = mode == .richText
        if let snapshot = session.renderSnapshot, snapshot.source == session.source {
            outlineSidebar.update(headings: snapshot.headings)
            outlineSidebar.selectHeading(atSourceOffset: selection.location)
        }
        if mode == .source {
            if displayedSource != session.source || displayedMode != .source {
                textView.textStorage?.setAttributedString(NSAttributedString(string: session.source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: Typography.source, weight: .regular), .foregroundColor: NSColor.textColor]))
            }
            map = nil
            displayedSource = session.source
            displayedMode = .source
            textView.setSelectedRange(selection)
            pendingRender = false
        } else if let snapshot = session.renderSnapshot, snapshot.source == session.source {
            if renderedSnapshotSource != snapshot.source || displayedMode != .richText || imagesChanged {
                let result = MarkdownRenderer.render(snapshot: snapshot, imageProvider: imageProvider)
                if displayedMode != .richText || imagesChanged || !applyCheckboxUpdate(result.attributedString) {
                    textView.textStorage?.setAttributedString(result.attributedString)
                }
                map = result.sourceMap
                renderedSnapshotSource = snapshot.source
                imagesChanged = false
            }
            displayedSource = snapshot.source
            displayedMode = .richText
            let displayedSelection = snapshot.sourceMap.displayedRange(forSourceRange: selection)
            if textView.selectedRange() != displayedSelection { textView.setSelectedRange(displayedSelection) }
            pendingRender = false
        } else {
            pendingRender = true
            if displayedSource != session.source || displayedMode != .richText {
                textView.textStorage?.setAttributedString(NSAttributedString(string: session.source, attributes: [.font: NSFont.systemFont(ofSize: Typography.body)]))
                let length = session.source.utf16.count
                map = SourceMap(segments: [MappingSegment(displayedNSRange: NSRange(location: 0, length: length), sourceNSRange: NSRange(location: 0, length: length), kind: .text, isIdentity: true)], sourceLength: length, displayedLength: length)
                displayedSource = session.source
                displayedMode = .richText
                renderedSnapshotSource = nil
                textView.setSelectedRange(selection)
            }
        }
        textView.updateTableLayout()
        textView.updateImageLayout()
        if !pendingRender, let anchor = modeViewportAnchor {
            restoreViewportAnchor(anchor)
            modeViewportAnchor = nil
        }
        textView.window?.invalidateCursorRects(for: textView)
        textView.typingAttributes = [.font: mode == .source ? NSFont.monospacedSystemFont(ofSize: Typography.source, weight: .regular) : NSFont.systemFont(ofSize: Typography.body), .foregroundColor: NSColor.textColor]
    }

    private func beginComposition() {
        compositionText = textView.string
        compositionSource = session.source
        compositionMap = map
    }
    private func endComposition() {
        guard let before = compositionText, let originalSource = compositionSource else { return }
        compositionText = nil; compositionSource = nil
        let after = textView.string
        let oldCharacters = Array(before)
        let newCharacters = Array(after)
        var prefix = 0
        while prefix < min(oldCharacters.count, newCharacters.count), oldCharacters[prefix] == newCharacters[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldCharacters.count, newCharacters.count) - prefix,
              oldCharacters[oldCharacters.count - suffix - 1] == newCharacters[newCharacters.count - suffix - 1] { suffix += 1 }
        let start = String(oldCharacters.prefix(prefix)).utf16.count
        let deleted = String(oldCharacters[prefix..<(oldCharacters.count - suffix)]).utf16.count
        let replacement = String(newCharacters[prefix..<(newCharacters.count - suffix)])
        let affected = NSRange(location: start, length: deleted)
        if originalSource == session.source && canEdit {
            let sourceRange = mode == .source ? affected : compositionMap?.sourceRange(forDisplayedRange: affected)
            let appliedPending = sourceRange.map { applyPendingStyles(to: replacement, in: $0) } ?? false
            let patches = mode == .source ? [SourcePatch(range: affected, replacement: replacement)] : compositionMap?.patches(forDisplayedRange: affected, replacement: replacement, source: originalSource)
            if !appliedPending, let patches {
                applyingNativeEdit = true
                if session.apply(patches) {
                    renderedSnapshotSource = nil
                    map = compositionMap?.replacing(displayed: affected, with: replacement, patches: patches)
                    displayedSource = session.source
                    session.selectedSourceRange = selectedSourceRange()
                }
                applyingNativeEdit = false
            }
        }
        compositionMap = nil
        if let mode = pendingMode { pendingMode = nil; self.mode = mode }
        refresh()
    }
}