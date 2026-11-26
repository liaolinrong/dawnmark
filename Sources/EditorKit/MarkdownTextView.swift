import AppKit
import MarkdownEngine

@MainActor public final class MarkdownTextView: NSTextView, CodeBlockBackgroundDrawing, TableBackgroundDrawing {
    public static let formattedMarkdownType = NSPasteboard.PasteboardType("com.liaolinrong.DawnMark.formatted-markdown")
    public var onCopyMarkdown: ((NSRange) -> String?)?
    public var onPasteMarkdown: ((String) -> Bool)?
    public var onImportImages: (([URL], Data?) -> Void)?
    public var editingAllowed: (() -> Bool)?
    public var onCompositionStart: (() -> Void)?
    public var onCompositionEnd: (() -> Void)?
    public var onToggleCheckbox: ((Int) -> Bool)?
    public var onListNewline: (() -> Bool)?
    public var onListIndent: ((Bool) -> Bool)?
    public var onLinkMenu: ((Int) -> NSMenu?)?
    public var onCodeBlockMenu: ((Int) -> NSMenu?)?
    public var onTableMenu: ((Int) -> NSMenu?)?
    public private(set) var isComposing = false
    public private(set) var isCancellingComposition = false
    public weak var documentSession: DocumentSession?
    private var checkboxTrackingArea: NSTrackingArea?
    weak var codeLanguagePicker: CodeLanguagePicker?
    private var codeLanguagePickerOffset: Int?

    override public func layout() {
        super.layout()
        positionCodeLanguagePicker(at: codeLanguagePickerOffset)
    }

