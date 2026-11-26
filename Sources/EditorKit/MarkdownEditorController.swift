import AppKit
@_exported import MarkdownEngine

@MainActor public final class MarkdownEditorController: NSViewController, NSTextViewDelegate {
    public let session: DocumentSession
    public private(set) var pendingStyles: Set<PendingFormattingStyle> = []
    private var pendingStyleSelection: NSRange?
    public private(set) var textView: MarkdownTextView!
    public let outlineSidebar = OutlineSidebar(frame: .zero)
    public var sourceUpdated: ((String) -> Void)?
    public var linkMenu: ((MarkdownLinkContext) -> NSMenu?)?
    public var tableMenu: ((NSRange) -> NSMenu?)?
    public var codeBlockMenu: ((CodeBlockSnapshot) -> NSMenu?)?
    public var codeLanguagePickerLabels: (() -> (title: String, noLanguage: String))? {
        didSet { updateCodeLanguagePicker() }
    }
    let codeLanguagePicker = CodeLanguagePicker(frame: .zero)
    public static var codeBlockLanguages: [(label: String, title: String)] {
        CodeLanguage.allCases.map { ($0.rawValue, $0.displayName) }.sorted { $0.title < $1.title }
    }

    public var currentCodeBlock: CodeBlockSnapshot? {
        guard isViewLoaded, mode == .richText, !textView.isComposing, !textView.hasMarkedText() else { return nil }
        let selection = textView.selectedRange()
        guard let block = session.codeBlock(atDisplayedOffset: selection.location),
              NSMaxRange(selection) <= NSMaxRange(block.range) else { return nil }
        return block
    }
    public var onImportImages: (([URL], Data?) -> Void)? { didSet { textView?.onImportImages = onImportImages } }
    public var imageProvider: ((String) -> NSImage?)? {
        didSet {
            if isViewLoaded, mode == .richText, modeViewportAnchor == nil {
                modeViewportAnchor = captureViewportAnchor()
            }
            imagesChanged = true
            refresh()
        }
    }
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
            if newValue == .richText, session.renderSnapshot?.source != session.source {
                session.renderNow()
            } else {
                refresh()
            }
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
    private let codeHighlighter = CodeHighlighter()
    private var codeHighlightTask: Task<Void, Never>?
    private var codeHighlightRevision: UInt64 = 0
    private var scheduledHighlightSource: String?
    private var hasCodeColors = false
    private struct ColoredBlock: Hashable {
        let language: CodeLanguage
        let text: Data
    }
    private var blockColors: [ColoredBlock: [CodeHighlight]] = [:]
    private var pendingCodeColorEdit: (text: String, range: NSRange, language: String, colors: [CodeHighlight])?
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
            self.invalidateCodeHighlightTask()
            if !self.applyingNativeEdit { self.clearPendingStyles() }
            self.sourceUpdated?(value.source)
            self.textView?.isEditable = value.canEdit
            if !self.applyingNativeEdit {
                if self.mode == .richText, value.undoManager.isUndoing || value.undoManager.isRedoing {
                    value.renderNow()
                } else {
                    self.refresh()
                }
            }
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
        codeHighlightTask?.cancel()
        let session = session
        let tokens = [changeToken, renderToken, editabilityToken].compactMap { $0 }
        Task { @MainActor in for token in tokens { session.removeObserver(token) } }
    }

    public override func loadView() {
        let scroll = NSScrollView()
        scroll.contentView = EditorClipView()
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
            return self.structuralEdit {
                self.insertNewlineAfterCodeBlock() || self.insertNewlineBeforeBlock() || self.session.continueList(in: self.selectedSourceRange())
            }
        }
        editor.onListIndent = { [weak self] outdent in
            guard let self, self.mode == .richText else { return false }
            return self.structuralEdit {
                self.session.indentList(in: self.selectedSourceRange(), outdent: outdent)
            }
        }
        editor.onLinkMenu = { [weak self] offset in
            guard let self, let link = self.link(atDisplayedOffset: offset) else { return nil }
            return self.linkMenu?(link)
        }
        editor.onCodeBlockMenu = { [weak self] offset in
            guard let self, self.mode == .richText, let block = self.session.codeBlock(atDisplayedOffset: offset) else { return nil }
            return self.codeBlockMenu?(block)
        }
        editor.onTableMenu = { [weak self] offset in
            guard let self, self.displayedSource == self.session.source,
                  offset >= 0, offset < self.textView.string.utf16.count else { return nil }
            let range = NSRange(location: offset, length: 0)
            guard let sourceRange = self.mode == .source ? range : self.map?.sourceRange(forDisplayedRange: range),
                  self.session.tableRange(in: sourceRange) != nil else { return nil }
            return self.tableMenu?(sourceRange)
        }
        scroll.documentView = editor
        textView = editor
        codeLanguagePicker.isHidden = true
        codeLanguagePicker.onCommit = { [weak self] picker in self?.changeCodeLanguage(picker) }
        editor.codeLanguagePicker = codeLanguagePicker
        editor.addSubview(codeLanguagePicker)
        let root = EditorSplitView(sidebar: outlineSidebar, editor: scroll)
        outlineSidebar.onNavigate = { [weak self] heading in self?.navigate(to: heading) }
        view = root
        editor.registerForDraggedTypes(editor.readablePasteboardTypes)
        refresh()
    }

    public var currentLink: MarkdownLinkContext? {
        guard textView?.isComposing != true, textView?.hasMarkedText() != true else { return nil }
        return session.link(in: selectedSourceRange())
    }

    public func link(atDisplayedOffset offset: Int) -> MarkdownLinkContext? {
        guard isViewLoaded, !textView.isComposing, !textView.hasMarkedText(),
              displayedSource == session.source, offset >= 0, offset < textView.string.utf16.count else { return nil }
        let range = NSRange(location: offset, length: 1)
        let sourceRange = mode == .source ? range : map?.sourceRange(forDisplayedRange: range)
        return sourceRange.flatMap { session.link(in: $0) }
    }

    @discardableResult public func updateLink(in range: NSRange, destination: String, label: String?) -> Bool {
        structuralEdit { session.perform(.insertLink(destination: destination, label: label), in: range) }
    }

    @discardableResult public func removeLink(in range: NSRange) -> Bool {
        structuralEdit { session.removeLink(in: range) }
    }

    @discardableResult public func insertCodeBlock(language: String) -> Bool {
        session.selectedSourceRange = selectedSourceRange()
        return structuralEdit { session.insertCodeBlock(language: language, in: session.selectedSourceRange) }
    }

    @discardableResult public func setCodeBlockLanguage(_ language: String, in block: CodeBlockSnapshot) -> Bool {
        session.selectedSourceRange = selectedSourceRange()
        return structuralEdit { session.setCodeBlockLanguage(language, in: block) }
    }

    private func updateCodeLanguagePicker() {
        guard isViewLoaded else { return }
        guard canEdit, mode == .richText, !textView.isComposing, !textView.hasMarkedText(),
              let labels = codeLanguagePickerLabels?() else {
            textView.positionCodeLanguagePicker(at: nil)
            return
        }
        guard let block = currentCodeBlock else {
            if displayedSource == session.source, session.renderSnapshot?.source != session.source,
               textView.keepCodeLanguagePicker(for: textView.selectedRange()) { return }
            textView.positionCodeLanguagePicker(at: nil)
            return
        }
        let original = (session.source as NSString).substring(with: block.languageSourceRange)
        if codeLanguagePicker.input.currentEditor() == nil {
            codeLanguagePicker.configure(original: original, hasAdditionalInfo: block.hasAdditionalInfo,
                                         title: labels.title, noLanguage: labels.noLanguage)
        }
        textView.positionCodeLanguagePicker(at: block.range.length > 0 ? block.range.location : nil)
    }

    private func changeCodeLanguage(_ sender: CodeLanguagePicker) {
        if canEdit, let block = currentCodeBlock {
            let original = (session.source as NSString).substring(with: block.languageSourceRange)
            let language = sender.language
            if language != original, !setCodeBlockLanguage(language, in: block) { NSSound.beep() }
        }
        textView.window?.makeFirstResponder(textView)
        updateCodeLanguagePicker()
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

    @discardableResult public func insertMarkdown(_ markdown: String, in range: NSRange? = nil) -> Bool {
        guard canEdit, textView?.isComposing != true, textView?.hasMarkedText() != true else { return false }
        clearPendingStyles()
        return structuralEdit { session.replaceSource(in: range ?? selectedSourceRange(), with: markdown) }
    }

    public func formattingState(_ command: FormattingCommand) -> FormattingState {
        guard textView?.isComposing != true, textView?.hasMarkedText() != true else { return .unavailable }
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

    @discardableResult public func perform(_ command: FormattingCommand, inSourceRange range: NSRange) -> Bool {
        guard canEdit, textView?.isComposing != true, textView?.hasMarkedText() != true else { return false }
        clearPendingStyles()
        return structuralEdit { session.perform(command, in: range) }
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

    private func insertNewlineAfterCodeBlock() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        guard let snapshot = session.renderSnapshot, snapshot.source == session.source,
              let block = snapshot.codeBlocks.first(where: { $0.range.length > 0 && NSMaxRange($0.range) == selection.location }),
              let end = block.closingFenceEnd else { return false }
        let source = session.source
        let newline = source.contains("\r\n") ? "\r\n" : source.contains("\r") && !source.contains("\n") ? "\r" : "\n"
        session.selectedSourceRange = NSRange(location: end, length: 0)
        return session.apply([SourcePatch(range: session.selectedSourceRange, replacement: newline)],
                     selectionAfter: NSRange(location: end + newline.utf16.count, length: 0))
    }

    private func insertNewlineBeforeBlock() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        if session.renderSnapshot?.source != session.source { session.renderNow() }
        guard let snapshot = session.renderSnapshot else { return false }
        let start: Int
        if let heading = snapshot.headings.first(where: { $0.displayedRange.length > 0 && $0.displayedRange.location == selection.location }) {
            start = heading.sourceRange.location
        } else if let rule = snapshot.sourceMap.segments.first(where: { $0.kind == .attachment && $0.displayedNSRange.location == selection.location }),
                  snapshot.runs.contains(where: { $0.style.contains(.horizontalRule) && $0.range.location == selection.location }) {
            start = rule.sourceNSRange.location
        } else { return false }
        let source = session.source
        let original = source as NSString
        let line = original.lineRange(for: NSRange(location: start, length: 0))
        let prefix = original.substring(with: NSRange(location: line.location, length: start - line.location))
        guard prefix.allSatisfy({ $0 == " " || $0 == "\t" || $0 == ">" }) else { return false }
        let newline = source.contains("\r\n") ? "\r\n" : source.contains("\r") && !source.contains("\n") ? "\r" : "\n"
        let insertion = prefix + newline
        let caret = snapshot.sourceMap.sourceOffset(forDisplayedOffset: selection.location)
        return session.apply([SourcePatch(range: NSRange(location: line.location, length: 0), replacement: insertion)],
                     selectionAfter: NSRange(location: caret + insertion.utf16.count, length: 0))
    }

    private func structuralEdit(_ edit: () -> Bool) -> Bool {
        guard canEdit, textView?.isComposing != true, textView?.hasMarkedText() != true else { return false }
        applyingNativeEdit = true
        let accepted = edit()
        applyingNativeEdit = false
        if accepted { session.renderNow() }
        return accepted
    }

    private enum RuleBoundary { case unaffected, converted([SourcePatch]), blocked }

    private func ruleBoundary(deleting range: NSRange, patches: [SourcePatch]) -> RuleBoundary {
        guard mode == .richText, range.length > 0,
              textView.selectedRange() == NSRange(location: NSMaxRange(range), length: 0),
              let snapshot = session.renderSnapshot, snapshot.source == session.source,
              let rule = snapshot.runs.first(where: { $0.style.contains(.horizontalRule) && $0.range.location >= NSMaxRange(range) }) else { return .unaffected }
        let gap = NSRange(location: range.location, length: rule.range.location - range.location)
        guard (textView.string as NSString).substring(with: gap).allSatisfy({ $0.isWhitespace }) else { return .unaffected }
        let originalOffset = snapshot.sourceMap.sourceOffset(forDisplayedOffset: rule.range.location)
        let offset = patches.filter { NSMaxRange($0.range) <= originalOffset }.reduce(originalOffset) {
            $0 + $1.replacement.utf16.count - $1.range.length
        }
        func keepsRule(_ patches: [SourcePatch]) -> Bool {
            let source = NSMutableString(string: session.source)
            for patch in patches.sorted(by: { $0.range.location > $1.range.location }) {
                source.replaceCharacters(in: patch.range, with: patch.replacement)
            }
            let candidate = MarkdownRenderer.snapshot(source: source as String)
            return candidate.runs.contains {
                $0.style.contains(.horizontalRule) && candidate.sourceMap.sourceOffset(forDisplayedOffset: $0.range.location) == offset
            }
        }
        if keepsRule(patches) { return .unaffected }
        // `---` directly under text becomes a Setext underline; `***` stays a rule.
        if let marker = snapshot.sourceMap.segments.first(where: { $0.kind == .attachment && $0.displayedNSRange.location == rule.range.location })?.sourceNSRange,
           patches.allSatisfy({ NSMaxRange($0.range) <= marker.location }) {
            let converted = patches + [SourcePatch(range: marker, replacement: "***")]
            if keepsRule(converted) { return .converted(converted) }
        }
        return .blocked
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if self.textView.isCancellingComposition { return true }
        guard canEdit, !refreshing else { return false }
        if self.textView.isComposing || textView.hasMarkedText() { return true }
        guard let replacementString else { return false }
        let editingRange = affectedCharRange
        if mode == .richText, replacementString.isEmpty, editingRange.length == 1,
           textView.selectedRange() == NSRange(location: NSMaxRange(editingRange), length: 0),
           let snapshot = session.renderSnapshot, snapshot.source == session.source,
           snapshot.codeBlocks.contains(where: {
               $0.closingFenceEnd != nil && $0.range.length > 0 && NSMaxRange($0.range) == NSMaxRange(editingRange)
           }) {
            textView.setSelectedRange(NSRange(location: editingRange.location, length: 0))
            session.selectedSourceRange = selectedSourceRange()
            return false
        }
        if mode == .richText, replacementString.isEmpty, affectedCharRange.length == 1,
           textView.selectedRange() == NSRange(location: NSMaxRange(affectedCharRange), length: 0),
           affectedCharRange.location > 0, let storage = textView.textStorage,
           storage.attribute(.markdownHorizontalRule, at: affectedCharRange.location - 1, effectiveRange: nil) != nil,
           (storage.string as NSString).character(at: affectedCharRange.location) == 10 {
            let text = storage.string as NSString
            let next = NSMaxRange(affectedCharRange)
            // A text line would merge into the rule marker, so select the rule first instead.
            if next < text.length, text.character(at: next) != 10 {
                textView.setSelectedRange(NSRange(location: affectedCharRange.location - 1, length: 1))
                session.selectedSourceRange = selectedSourceRange()
                return false
            }
        }
        let deletingHorizontalRule = mode == .richText && replacementString.isEmpty && editingRange.length == 1
            && textView.textStorage?.attribute(.markdownHorizontalRule, at: editingRange.location, effectiveRange: nil) != nil
        let sourceRange = mode == .source ? editingRange : map?.sourceRange(forDisplayedRange: editingRange)
        if let sourceRange, applyPendingStyles(to: replacementString, in: sourceRange) { return false }
        session.selectedSourceRange = selectedSourceRange()
        var patches: [SourcePatch]
        if mode == .source { patches = [SourcePatch(range: editingRange, replacement: replacementString)] }
        else {
            guard displayedSource == session.source, let map,
                  let result = map.patches(forDisplayedRange: editingRange, replacement: replacementString, source: session.source) else { return false }
            patches = result
        }
        if replacementString.isEmpty {
            if mode == .richText, editingRange.length == 1,
               textView.selectedRange() == NSRange(location: NSMaxRange(editingRange), length: 0),
               let snapshot = session.renderSnapshot, snapshot.source == session.source,
               let block = snapshot.codeBlocks.first(where: { NSMaxRange($0.range) == editingRange.location }),
               let fenceEnd = block.closingFenceEnd, patches.count == 1,
               patches[0].range.location == fenceEnd {
                let source = session.source as NSString
                let removed = source.substring(with: patches[0].range)
                let next = NSMaxRange(patches[0].range)
                if ["\n", "\r\n", "\r"].contains(removed), next < source.length,
                   source.character(at: next) != 10, source.character(at: next) != 13 {
                    textView.setSelectedRange(NSRange(location: editingRange.location, length: 0))
                    session.selectedSourceRange = selectedSourceRange()
                    return false
                }
            }
            switch ruleBoundary(deleting: editingRange, patches: patches) {
            case .unaffected: break
            case .converted(let converted):
                patches = converted
                applyingNativeEdit = true
                let accepted = session.apply(patches)
                applyingNativeEdit = false
                if accepted {
                    session.renderNow()
                    textView.setSelectedRange(NSRange(location: editingRange.location, length: 0))
                    session.selectedSourceRange = selectedSourceRange()
                }
                return false
            case .blocked:
                let previous = (textView.string as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted,
                    options: .backwards, range: NSRange(location: 0, length: editingRange.location))
                let caret = previous.location == NSNotFound ? 0 : NSMaxRange(previous)
                textView.setSelectedRange(NSRange(location: caret, length: 0))
                session.selectedSourceRange = selectedSourceRange()
                return false
            }
        }
        let deletingListMarker = mode == .richText && replacementString.isEmpty && map?.segments.contains(where: {
            $0.isListMarker && NSIntersectionRange($0.displayedNSRange, affectedCharRange).length > 0
        }) == true
        let insertingInsideListMarker = mode == .richText && affectedCharRange.length == 0 && !replacementString.isEmpty && map?.segments.contains(where: {
            $0.isListMarker && NSLocationInRange(affectedCharRange.location, $0.displayedNSRange)
        }) == true
        let fencedFrame = mode == .richText ? self.textView.codeBlockFrame(at: editingRange.location) : nil
        let insertingWhitespace = mode == .richText && !replacementString.isEmpty
            && replacementString.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        let editsCodeInPlace = fencedFrame != nil && patches.count == 1
            && patches[0].range == sourceRange && patches[0].replacement == replacementString
            && !insertingWhitespace && !replacementString.contains(where: \.isNewline)
            && session.renderSnapshot?.codeBlocks.contains(where: {
                $0.closingFenceEnd != nil && self.textView.codeBlockFrame(at: $0.range.location) === fencedFrame
            }) == true
            && map?.segments.contains(where: {
                $0.kind == .code && NSLocationInRange(editingRange.location, $0.displayedNSRange)
                    && NSMaxRange(editingRange) <= NSMaxRange($0.displayedNSRange)
                    && !(textView.string as NSString).substring(with: $0.displayedNSRange).contains(where: \.isNewline)
            }) == true
        let colorEdit = !editsCodeInPlace && patches.count == 1 && patches[0].replacement == replacementString
            ? codeColorEdit(in: editingRange, replacement: replacementString) : nil
        applyingNativeEdit = true
        let accepted = session.apply(patches)
        applyingNativeEdit = false
        pendingCodeColorEdit = accepted ? colorEdit : nil
        defer { pendingCodeColorEdit = nil }
        if accepted, deletingHorizontalRule || deletingListMarker || insertingInsideListMarker || insertingWhitespace {
            session.renderNow()
            return false
        }
        if accepted, mode == .richText, !editsCodeInPlace, let sourceRange,
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
        updateCodeLanguagePicker()
    }
    public func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard affectedRanges.count == 1, let replacement = replacementStrings?.first else { return false }
        return self.textView(textView, shouldChangeTextIn: affectedRanges[0].rangeValue, replacementString: replacement)
    }

    private func applyRenderedAttributes(_ result: NSAttributedString) -> Bool {
        guard let storage = textView.textStorage, storage.string == result.string else { return false }
        var changes: [(NSRange, [NSAttributedString.Key: Any])] = []
        var linkChanges: [NSRange] = []
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attributes, range, _ in
            storage.enumerateAttributes(in: range) { previous, span, _ in
                var updated = attributes
                if let attachment = previous[.attachment], attributes[.attachment] != nil,
                   (attributes[.markdownHorizontalRule] != nil && previous[.markdownHorizontalRule] != nil
                    || (attributes[NSAttributedString.Key("MarkdownImagePath")] as? String).map {
                        $0 == previous[NSAttributedString.Key("MarkdownImagePath")] as? String
                    } == true) {
                    updated[.attachment] = attachment
                }
                if !NSDictionary(dictionary: previous).isEqual(to: updated) {
                    changes.append((span, updated))
                    if previous[.link] != nil || updated[.link] != nil { linkChanges.append(span) }
                }
            }
        }
        storage.beginEditing()
        for (range, attributes) in changes { storage.setAttributes(attributes, range: range) }
        storage.endEditing()
        for range in linkChanges {
            textView.layoutManager?.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
        }
        return true
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
        (clip as? EditorClipView)?.preservesScrollOrigin = false
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maximum, max(0, proposed))))
        scroll.reflectScrolledClipView(clip)
    }

    private func refresh() {
        guard isViewLoaded else { return }
        guard !textView.isComposing, !textView.hasMarkedText(), !applyingNativeEdit else { pendingRender = true; return }
        let clip = textView.enclosingScrollView?.contentView as? EditorClipView
        if modeViewportAnchor != nil { clip?.preservesScrollOrigin = true }
        let selection = session.selectedSourceRange
        refreshing = true
        defer { refreshing = false; clip?.preservesScrollOrigin = false }
        textView.isEditable = canEdit
        textView.isRichText = mode == .richText
        if let snapshot = session.renderSnapshot, snapshot.source == session.source {
            outlineSidebar.update(headings: snapshot.headings)
            outlineSidebar.selectHeading(atSourceOffset: selection.location)
        }
        if mode == .source {
            clearCodeHighlights()
            blockColors.removeAll()
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
                if displayedMode != .richText || imagesChanged
                    || (!applyRenderedAttributes(result.attributedString) && !applyCheckboxUpdate(result.attributedString)) {
                    clearCodeHighlights()
                    textView.textStorage?.setAttributedString(result.attributedString)
                    restoreCodeHighlights(in: snapshot)
                }
                map = result.sourceMap
                renderedSnapshotSource = snapshot.source
                imagesChanged = false
            }
            displayedSource = snapshot.source
            displayedMode = .richText
            scheduleCodeHighlights(snapshot)
            let displayedSelection = snapshot.sourceMap.displayedRange(forSourceRange: selection)
            if textView.selectedRange() != displayedSelection { textView.setSelectedRange(displayedSelection) }
            pendingRender = false
        } else {
            invalidateCodeHighlightTask()
            pendingRender = true
            if displayedSource != session.source || displayedMode != .richText {
                clearCodeHighlights()
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
        updateCodeLanguagePicker()
    }

    func waitForCodeHighlights() async { await codeHighlightTask?.value }

    private func invalidateCodeHighlightTask() {
        if scheduledHighlightSource != nil {
            codeHighlightRevision &+= 1
            codeHighlightTask?.cancel()
            codeHighlightTask = nil
            scheduledHighlightSource = nil
        }
    }

    private func clearCodeHighlights() {
        invalidateCodeHighlightTask()
        guard hasCodeColors else { return }
        if let storage = textView.textStorage {
            textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        }
        hasCodeColors = false
    }

    private func scheduleCodeHighlights(_ snapshot: RenderSnapshot) {
        guard !snapshot.codeBlocks.isEmpty else {
            clearCodeHighlights()
            blockColors.removeAll()
            return
        }
        guard scheduledHighlightSource != snapshot.source else { return }
        invalidateCodeHighlightTask()
        scheduledHighlightSource = snapshot.source
        let revision = codeHighlightRevision
        let highlighter = codeHighlighter
        codeHighlightTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            let highlights = await highlighter.highlights(in: snapshot)
            guard !Task.isCancelled, let self, self.codeHighlightRevision == revision else { return }
            if self.textView.isComposing || self.textView.hasMarkedText() {
                self.scheduledHighlightSource = nil
                return
            }
            guard self.mode == .richText, self.session.source == snapshot.source,
                  self.renderedSnapshotSource == snapshot.source else { return }
            self.applyCodeHighlights(highlights)
            self.rememberCodeHighlights(highlights, in: snapshot)
        }
    }

    private func coloredBlock(_ block: CodeBlockSnapshot, in text: NSString) -> ColoredBlock? {
        guard block.range.length <= CodeHighlighter.maximumBlockLength,
              let language = CodeLanguage(label: block.language),
              let bytes = text.substring(with: block.range).data(using: .utf16LittleEndian) else { return nil }
          return ColoredBlock(language: language, text: bytes)
    }

    private func rememberCodeHighlights(_ highlights: [CodeHighlight], in snapshot: RenderSnapshot) {
        blockColors.removeAll(keepingCapacity: true)
        let text = snapshot.text as NSString
        var index = 0
        var remaining = CodeHighlighter.maximumCacheLength
        for block in snapshot.codeBlocks {
            let start = index
            while index < highlights.count, highlights[index].range.location < NSMaxRange(block.range) { index += 1 }
            guard index > start, block.range.length <= remaining,
                let key = coloredBlock(block, in: text), blockColors[key] == nil else { continue }
            remaining -= block.range.length
            blockColors[key] = highlights[start..<index].map { $0.offset(by: -block.range.location) }
        }
    }

    private func restoreCodeHighlights(in snapshot: RenderSnapshot) {
        guard !blockColors.isEmpty || pendingCodeColorEdit != nil else { return }
        let text = snapshot.text as NSString
        let highlights = snapshot.codeBlocks.flatMap { block -> [CodeHighlight] in
            if let edit = pendingCodeColorEdit, block.range == edit.range, block.language == edit.language,
               text.substring(with: block.range).utf16.elementsEqual(edit.text.utf16) { return edit.colors }
            guard let key = coloredBlock(block, in: text), let colors = blockColors[key] else { return [] }
            return colors.map { $0.offset(by: block.range.location) }
        }
        applyCodeHighlights(highlights)
    }

    private func codeColorEdit(in range: NSRange, replacement: String)
        -> (text: String, range: NSRange, language: String, colors: [CodeHighlight])? {
        guard hasCodeColors, let block = currentCodeBlock, block.range.length <= CodeHighlighter.maximumBlockLength,
              range.location >= block.range.location, NSMaxRange(range) <= NSMaxRange(block.range),
              let key = coloredBlock(block, in: textView.string as NSString), let colors = blockColors[key] else { return nil }
        let local = NSRange(location: range.location - block.range.location, length: range.length)
        let delta = replacement.utf16.count - range.length
        let text = (textView.string as NSString).substring(with: block.range) as NSString
        let updated = colors.compactMap { color -> CodeHighlight? in
            if NSMaxRange(color.range) <= local.location { return color.offset(by: block.range.location) }
            if color.range.location >= NSMaxRange(local) { return color.offset(by: block.range.location + delta) }
            return nil
        }
        return (text.replacingCharacters(in: local, with: replacement),
                NSRange(location: block.range.location, length: block.range.length + delta), block.language, updated)
    }

    private func applyCodeHighlights(_ highlights: [CodeHighlight]) {
        guard hasCodeColors || !highlights.isEmpty, let storage = textView.textStorage,
              let layout = textView.layoutManager, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        var index = 0
        var tokenIndex = 0
        while index < whole.length {
            var actual = NSRange()
            let current = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                    longestEffectiveRange: &actual, in: whole) as? NSColor
            let token = tokenIndex < highlights.count ? highlights[tokenIndex] : nil
            let desired = token.flatMap { $0.range.location <= index ? $0.kind.color : nil }
            let limit = token.map { $0.range.location <= index ? NSMaxRange($0.range) : $0.range.location } ?? whole.length
            let end = min(NSMaxRange(actual), limit)
            let changed = NSRange(location: index, length: end - index)
            if current != desired {
                if let desired { layout.addTemporaryAttribute(.foregroundColor, value: desired, forCharacterRange: changed) }
                else { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: changed) }
            }
            index = end
            if let token, end == NSMaxRange(token.range) { tokenIndex += 1 }
        }
        hasCodeColors = !highlights.isEmpty
    }

    private func beginComposition() {
        updateCodeLanguagePicker()
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

@MainActor private final class EditorClipView: NSClipView {
    var preservesScrollOrigin = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        if preservesScrollOrigin { result.origin = bounds.origin }
        return result
    }
}

private extension CodeHighlight.Kind {
    var color: NSColor {
        switch self {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number, .constant: .systemOrange
        case .type, .tag: .systemTeal
        case .function: .systemBlue
        case .property: .systemIndigo
        case .operatorSymbol: .systemPink
        }
    }
}