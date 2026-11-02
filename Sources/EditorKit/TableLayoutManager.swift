import AppKit
import CoreText

extension NSParagraphStyle {
    var markdownTableBlock: NSTextTableBlock? {
        textBlocks.compactMap { $0 as? NSTextTableBlock }.first { !($0 is QuoteTextBlock) }
    }

    var markdownQuoteIndent: CGFloat {
        textBlocks.compactMap { $0 as? QuoteTextBlock }.reduce(0) {
            $0 + $1.width(for: .border, edge: .minX) + $1.width(for: .padding, edge: .minX)
        }
    }
}

public final class TableLayoutManager: NSLayoutManager {
    public func headingSeparatorRect(at character: Int) -> NSRect? {
        guard let storage = textStorage, let container = textContainers.first,
              character >= 0, character < storage.length else { return nil }
        var range = NSRange()
        guard storage.attribute(.markdownHeadingSeparator, at: character, longestEffectiveRange: &range,
                                in: NSRange(location: 0, length: storage.length)) != nil else { return nil }
        let text = storage.string as NSString
        var end = NSMaxRange(range)
        while end > range.location, [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
        guard end > range.location else { return nil }
        let glyph = glyphIndexForCharacter(at: end - 1)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = storage.attribute(.font, at: end - 1, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 16)
        let paragraph = storage.attribute(.paragraphStyle, at: end - 1, effectiveRange: nil) as? NSParagraphStyle
        let indent = paragraph?.headIndent ?? 0
        let baseline = line.minY + location(forGlyphAt: glyph).y
        return NSRect(x: line.minX + container.lineFragmentPadding + indent, y: baseline - font.descender + 4,
                      width: max(0, line.width - 2 * container.lineFragmentPadding - indent), height: 1)
    }

    public func horizontalRuleRect(at character: Int) -> NSRect? {
        guard let storage = textStorage, let container = textContainers.first,
              character >= 0, character < storage.length,
              storage.attribute(.markdownHorizontalRule, at: character, effectiveRange: nil) != nil else { return nil }
        let glyph = glyphIndexForCharacter(at: character)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let paragraph = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle
        let indent = paragraph?.headIndent ?? 0
        return NSRect(x: line.minX + container.lineFragmentPadding + indent, y: line.midY - 2,
                  width: max(0, line.width - 2 * container.lineFragmentPadding - indent), height: 4)
    }

    public func checkboxRect(at character: Int) -> NSRect? {
        guard let storage = textStorage, let container = textContainers.first,
              character >= 0, character < storage.length,
              storage.attribute(.markdownCheckbox, at: character, effectiveRange: nil) != nil else { return nil }
        let glyphs = glyphRange(forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil)
        let bounds = boundingRect(forGlyphRange: glyphs, in: container)
        let text = storage.string as NSString
        let content = min(character + 2, storage.length - 1)
        let reference = text.character(at: content) == 10 ? character : content
        let referenceGlyph = glyphIndexForCharacter(at: reference)
        let line = lineFragmentRect(forGlyphAt: referenceGlyph, effectiveRange: nil)
        let baseline = line.minY + location(forGlyphAt: referenceGlyph).y
        let font = storage.attribute(.font, at: reference, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 16)
        let sample = storage.attributedSubstring(from: text.rangeOfComposedCharacterSequence(at: reference))
        let ink = CTLineGetImageBounds(CTLineCreateWithAttributedString(sample), nil)
        let middle = ink.isEmpty || ink.isNull ? font.capHeight / 2 : ink.midY
        return NSRect(x: bounds.midX - 8, y: baseline - middle - 8, width: 16, height: 16)
    }

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownHeadingSeparator, in: visible) { value, range, _ in
            guard value != nil, let rect = self.headingSeparatorRect(at: range.location) else { return }
            MainActor.assumeIsolated {
                NSColor.labelColor.withAlphaComponent(0.12).setFill()
                rect.offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
        storage.enumerateAttribute(.markdownHorizontalRule, in: visible) { value, range, _ in
            guard value != nil, let rect = self.horizontalRuleRect(at: range.location) else { return }
            MainActor.assumeIsolated {
                NSColor.labelColor.withAlphaComponent(0.18).setFill()
                rect.offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
        storage.enumerateAttribute(.markdownCheckbox, in: visible) { value, range, _ in
            guard let checked = value as? Bool, let bounds = self.checkboxRect(at: range.location) else { return }
            let rect = bounds.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.75, dy: 0.75)
            MainActor.assumeIsolated {
                let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                outline.lineWidth = 1.5
                if checked {
                    NSColor.controlAccentColor.setFill()
                    outline.fill()
                    NSColor.controlAccentColor.setStroke()
                } else {
                    NSColor.secondaryLabelColor.setStroke()
                }
                outline.stroke()
                if checked {
                    let check = NSBezierPath()
                    check.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
                    check.line(to: NSPoint(x: rect.minX + 6, y: rect.maxY - 4))
                    check.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 4))
                    check.lineWidth = 1.8
                    check.lineCapStyle = .round
                    check.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    check.stroke()
                }
            }
        }
    }

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let all = NSRange(location: 0, length: storage.length)
        var location = visible.location
        while location < NSMaxRange(visible) {
            var span = NSRange()
            let value = storage.attribute(.markdownInlineCode, at: location, longestEffectiveRange: &span, in: all)
            location = max(location + 1, NSMaxRange(span))
            guard value != nil else { continue }
            // The trailing kern is inside the glyph rect, so shifting left by one padding centres the text.
            let glyphs = glyphRange(forCharacterRange: span, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                var frame = rect.offsetBy(dx: origin.x - CodeBlockTextBlock.inlinePadding, dy: origin.y)
                frame = frame.insetBy(dx: 0, dy: 1)
                MainActor.assumeIsolated { CodeBlockTextBlock.drawFrame(frame, radius: CodeBlockTextBlock.inlineCornerRadius) }
            }
        }
    }

    public static func columnWidths(preferred: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !preferred.isEmpty else { return [] }
        let total = preferred.reduce(0, +)
        if total <= available {
            let extra = (available - total) / CGFloat(preferred.count)
            return preferred.map { $0 + extra }
        }
        var widths = preferred
        var remaining = available
        var pending = Set(preferred.indices)
        while !pending.isEmpty {
            let share = remaining / CGFloat(pending.count)
            let fitting = pending.filter { preferred[$0] <= share }
            if fitting.isEmpty {
                for index in pending { widths[index] = max(1, share) }
                break
            }
            for index in fitting { widths[index] = preferred[index]; remaining -= widths[index]; pending.remove(index) }
        }
        return widths
    }

    public struct GridRow {
        public let bounds: NSRect
        public let columns: Int
        public let isHeader: Bool
        public let columnWidths: [CGFloat]
    }

    public func tableRows(in container: NSTextContainer, characterRange: NSRange? = nil) -> [GridRow] {
        guard let storage = textStorage else { return [] }
        ensureLayout(for: container)
        let text = storage.string as NSString
        let requested = characterRange ?? NSRange(location: 0, length: text.length)
        guard requested.location < text.length else { return [] }
        var cursor = text.lineRange(for: NSRange(location: requested.location, length: 0)).location
        let end = min(text.length, NSMaxRange(requested))
        var rows: [GridRow] = []
        var rowKeys: [String: Int] = [:]
        while cursor < end {
            let range = text.lineRange(for: NSRange(location: cursor, length: 0))
            defer { cursor = NSMaxRange(range) }
            guard let paragraph = storage.attribute(.paragraphStyle, at: cursor, effectiveRange: nil) as? NSParagraphStyle,
                let block = paragraph.markdownTableBlock else { continue }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let rect = boundingRect(forGlyphRange: glyphs, in: container)
            let key = "\(ObjectIdentifier(block.table)):\(block.startingRow)"
            if let index = rowKeys[key] {
                let previous = rows[index]
                var widths = previous.columnWidths
                widths[block.startingColumn] = block.contentWidth + 13
                rows[index] = GridRow(bounds: previous.bounds.union(NSRect(x: container.lineFragmentPadding, y: rect.minY, width: block.table.contentWidth, height: max(28, rect.height))), columns: block.table.numberOfColumns, isHeader: block.startingRow == 0, columnWidths: widths)
            } else {
                rowKeys[key] = rows.count
                var widths = Array(repeating: CGFloat(0), count: block.table.numberOfColumns)
                widths[block.startingColumn] = block.contentWidth + 13
                rows.append(GridRow(bounds: NSRect(x: container.lineFragmentPadding, y: rect.minY, width: block.table.contentWidth, height: max(28, rect.height)), columns: block.table.numberOfColumns, isHeader: block.startingRow == 0, columnWidths: widths))
            }
        }
        return rows
    }

}