    func positionCodeLanguagePicker(at offset: Int?) {
        codeLanguagePickerOffset = offset
        guard let picker = codeLanguagePicker else { return }
        guard let offset, let storage = textStorage, offset < storage.length,
              let paragraph = storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle,
              let block = paragraph.textBlocks.compactMap({ $0 as? CodeBlockTextBlock }).first,
              let layout = layoutManager else { picker.isHidden = true; return }
        layout.ensureLayout(forCharacterRange: NSRange(location: offset, length: 1))
        let glyph = layout.glyphIndexForCharacter(at: offset)
        let origin = textContainerOrigin
        let frame = block.backgroundRect(for: layout.boundsRect(for: block, at: glyph, effectiveRange: nil))
            .offsetBy(dx: origin.x, dy: origin.y)
        let right = min(frame.maxX, bounds.maxX)
        let width = min(max(112, picker.intrinsicContentSize.width), 220, right - frame.minX)
        let bottom = frame.minY - CodeBlockTextBlock.languagePickerGap
        let height = max(CodeBlockTextBlock.languagePickerHeight, picker.intrinsicContentSize.height)
        guard width > 0, height > 0 else { picker.isHidden = true; return }
        picker.frame = NSRect(x: right - width, y: max(bounds.minY, bottom - height),
                      width: width, height: height)
        picker.isHidden = false
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawTableBackground(in: rect)
        guard let storage = textStorage, storage.length > 0,
              let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let search = rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -32)
        let glyphs = layout.glyphRange(forBoundingRect: search, in: container)
        guard glyphs.length > 0 else { return }
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var drawn: Set<ObjectIdentifier> = []
        storage.enumerateAttribute(.paragraphStyle, in: characters) { value, range, _ in
            guard let paragraph = value as? NSParagraphStyle else { return }
            for case let block as CodeBlockTextBlock in paragraph.textBlocks {
                guard drawn.insert(ObjectIdentifier(block)).inserted else { continue }
                let glyph = layout.glyphIndexForCharacter(at: range.location)
                let bounds = layout.boundsRect(for: block, at: glyph, effectiveRange: nil)
                let frame = block.backgroundRect(for: bounds).offsetBy(dx: origin.x, dy: origin.y)
                guard frame.intersects(rect) else { continue }
                CodeBlockTextBlock.drawFrame(frame, radius: CodeBlockTextBlock.cornerRadius)
            }
        }
    }

    private func drawTableBackground(in rect: NSRect) {
        guard let storage = textStorage, storage.length > 0, let layout = layoutManager else { return }
        let origin = textContainerOrigin
        var drawn: Set<ObjectIdentifier> = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let paragraph = value as? NSParagraphStyle else { return }
            for case let block as MarkdownTableBlock in paragraph.textBlocks {
                guard drawn.insert(ObjectIdentifier(block)).inserted else { continue }
                let glyph = layout.glyphIndexForCharacter(at: range.location)
                let frame = layout.boundsRect(for: block, at: glyph, effectiveRange: nil)
                    .offsetBy(dx: origin.x, dy: origin.y)
                guard frame.intersects(rect) else { continue }
                block.drawFrame(frame, in: self, characterRange: range, layoutManager: layout)
            }
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let checkboxTrackingArea { removeTrackingArea(checkboxTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        checkboxTrackingArea = area
    }

    func checkboxCharacter(at point: NSPoint) -> Int? {
        guard isEditable, editingAllowed?() != false, !isComposing, !hasMarkedText(),
              let layout = layoutManager as? TableLayoutManager, let container = textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        return layout.checkboxRect(at: character)?.contains(local) == true ? character : nil
    }

    private func horizontalRuleRange(at point: NSPoint) -> NSRange? {
        guard isRichText, isSelectable, !isComposing, !hasMarkedText(),
              let storage = textStorage, let layout = layoutManager as? TableLayoutManager,
              let container = textContainer, visibleRect.contains(point) else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: NSRect(x: local.x, y: local.y - 8, width: 1, height: 16), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var result: NSRange?
        storage.enumerateAttribute(.markdownHorizontalRule, in: characters) { value, range, stop in
            guard value != nil, let rect = layout.horizontalRuleRect(at: range.location),
                  rect.insetBy(dx: 0, dy: -4).contains(local) else { return }
            result = range
            stop.pointee = true
        }
        return result
    }

    public override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if checkboxCharacter(at: point) != nil || horizontalRuleRange(at: point) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if checkboxCharacter(at: point) != nil || horizontalRuleRange(at: point) != nil {
            NSCursor.pointingHand.set()
        }
    }
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTableLayout()
        updateImageLayout()
    }

    public func updateImageLayout() {
        guard let storage = textStorage, let container = textContainer else { return }
        let available = container.size.width - 2 * container.lineFragmentPadding
        guard available > 0 else { return }
        var changed: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image,
                  image.size.width > 0, image.size.height > 0 else { return }
            let isRule = storage.attribute(.markdownHorizontalRule, at: range.location, effectiveRange: nil) != nil
            let paragraph = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let block = paragraph?.markdownTableBlock
            let width = max(1, block?.contentWidth ?? (available - (paragraph?.markdownQuoteIndent ?? 0) - max(paragraph?.headIndent ?? 0, paragraph?.firstLineHeadIndent ?? 0)))
            let size = NSSize(width: isRule ? max(1, width - 1) : width, height: isRule ? 1 : width * image.size.height / image.size.width)
            if abs(attachment.bounds.width - size.width) > 0.01 || abs(attachment.bounds.height - size.height) > 0.01 {
                attachment.bounds = NSRect(origin: attachment.bounds.origin, size: size)
                changed.append(range)
            }
        }
        for range in changed {
            layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager?.invalidateDisplay(forCharacterRange: range)
        }
    }

    public func updateTableLayout() {
        guard let storage = textStorage, let container = textContainer, storage.length > 0 else { return }
        let available = container.size.width - 2 * container.lineFragmentPadding
        guard available > 0 else { return }
        var cells: [(NSRange, NSParagraphStyle, NSTextTableBlock)] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let paragraph = value as? NSParagraphStyle, let block = paragraph.markdownTableBlock else { return }
            cells.append((range, paragraph, block))
        }
        let groups = Dictionary(grouping: cells, by: { ObjectIdentifier($0.2.table) })
        for group in groups.values {
            let table = group[0].2.table
            var preferred = Array(repeating: CGFloat(24), count: table.numberOfColumns)
            for (range, _, block) in group {
                let content = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
                content.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: content.length))
                let width = ceil(content.size().width) + 13
                preferred[block.startingColumn] = max(preferred[block.startingColumn], width)
            }
            let widths = TableLayoutManager.columnWidths(preferred: preferred, available: max(1, available - group[0].1.markdownQuoteIndent))
            let total = widths.reduce(0, +)
            var changed = table.contentWidthValueType != .absoluteValueType || abs(table.contentWidth - total) > 0.5
            table.setContentWidth(total, type: .absoluteValueType)
            for (_, _, block) in group {
                let width = max(1, widths[block.startingColumn] - 13)
                changed = changed || block.contentWidthValueType != .absoluteValueType || abs(block.contentWidth - width) > 0.5
                block.setContentWidth(width, type: .absoluteValueType)
            }
            if changed {
                for (range, paragraph, _) in group { storage.addAttribute(.paragraphStyle, value: paragraph.copy(), range: range) }
                layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: group[0].0.location, length: NSMaxRange(group.last!.0) - group[0].0.location), actualCharacterRange: nil)
            }
        }
    }

    // Source patches own undo; AppKit typing undo would replay displayed text through the delegate.
    public override var undoManager: UndoManager? { nil }
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        (isRichText ? [Self.formattedMarkdownType] : []) + [.fileURL, .png, .tiff, .string, .rtf]
    }

    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        (isRichText ? [Self.formattedMarkdownType] : []) + [.string] + super.writablePasteboardTypes.filter { $0 != .string }
    }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == Self.formattedMarkdownType {
            guard isRichText, selectedRanges.count == 1, let markdown = onCopyMarkdown?(selectedRange()) else { return false }
            return pboard.setString(markdown, forType: type)
        }
        guard type == .string else { return super.writeSelection(to: pboard, type: type) }
        let text = string as NSString
        let selections = selectedRanges.map(\.rangeValue).filter {
            $0.location != NSNotFound && $0.length > 0 && NSMaxRange($0) <= text.length
        }
        guard !selections.isEmpty else { return false }
        return pboard.setString(selections.map { text.substring(with: $0) }.joined(separator: "\n"), forType: .string)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard isSelectable, !isComposing, !hasMarkedText(),
              let storage = textStorage, let layout = layoutManager as? TableLayoutManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownCheckbox, in: characters) { value, range, _ in
            guard isEditable, editingAllowed?() != false,
                  value != nil, let rect = layout.checkboxRect(at: range.location) else { return }
            let clipped = rect.offsetBy(dx: origin.x, dy: origin.y).intersection(visibleRect)
            guard !clipped.isEmpty, clipped.origin.x.isFinite, clipped.origin.y.isFinite,
                  clipped.width.isFinite, clipped.height.isFinite else { return }
            addCursorRect(clipped, cursor: .pointingHand)
        }
        if isRichText {
            storage.enumerateAttribute(.markdownHorizontalRule, in: characters) { value, range, _ in
                guard value != nil, let rect = layout.horizontalRuleRect(at: range.location) else { return }
                let clipped = rect.insetBy(dx: 0, dy: -4).offsetBy(dx: origin.x, dy: origin.y).intersection(visibleRect)
                guard !clipped.isEmpty, clipped.origin.x.isFinite, clipped.origin.y.isFinite,
                      clipped.width.isFinite, clipped.height.isFinite else { return }
                addCursorRect(clipped, cursor: .pointingHand)
            }
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard !isComposing, !hasMarkedText(), let layout = layoutManager, let container = textContainer else {
            return super.menu(for: event)
        }
        let point = convert(event.locationInWindow, from: nil)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndex(for: local, in: container)
        if glyph < layout.numberOfGlyphs,
           layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).insetBy(dx: -6, dy: 0).contains(local),
           let code = onCodeBlockMenu?(layout.characterIndexForGlyph(at: glyph)) {
            let selection = selectedRanges
            let menu = super.menu(for: event) ?? NSMenu()
            if selectedRanges != selection { selectedRanges = selection }
            if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
            while let item = code.items.first {
                code.removeItem(item)
                menu.insertItem(item, at: 0)
            }
            return menu
        }
        if glyph < layout.numberOfGlyphs,
           layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local),
           let menu = onLinkMenu?(layout.characterIndexForGlyph(at: glyph)) {
            if let table = onTableMenu?(layout.characterIndexForGlyph(at: glyph)) {
                menu.addItem(.separator())
                let item = NSMenuItem(title: table.title, action: nil, keyEquivalent: "")
                item.submenu = table
                menu.addItem(item)
            }
            return menu
        }
        if let storage = textStorage {
            var result: NSMenu?
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard let paragraph = value as? NSParagraphStyle, let block = paragraph.markdownTableBlock else { return }
                let character = range.location
                let blockGlyph = layout.glyphIndexForCharacter(at: character)
                guard layout.boundsRect(for: block, at: blockGlyph, effectiveRange: nil).contains(local),
                      let menu = self.onTableMenu?(character) else { return }
                result = menu
                stop.pointee = true
            }
            if let result { return result }
        }
        if glyph < layout.numberOfGlyphs,
           layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local),
           let menu = onTableMenu?(layout.characterIndexForGlyph(at: glyph)) {
            return menu
        }
        return super.menu(for: event)
    }

    private func tableBorderInsertion(at point: NSPoint) -> Int? {
        guard isRichText, isSelectable, !isComposing, !hasMarkedText(),
              let storage = textStorage, let layout = layoutManager, let container = textContainer else { return nil }
        layout.ensureLayout(for: container)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        typealias Cell = (block: NSTextTableBlock, range: NSRange, frame: NSRect)
        var tables: [ObjectIdentifier: [Cell]] = [:]
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let paragraph = value as? NSParagraphStyle, let block = paragraph.markdownTableBlock else { return }
            let frame = layout.boundsRect(for: block, at: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            tables[ObjectIdentifier(block.table), default: []].append((block, range, frame))
        }
        for cells in tables.values {
            let grouped = Dictionary(grouping: cells, by: { $0.block.startingRow })
            let rows = grouped.keys.sorted().map { grouped[$0]!.sorted { $0.block.startingColumn < $1.block.startingColumn } }
            let frames = rows.map { $0.reduce(NSRect.null) { $0.union($1.frame) } }
            guard let first = frames.first, let last = frames.last,
                  local.x >= first.minX, local.x <= first.maxX else { continue }
            var targetRow: Int?
            let topPadding = rows[0].map { $0.block.width(for: .padding, edge: .minY) }.max() ?? 0
            let bottomPadding = rows.last!.map { $0.block.width(for: .padding, edge: .maxY) }.max() ?? 0
            if local.y >= first.minY - 1 && local.y <= first.minY + max(1, topPadding) { targetRow = 0 }
            if local.y >= last.maxY - max(1, bottomPadding) && local.y <= last.maxY + 1 { targetRow = rows.count - 1 }
            if rows.count > 1 {
                for index in 0..<(rows.count - 1) {
                    let border = (frames[index].maxY + frames[index + 1].minY) / 2
                    let upperPadding = rows[index].map { $0.block.width(for: .padding, edge: .maxY) }.max() ?? 0
                    let lowerPadding = rows[index + 1].map { $0.block.width(for: .padding, edge: .minY) }.max() ?? 0
                    if local.y >= border - max(1, upperPadding) && local.y <= border + max(1, lowerPadding) {
                        targetRow = local.y <= border ? index : index + 1
                        break
                    }
                }
            }
            guard let targetRow else { continue }
            let row = rows[targetRow]
            var target = row.last!
            for index in row.indices.dropLast() {
                if local.x <= (row[index].frame.maxX + row[index + 1].frame.minX) / 2 {
                    target = row[index]
                    break
                }
            }
            let inside = NSPoint(x: min(max(local.x, target.frame.minX + 1), target.frame.maxX - 1) + textContainerOrigin.x,
                                 y: min(max(local.y, target.frame.minY + 1), target.frame.maxY - 1) + textContainerOrigin.y)
            let native = super.characterIndexForInsertion(at: inside)
            let text = storage.string as NSString
            var end = NSMaxRange(target.range)
            while end > target.range.location, [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
            return min(max(native, target.range.location), end)
        }
        return nil
    }

    public override func characterIndexForInsertion(at point: NSPoint) -> Int {
        tableBorderInsertion(at: point) ?? super.characterIndexForInsertion(at: point)
    }

    public override func mouseDown(with event: NSEvent) {
        if let character = checkboxCharacter(at: convert(event.locationInWindow, from: nil)),
           onToggleCheckbox?(character) == true { return }
        if event.clickCount > 0, let rule = horizontalRuleRange(at: convert(event.locationInWindow, from: nil)) {
            window?.makeFirstResponder(self)
            setSelectedRange(rule)
            return
        }
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let offset = tableBorderInsertion(at: convert(event.locationInWindow, from: nil)) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: offset, length: 0))
            return
        }
        super.mouseDown(with: event)
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let previous = selectedRanges
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard let storage = textStorage else { return }
        for value in previous + ranges {
            let range = value.rangeValue
            guard range.length > 0, range.location < storage.length else { continue }
            let valid = NSRange(location: range.location, length: min(range.length, storage.length - range.location))
            var containsRule = false
            storage.enumerateAttribute(.markdownHorizontalRule, in: valid) { value, _, stop in
                if value != nil { containsRule = true; stop.pointee = true }
            }
            if containsRule { needsDisplay = true; return }
        }
    }

    public override func insertNewline(_ sender: Any?) {
        guard editingAllowed?() != false else { return }
        if !isComposing, !hasMarkedText(), onListNewline?() == true { return }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) {
        guard editingAllowed?() != false else { return }
        if !isComposing, !hasMarkedText(), onListIndent?(false) == true { return }
        // NSTextView treats Tab inside a text block as cell navigation.
        if isInCodeBlock { insertText("\t", replacementRange: selectedRange()); return }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        guard editingAllowed?() != false else { return }
        if !isComposing, !hasMarkedText(), onListIndent?(true) == true { return }
        if isInCodeBlock { return }
        super.insertBacktab(sender)
    }

    private var isInCodeBlock: Bool {
        let location = selectedRange().location
        let attributes = location < textStorage?.length ?? 0 ? textStorage?.attributes(at: location, effectiveRange: nil) : typingAttributes
        return (attributes?[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.contains { $0 is CodeBlockTextBlock } == true
    }

    private func prepareInsertionParagraphStyle(replacementRange: NSRange) {
        guard isRichText, !isComposing, !hasMarkedText(),
              let storage = textStorage, storage.length > 0 else { return }
        let location = replacementRange.location == NSNotFound ? selectedRange().location : replacementRange.location
        guard location <= storage.length,
              let paragraph = storage.attribute(.paragraphStyle, at: min(location, storage.length - 1), effectiveRange: nil) as? NSParagraphStyle else { return }
        var attributes = typingAttributes
        attributes[.paragraphStyle] = paragraph
        typingAttributes = attributes
    }

    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard editingAllowed?() != false else { return }
        prepareInsertionParagraphStyle(replacementRange: replacementRange)
        if !isComposing { isComposing = true; onCompositionStart?() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if isComposing && !hasMarkedText() { isComposing = false; onCompositionEnd?() }
    }
    public override func unmarkText() {
        super.unmarkText()
        if isComposing { isComposing = false; onCompositionEnd?() }
    }
    public func cancelComposition() {
        guard isComposing || hasMarkedText() else { return }
        isCancellingComposition = true
        super.insertText("", replacementRange: markedRange())
        super.unmarkText()
        isCancellingComposition = false
        isComposing = false
        onCompositionEnd?()
    }
    public override func insertText(_ string: Any, replacementRange: NSRange) {
        guard editingAllowed?() != false else { return }
        prepareInsertionParagraphStyle(replacementRange: replacementRange)
        let composing = isComposing
        super.insertText(string, replacementRange: replacementRange)
        if !isComposing { updateTableLayout() }
        if composing && isComposing && !hasMarkedText() { isComposing = false; onCompositionEnd?() }
    }
    public override func paste(_ sender: Any?) {
        guard editingAllowed?() != false else { return }
        if isRichText, NSPasteboard.general.availableType(from: [Self.formattedMarkdownType]) != nil,
           readSelection(from: .general, type: Self.formattedMarkdownType) { return }
        if importImages(from: .general) { return }
        if let type = NSPasteboard.general.availableType(from: [.string, .rtf]) {
            _ = readSelection(from: .general, type: type)
        }
    }
    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard editingAllowed?() != false else { return false }
        if type == Self.formattedMarkdownType {
            guard isRichText, let markdown = pboard.string(forType: type) else { return false }
            return onPasteMarkdown?(markdown) == true
        }
        if importImages(from: pboard) { return true }
        let content: String
        if type == .string, let text = pboard.string(forType: .string) {
            content = text
        } else if type == .rtf, let data = pboard.data(forType: .rtf),
                  let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            content = text.string
        } else { return false }
        let previous = string
        let previousSource = documentSession?.source
        insertText(content, replacementRange: selectedRange())
        return string != previous || documentSession?.source != previousSource
    }
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard editingAllowed?() != false else { return [] }
        if onImportImages != nil && hasImages(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }
    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard editingAllowed?() != false else { return false }
        if onImportImages != nil, hasImages(sender.draggingPasteboard) {
            let point = convert(sender.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            return importImages(from: sender.draggingPasteboard)
        }
        return super.performDragOperation(sender)
    }
    private func imageURLs(_ board: NSPasteboard) -> [URL] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"].contains($0.pathExtension.lowercased()) }
    }
    private func hasImages(_ board: NSPasteboard) -> Bool {
        !imageURLs(board).isEmpty || board.availableType(from: [.png, .tiff]) != nil
    }
    private func importImages(from board: NSPasteboard) -> Bool {
        guard editingAllowed?() != false, let handler = onImportImages else { return false }
        let urls = imageURLs(board)
        let data = board.data(forType: .png) ?? board.data(forType: .tiff)
        guard !urls.isEmpty || data != nil else { return false }
        handler(urls, data)
        return true
    }
}