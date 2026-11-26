import AppKit
import Markdown

public struct RenderStyle: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = Self(rawValue: 1)
    public static let italic = Self(rawValue: 2)
    public static let strike = Self(rawValue: 4)
    public static let code = Self(rawValue: 8)
    public static let quote = Self(rawValue: 16)
    public static let table = Self(rawValue: 32)
    public static let tableHeader = Self(rawValue: 64)
    public static let codeBlock = Self(rawValue: 128)
    public static let list = Self(rawValue: 256)
    public static let horizontalRule = Self(rawValue: 512)
}

extension NSAttributedString.Key {
    public static let markdownInlineCode = NSAttributedString.Key("MarkdownInlineCode")
    public static let markdownCheckbox = NSAttributedString.Key("MarkdownCheckbox")
    public static let markdownHorizontalRule = NSAttributedString.Key("MarkdownHorizontalRule")
    public static let markdownHeadingSeparator = NSAttributedString.Key("MarkdownHeadingSeparator")
}

public protocol CodeBlockBackgroundDrawing: AnyObject {}

public protocol TableBackgroundDrawing: AnyObject {}

public final class MarkdownTableBlock: NSTextTableBlock {
    public override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        guard !(controlView is any TableBackgroundDrawing) else { return }
        super.drawBackground(withFrame: frameRect, in: controlView, characterRange: charRange, layoutManager: layoutManager)
    }

    @MainActor public func drawFrame(_ frame: NSRect, in view: NSView, characterRange: NSRange, layoutManager: NSLayoutManager) {
        super.drawBackground(withFrame: frame, in: view, characterRange: characterRange, layoutManager: layoutManager)
    }
}

public final class QuoteTextBlock: NSTextTableBlock {
    public init() {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.setContentWidth(100, type: .percentageValueType)
        super.init(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        setContentWidth(100, type: .percentageValueType)
        setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        setBorderColor(.separatorColor, for: .minX)
        setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
}

public final class CodeBlockTextBlock: NSTextBlock {
    public static let cornerRadius: CGFloat = 6
    public static let inlineCornerRadius: CGFloat = 4
    /// Horizontal room around inline code, reserved with kerning so the frame never touches neighbours.
    public static let inlinePadding: CGFloat = 3
    public static let languagePickerHeight: CGFloat = 22
    public static let languagePickerGap: CGFloat = 2
    @MainActor public static var fillColor: NSColor { NSColor.textBackgroundColor.blended(withFraction: 0.04, of: .labelColor) ?? .textBackgroundColor }

    @MainActor public static func drawFrame(_ rect: NSRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        path.lineWidth = 1
        fillColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    public override init() {
        super.init()
        setContentWidth(100, type: .percentageValueType)
        setWidth(10, type: .absoluteValueType, for: .padding)
        setWidth(1, type: .absoluteValueType, for: .border)
        setBorderColor(.separatorColor)
        setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    public func backgroundRect(for bounds: NSRect) -> NSRect {
        var rect = bounds
        rect.origin.y += width(for: .margin, edge: .minY)
        rect.size.height -= width(for: .margin, edge: .minY) + width(for: .margin, edge: .maxY)
        return rect
    }

    public override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        guard !(controlView is any CodeBlockBackgroundDrawing) else { return }
        let rect = backgroundRect(for: frameRect)
        MainActor.assumeIsolated { Self.drawFrame(rect, radius: Self.cornerRadius) }
    }
}

public struct RenderRun: Sendable {
    public let range: NSRange
    public let style: RenderStyle
    public let listDepth: Int
    public let headingLevel: Int
    public let destination: String?
    public let imagePath: String?
    public let tableColumns: Int
}

public struct OutlineHeading: Sendable, Equatable {
    public let title: String
    public let level: Int
    public let sourceRange: NSRange
    public let displayedRange: NSRange
}

public enum Typography {
    public static let body: CGFloat = 16
    public static let source: CGFloat = 15
    public static let listIndent: CGFloat = 32
    public static let headings: [(size: CGFloat, before: CGFloat, after: CGFloat)] = [
        (34, 20, 10), (28, 16, 8), (24, 12, 6),
        (20, 10, 6), (18, 8, 4), (16, 6, 4)
    ]
}

public struct RenderSnapshot: Sendable {
    public let source: String
    public let text: String
    public let runs: [RenderRun]
    public let sourceMap: SourceMap
    public let headings: [OutlineHeading]
    public let tableCells: [TableCellSnapshot]
    public let quoteRanges: [NSRange]
    public let codeBlocks: [CodeBlockSnapshot]
}

public struct CodeBlockSnapshot: Sendable {
    public let language: String
    public let range: NSRange
    public let languageSourceRange: NSRange
    public let hasAdditionalInfo: Bool
    public let closingFenceEnd: Int?
}

public struct TableCellSnapshot: Sendable {
    public let table: Int
    public let row: Int
    public let column: Int
    public let columns: Int
    public let range: NSRange
    public let alignment: NSTextAlignment
}

public struct RenderResult {
    public let attributedString: NSAttributedString
    public let sourceMap: SourceMap
    public var segments: [MappingSegment] { sourceMap.segments }
}

public enum MarkdownRenderer {
    public static func snapshot(source: String) -> RenderSnapshot {
        var source = source
        source.makeContiguousUTF8()
        var visitor = RenderVisitor(source: source)
        visitor.visit(MarkdownParser.parse(source))
        return visitor.snapshot
    }

    @MainActor public static func render(source: String) -> RenderResult {
        render(snapshot: snapshot(source: source))
    }

    @MainActor public static func render(
        snapshot: RenderSnapshot,
        imageProvider: ((String) -> NSImage?)? = nil
    ) -> RenderResult {
        let result = NSMutableAttributedString(string: snapshot.text, attributes: [
            .font: NSFont.systemFont(ofSize: Typography.body), .foregroundColor: NSColor.textColor
        ])
        let headingStyles = Typography.headings
        var fonts: [Int: NSFont] = [:]
        var paragraphs: [Int: NSParagraphStyle] = [:]
        for run in snapshot.runs {
            let headingStyle = run.headingLevel > 0 ? headingStyles[min(run.headingLevel, 6) - 1] : nil
            let size = headingStyle?.size ?? Typography.body
            let code = run.style.contains(.code), bold = run.style.contains(.bold) || run.headingLevel > 0, italic = run.style.contains(.italic)
            let fontKey = Int(size) << 3 | (code ? 4 : 0) | (bold ? 2 : 0) | (italic ? 1 : 0)
            let font: NSFont
            if let cached = fonts[fontKey] { font = cached } else {
                var traits: NSFontTraitMask = []
                if bold { traits.insert(.boldFontMask) }
                if italic { traits.insert(.italicFontMask) }
                font = NSFontManager.shared.convert(code ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size), toHaveTrait: traits)
                fonts[fontKey] = font
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            let quote = run.style.contains(.quote), table = run.style.contains(.table)
            let list = run.style.contains(.list)
            let paragraphKey = run.listDepth << 8 | run.headingLevel << 4 | (code ? 8 : 0) | (list ? 4 : 0) | (quote ? 2 : 0) | (table ? 1 : 0)
            let paragraph: NSParagraphStyle
            if let cached = paragraphs[paragraphKey] { paragraph = cached } else {
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = CGFloat(max(0, run.listDepth - 1)) * Typography.listIndent
                style.headIndent = style.firstLineHeadIndent
                style.paragraphSpacingBefore = headingStyle?.before ?? 0
                style.paragraphSpacing = table ? 0 : headingStyle?.after ?? 6
                if !table, headingStyle == nil, !code {
                    style.lineSpacing = list ? 5 : 3
                    if list { style.paragraphSpacing = 9 }
                }
                paragraph = style
                paragraphs[paragraphKey] = style
            }
            if table {
                attributes[NSAttributedString.Key("MarkdownTableColumns")] = run.tableColumns
                attributes[NSAttributedString.Key("MarkdownTableHeader")] = run.style.contains(.tableHeader)
            }
            attributes[.paragraphStyle] = paragraph
            if run.style.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.contains(.code), !run.style.contains(.codeBlock) { attributes[.markdownInlineCode] = true }
            if run.style.contains(.quote) { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
            if run.style.contains(.horizontalRule) {
                attributes[.markdownHorizontalRule] = true
                attributes[.foregroundColor] = NSColor.clear
                let attachment = NSTextAttachment()
                attachment.image = NSImage(size: NSSize(width: 1, height: 1))
                attachment.bounds = NSRect(x: 0, y: 0, width: 1, height: 1)
                attributes[.attachment] = attachment
                let ruleParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
                ruleParagraph.minimumLineHeight = 28
                ruleParagraph.lineSpacing = 0
                ruleParagraph.paragraphSpacingBefore = 12
                ruleParagraph.paragraphSpacing = 12
                attributes[.paragraphStyle] = ruleParagraph
            }
            if let destination = run.destination { attributes[.link] = destination }
            if let path = run.imagePath {
                let attachment = NSTextAttachment()
                attachment.image = imageProvider?(path)
                let size = attachment.image?.size ?? NSSize(width: 24, height: 24)
                attachment.bounds = NSRect(x: 0, y: -3, width: size.width, height: size.height)
                attributes[.attachment] = attachment
                attributes[NSAttributedString.Key("MarkdownImagePath")] = path
            }
            result.addAttributes(attributes, range: run.range)
            // Fallback fonts such as PingFang have no italic face; slant those characters instead.
            if italic, run.imagePath == nil {
                let covered = font.coveredCharacterSet
                let text = result.string as NSString
                var start = NSNotFound
                text.enumerateSubstrings(in: run.range, options: .byComposedCharacterSequences) { value, range, _, _ in
                    let missing = value?.unicodeScalars.contains { !covered.contains($0) } == true
                    if missing, start == NSNotFound { start = range.location }
                    if !missing, start != NSNotFound {
                        result.addAttribute(.obliqueness, value: 0.2, range: NSRange(location: start, length: range.location - start))
                        start = NSNotFound
                    }
                }
                if start != NSNotFound { result.addAttribute(.obliqueness, value: 0.2, range: NSRange(location: start, length: NSMaxRange(run.range) - start)) }
            }
        }
        applyCodeBlockFrames(to: result, runs: snapshot.runs, fencedStarts: Set(snapshot.codeBlocks.map { $0.range.location }))
        applyInlineCodeSpacing(to: result)
        for heading in snapshot.headings where heading.level <= 2 && heading.displayedRange.length > 0 {
            result.addAttribute(.markdownHeadingSeparator, value: true, range: heading.displayedRange)
        }
        for marker in snapshot.sourceMap.segments where marker.isListMarker {
            let range = marker.displayedNSRange
            let value = (snapshot.text as NSString).substring(with: range)
            result.addAttribute(.kern, value: 5, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            let symbol = NSRange(location: range.location, length: 1)
            if value.hasPrefix("\u{2022}") {
                result.addAttribute(.font, value: NSFont.systemFont(ofSize: 20, weight: .medium), range: symbol)
            } else if value.hasPrefix("\u{2610}") || value.hasPrefix("\u{2611}") {
                result.addAttributes([
                    .font: NSFont(name: "Apple Symbols", size: 20) ?? NSFont.systemFont(ofSize: 20),
                    .foregroundColor: NSColor.clear,
                    .markdownCheckbox: value.hasPrefix("\u{2611}")
                ], range: symbol)
            }
        }
        var tables: [Int: NSTextTable] = [:]
        for cell in snapshot.tableCells {
            let table = tables[cell.table] ?? NSTextTable()
            table.numberOfColumns = cell.columns
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.collapsesBorders = true
            table.setContentWidth(100, type: .percentageValueType)
            tables[cell.table] = table
            let block = MarkdownTableBlock(table: table, startingRow: cell.row, rowSpan: 1, startingColumn: cell.column, columnSpan: 1)
            block.setContentWidth(100 / CGFloat(cell.columns), type: .percentageValueType)
            block.setWidth(6, type: .absoluteValueType, for: .padding)
            block.setWidth(0.5, type: .absoluteValueType, for: .border)
            block.setBorderColor(.separatorColor)
            block.setValue(28, type: .absoluteValueType, for: .minimumHeight)
            if cell.row == 0 { block.backgroundColor = .controlBackgroundColor }
            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [block]
            paragraph.alignment = cell.alignment
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.paragraphSpacing = 0
            result.addAttribute(.paragraphStyle, value: paragraph, range: cell.range)
        }
        let text = result.string as NSString
        let quotes = snapshot.quoteRanges.sorted {
            $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
        }
        for quote in quotes where quote.length > 0 {
            let block = QuoteTextBlock()
            result.enumerateAttribute(.paragraphStyle, in: text.paragraphRange(for: quote)) { value, range, _ in
                let paragraph = ((value as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                let depth = paragraph.textBlocks.prefix { $0 is QuoteTextBlock }.count
                paragraph.textBlocks.insert(block, at: depth)
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
        }
        return RenderResult(attributedString: result.copy() as! NSAttributedString, sourceMap: snapshot.sourceMap)
    }

    @MainActor private static func applyInlineCodeSpacing(to result: NSMutableAttributedString) {
        let text = result.string as NSString
        let space = 2 * CodeBlockTextBlock.inlinePadding
        result.enumerateAttribute(.markdownInlineCode, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard value != nil, range.length > 0 else { return }
            result.addAttribute(.kern, value: space, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            if range.location > 0, ![10, 13].contains(text.character(at: range.location - 1)) {
                result.addAttribute(.kern, value: space, range: NSRange(location: range.location - 1, length: 1))
            }
        }
    }

    @MainActor private static func applyCodeBlockFrames(to result: NSMutableAttributedString, runs: [RenderRun], fencedStarts: Set<Int>) {
        var groups: [NSRange] = []
        for run in runs where run.style.contains(.codeBlock) && run.range.length > 0 {
            if let last = groups.last, NSMaxRange(last) == run.range.location, !fencedStarts.contains(run.range.location) { groups[groups.count - 1] = NSUnionRange(last, run.range) }
            else { groups.append(run.range) }
        }
        let text = result.string as NSString
        for group in groups {
            let block = CodeBlockTextBlock()
            let paragraphs = text.paragraphRange(for: group)
            result.enumerateAttribute(.paragraphStyle, in: paragraphs) { value, range, _ in
                let paragraph = ((value as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                paragraph.textBlocks = [block]
                paragraph.paragraphSpacing = 0
                paragraph.paragraphSpacingBefore = 0
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
        }
    }
}

private struct RenderVisitor: MarkupVisitor {
    typealias Result = Void
    static let quotePrefix = try! NSRegularExpression(pattern: "^ {0,3}(?:>[ \\t]?)+")
    static let quoteContinuation = try! NSRegularExpression(pattern: "^[ \\t]*(?:>[ \\t]?)+")
    static let emptyQuoteContinuation = try! NSRegularExpression(pattern: "^(?:\\r\\n|\\n|\\r)[ \\t]*(?:>[ \\t]*)+(?=\\r|\\n|$)")
    static let headingPrefix = try! NSRegularExpression(pattern: "^ {0,3}#{1,6}[ \\t]")
    static let listMarker = try! NSRegularExpression(pattern: "^(?:[-+*]|[0-9]{1,9}[.)])[ \\t](?:\\[[ xX]\\][ \\t])?")
    let source: String
    let original: NSString
    let sourceLength: Int
    let coordinates: SourceCoordinates
    let text = NSMutableString()
    var segments: [MappingSegment] = []
    var containers: [MappingContainer] = []
    var runs: [RenderRun] = []
    var headings: [OutlineHeading] = []
    var tableCells: [TableCellSnapshot] = []
    var quoteRanges: [NSRange] = []
    var codeBlocks: [CodeBlockSnapshot] = []
    var tableIndex = -1
    var tableRow = 0
    var style: RenderStyle = []
    var heading = 0
    var destination: String?
    var listNumber: Int?
    var listDepth = 0
    var continuationPrefix = ""
    var tableColumns = 0
    var tableAlignments: [NSTextAlignment] = []

    init(source: String) {
        self.source = source
        let units = Array(source.utf16)
        original = NSString(characters: units, length: units.count)
        sourceLength = units.count
        coordinates = SourceCoordinates(source: source)
    }
    var snapshot: RenderSnapshot {
        var displayed = text as String
        displayed.makeContiguousUTF8()
        return RenderSnapshot(source: source, text: displayed, runs: runs, sourceMap: SourceMap(segments: segments, sourceLength: sourceLength, displayedLength: text.length, containers: containers), headings: headings, tableCells: tableCells, quoteRanges: quoteRanges, codeBlocks: codeBlocks)
    }
    func range(_ markup: Markup) -> NSRange {
        let mapped = coordinates.nsRange(markup.range)
        if mapped == nil, let node = markup as? Markdown.Text, let position = node.range?.lowerBound,
           let start = coordinates.utf16Offset(line: position.line, utf8Column: 1) {
            let line = original.lineRange(for: NSRange(location: start, length: 0))
            let found = original.range(of: node.string, options: .literal, range: line)
            if found.location != NSNotFound, found.length > 0 { return found }
        }
        let content = mapped ?? NSRange(location: sourceLength, length: 0)
        if let heading = markup as? Heading, heading.level <= 2,
           let last = heading.child(at: max(0, heading.childCount - 1)) {
            let lastEnd = NSMaxRange(range(last))
            if lastEnd > content.location, lastEnd <= sourceLength {
                let contentLine = original.lineRange(for: NSRange(location: lastEnd - 1, length: 0))
                let underlineStart = NSMaxRange(contentLine)
                if underlineStart < sourceLength, underlineStart < NSMaxRange(content) {
                    let underline = original.lineRange(for: NSRange(location: underlineStart, length: 0))
                    var value = raw(underline).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let prefix = Self.quotePrefix.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)) {
                        value = (value as NSString).substring(from: NSMaxRange(prefix.range)).trimmingCharacters(in: .whitespaces)
                    }
                    let marker: Character = heading.level == 1 ? "=" : "-"
                    if !value.isEmpty, value.allSatisfy({ $0 == marker }) {
                        var end = NSMaxRange(underline)
                        while end > underlineStart, [10, 13].contains(original.character(at: end - 1)) { end -= 1 }
                        return NSRange(location: content.location, length: end - content.location)
                    }
                }
            }
        }
        guard let node = markup as? Markdown.Text else { return content }
        let line = original.lineRange(for: NSRange(location: content.location, length: 0))
          guard raw(content) != node.string else { return content }
        let indentation = original.substring(with: line).prefix { $0 == " " || $0 == "\t" }
          let adjusted = NSRange(location: line.location + indentation.utf16.count, length: content.length)
          if !indentation.isEmpty, content.location <= adjusted.location,
              NSMaxRange(adjusted) <= NSMaxRange(line), raw(adjusted) == node.string { return adjusted }
        // Container continuation lines (e.g. `>    text`) report the column after the container prefix.
        let tail = NSRange(location: content.location, length: NSMaxRange(line) - content.location)
        let found = original.range(of: node.string, options: .literal, range: tail)
        guard found.location != NSNotFound, found.length > 0,
              raw(NSRange(location: content.location, length: found.location - content.location)).allSatisfy({ $0 == " " || $0 == "\t" }) else { return content }
        return found
    }
    func raw(_ range: NSRange) -> String { original.substring(with: range) }

    func renderedBlockEnd(_ markup: Markup) -> Int {
        let outer = range(markup)
        let end = NSMaxRange(outer)
        guard let rendered = segments.last.map({ NSMaxRange($0.sourceNSRange) }),
              rendered >= outer.location, rendered < end,
              raw(NSRange(location: rendered, length: end - rendered)).allSatisfy({ $0.isWhitespace }) else { return end }
        return rendered
    }

    mutating func append(_ value: String, sourceRange: NSRange, kind: SegmentKind = .text, identity: Bool? = nil, image: String? = nil, isListMarker: Bool = false) {
        guard !value.isEmpty else { return }
        let displayed = NSRange(location: text.length, length: value.utf16.count)
        text.append(value)
        segments.append(MappingSegment(displayedNSRange: displayed, sourceNSRange: sourceRange, kind: kind, isIdentity: identity ?? (raw(sourceRange) == value), continuationPrefix: continuationPrefix, isListMarker: isListMarker))
        runs.append(RenderRun(range: displayed, style: style, listDepth: listDepth, headingLevel: heading, destination: destination, imagePath: image, tableColumns: tableColumns))
    }

    mutating func literal(_ value: String, sourceRange: NSRange, kind: SegmentKind = .text) {
        let original = raw(sourceRange) as NSString
        if original as String == value {
            append(value, sourceRange: sourceRange, kind: kind)
            return
        }
        var sourceOffset = 0
        var valueOffset = 0
        let decoded = value as NSString
        var local: [(String, NSRange)] = []
        while sourceOffset < original.length && valueOffset < decoded.length {
            var tokenRange = original.rangeOfComposedCharacterSequence(at: sourceOffset)
            if kind == .inlineCode, original.character(at: sourceOffset) == 13,
               sourceOffset + 1 < original.length, original.character(at: sourceOffset + 1) == 10 {
                tokenRange = NSRange(location: sourceOffset, length: 2)
            }
            var token = original.substring(with: tokenRange)
            if kind == .inlineCode, token == "\n" || token == "\r" || token == "\r\n" {
                token = " "
            } else if kind == .text, token == "\\", NSMaxRange(tokenRange) < original.length {
                let next = original.rangeOfComposedCharacterSequence(at: NSMaxRange(tokenRange))
                tokenRange = NSUnionRange(tokenRange, next)
                token = original.substring(with: next)
            } else if kind == .text, token == "&" {
                let remaining = NSRange(location: sourceOffset, length: original.length - sourceOffset)
                let end = original.range(of: ";", range: remaining)
                if end.location != NSNotFound, end.location - sourceOffset < 32 {
                    tokenRange = NSRange(location: sourceOffset, length: end.location - sourceOffset + 1)
                    let document = MarkdownParser.parse(original.substring(with: tokenRange))
                    if let paragraph = document.child(at: 0) as? Paragraph { token = paragraph.plainText }
                }
            }
            let tokenLength = token.utf16.count
            guard valueOffset + tokenLength <= decoded.length,
                  decoded.substring(with: NSRange(location: valueOffset, length: tokenLength)) == token else {
                append(value, sourceRange: sourceRange, kind: kind, identity: false)
                return
            }
            local.append((token, NSRange(location: sourceRange.location + tokenRange.location, length: tokenRange.length)))
            valueOffset += tokenLength
            sourceOffset = NSMaxRange(tokenRange)
        }
        let remainder = original.substring(from: sourceOffset)
        guard valueOffset == decoded.length,
              sourceOffset == original.length || (kind == .text && remainder.allSatisfy({ $0 == " " || $0 == "\t" })) else {
            append(value, sourceRange: sourceRange, kind: kind, identity: false)
            return
        }
        for (token, tokenRange) in local { append(token, sourceRange: tokenRange, kind: kind) }
        if sourceOffset < original.length {
            append(remainder, sourceRange: NSRange(location: sourceRange.location + sourceOffset, length: original.length - sourceOffset), kind: kind)
        }
    }

    mutating func children(_ markup: Markup, blockSpacing: Bool = false) {
        var previous: Markup?
        for child in markup.children {
            if blockSpacing, let previous {
                gap(from: renderedBlockEnd(previous), to: range(child).location)
            }
            else if let previous, markup is Paragraph || markup is Heading {
                appendInlineWhitespace(from: NSMaxRange(range(previous)), to: range(child).location)
            }
            visit(child)
            previous = child
        }
        if let previous, markup is Paragraph || markup is Heading {
            appendInlineWhitespace(from: NSMaxRange(range(previous)), to: NSMaxRange(range(markup)))
        }
    }

    mutating func appendInlineWhitespace(from start: Int, to end: Int) {
        guard end > start else { return }
        let span = NSRange(location: start, length: end - start)
        let value = String(raw(span).prefix { $0 == " " || $0 == "\t" })
        guard !value.isEmpty else { return }
        literal(value, sourceRange: NSRange(location: start, length: value.utf16.count))
    }

    mutating func gap(from start: Int, to end: Int) {
        guard end >= start else { return }
        let gapRange = NSRange(location: start, length: end - start)
        let gap = raw(gapRange) as NSString
        let firstNewline = gap.rangeOfCharacter(from: .newlines).location
        if firstNewline != NSNotFound {
            let prefix = gap.substring(to: firstNewline)
            if prefix.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                appendInlineWhitespace(from: start, to: start + firstNewline)
            }
        }
        var found = false
        for offset in 0..<gap.length where gap.character(at: offset) == 10 || (gap.character(at: offset) == 13 && (offset + 1 == gap.length || gap.character(at: offset + 1) != 10)) {
            let crlf = gap.character(at: offset) == 10 && offset > 0 && gap.character(at: offset - 1) == 13
            append("\n", sourceRange: NSRange(location: start + offset - (crlf ? 1 : 0), length: crlf ? 2 : 1), kind: .lineBreak)
            found = true
        }
        if !found { append("\n", sourceRange: NSRange(location: start, length: 0), kind: .decoration, identity: false) }
    }

    mutating func styled(_ markup: Markup, adding added: RenderStyle) {
        let saved = style
        let start = text.length
        style.formUnion(added)
        children(markup, blockSpacing: markup is BlockQuote)
        style = saved
        if markup is Strong || markup is Emphasis || markup is Strikethrough { recordContainer(markup, start: start) }
    }

    mutating func recordContainer(_ markup: Markup, start: Int) {
        containers.append(MappingContainer(displayedNSRange: NSRange(location: start, length: text.length - start), sourceNSRange: range(markup)))
    }

    mutating func defaultVisit(_ markup: Markup) {
        let sourceRange = range(markup)
        literal(raw(sourceRange), sourceRange: sourceRange)
    }
    mutating func visitDocument(_ document: Document) {
        if let first = document.child(at: 0) {
            let leading = NSRange(location: 0, length: range(first).location)
            if raw(leading).contains(where: { $0.isNewline }) { gap(from: 0, to: leading.length) }
            else if !(first is CodeBlock), raw(leading).allSatisfy({ $0 == " " || $0 == "\t" }) {
                literal(raw(leading), sourceRange: leading)
            }
        }
        children(document, blockSpacing: true)
        let end = document.childCount > 0 ? document.child(at: document.childCount - 1).map { renderedBlockEnd($0) } ?? 0 : 0
        if end < sourceLength {
            let tail = NSRange(location: end, length: sourceLength - end)
            if raw(tail).allSatisfy({ $0.isWhitespace }) { literal(raw(tail), sourceRange: tail, kind: .lineBreak) }
        }
    }
    mutating func visitParagraph(_ paragraph: Paragraph) {
        let start = range(paragraph).location
        let lineStart = original.lineRange(for: NSRange(location: start, length: 0)).location
        let mappedEnd = segments.last.map { NSMaxRange($0.sourceNSRange) } ?? 0
        let prefixStart = max(lineStart, mappedEnd)
        if prefixStart < start {
            let prefix = NSRange(location: prefixStart, length: start - prefixStart)
            let value = raw(prefix)
            if value.allSatisfy({ $0 == " " || $0 == "\t" }) { literal(value, sourceRange: prefix) }
            else if style.contains(.quote) {
                if let match = Self.quotePrefix.firstMatch(in: value, range: NSRange(location: 0, length: prefix.length)) {
                    appendInlineWhitespace(from: prefix.location + NSMaxRange(match.range), to: start)
                }
            }
        }
        if let first = paragraph.child(at: 0) { appendInlineWhitespace(from: max(start, mappedEnd), to: range(first).location) }
        children(paragraph)
    }
    mutating func visitHeading(_ node: Heading) {
        let saved = heading; let start = text.length
        heading = node.level
        if let first = node.child(at: 0) {
            let prefix = NSRange(location: range(node).location, length: max(0, range(first).location - range(node).location))
            if let match = Self.headingPrefix.firstMatch(in: raw(prefix), range: NSRange(location: 0, length: prefix.length)) {
                appendInlineWhitespace(from: prefix.location + NSMaxRange(match.range), to: NSMaxRange(prefix))
            }
        }
        children(node); heading = saved
        let displayedRange = NSRange(location: start, length: text.length - start)
        let title = text.substring(with: displayedRange)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        headings.append(OutlineHeading(title: title, level: node.level, sourceRange: range(node), displayedRange: displayedRange))
        recordContainer(node, start: start)
    }
    mutating func visitStrong(_ node: Strong) { styled(node, adding: .bold) }
    mutating func visitEmphasis(_ node: Emphasis) { styled(node, adding: .italic) }
    mutating func visitStrikethrough(_ node: Strikethrough) { styled(node, adding: .strike) }
    mutating func visitBlockQuote(_ node: BlockQuote) {
        let displayedStart = text.length
        let saved = continuationPrefix; continuationPrefix += "> "
        styled(node, adding: .quote)
        let outer = range(node)
        let end = NSMaxRange(outer)
        let limit = end > outer.location ? NSMaxRange(original.lineRange(for: NSRange(location: end - 1, length: 0))) : end
        var cursor = node.child(at: max(0, node.childCount - 1)).map { renderedBlockEnd($0) } ?? outer.location
        cursor = max(cursor, segments.last.map { NSMaxRange($0.sourceNSRange) } ?? cursor)
        let savedStyle = style
        style.insert(.quote)
        while cursor < limit {
            let tail = raw(NSRange(location: cursor, length: limit - cursor))
            guard let match = Self.emptyQuoteContinuation.firstMatch(in: tail, range: NSRange(location: 0, length: tail.utf16.count)) else { break }
            append("\n", sourceRange: NSRange(location: cursor, length: match.range.length), kind: .lineBreak, identity: false)
            cursor += match.range.length
        }
        style = savedStyle
        quoteRanges.append(NSRange(location: displayedStart, length: text.length - displayedStart))
        continuationPrefix = saved
    }
    mutating func visitText(_ node: Markdown.Text) {
        let content = range(node)
        if style.contains(.quote), let last = segments.last, last.kind == .lineBreak, NSMaxRange(last.sourceNSRange) < content.location {
            let gap = NSRange(location: NSMaxRange(last.sourceNSRange), length: content.location - NSMaxRange(last.sourceNSRange))
            if let match = Self.quoteContinuation.firstMatch(in: raw(gap), range: NSRange(location: 0, length: gap.length)) {
                appendInlineWhitespace(from: gap.location + NSMaxRange(match.range), to: content.location)
            }
        }
        // Only the start is needed; cmark's end column can fall inside a multibyte character on indented continuations.
        if let lower = node.range?.lowerBound, var parsedStart = coordinates.utf16Offset(line: lower.line, utf8Column: lower.column),
           content.location > parsedStart {
            // cmark offsets top-level continuation columns by the first line's indentation.
            if continuationPrefix.isEmpty {
                let lineStart = original.lineRange(for: NSRange(location: content.location, length: 0)).location
                if raw(NSRange(location: lineStart, length: content.location - lineStart)).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    parsedStart = min(parsedStart, lineStart)
                }
            }
            let start = max(parsedStart, segments.last.map { NSMaxRange($0.sourceNSRange) } ?? parsedStart)
            if start < content.location {
                let indentation = NSRange(location: start, length: content.location - start)
                let value = raw(indentation)
                if value.allSatisfy({ $0 == " " || $0 == "\t" }) { append(value, sourceRange: indentation) }
            }
        }
        literal(node.string, sourceRange: content)
    }
    mutating func visitLink(_ node: Markdown.Link) {
        let saved = destination; let start = text.length
        destination = node.destination; children(node); destination = saved
        recordContainer(node, start: start)
    }
    mutating func visitImage(_ node: Markdown.Image) { append("\u{FFFC}", sourceRange: range(node), kind: .attachment, identity: false, image: node.source ?? "") }
    mutating func visitThematicBreak(_ node: ThematicBreak) {
        let saved = style
        style.insert(.horizontalRule)
        let outer = range(node)
        let line = original.lineRange(for: NSRange(location: outer.location, length: 0))
        var end = min(NSMaxRange(outer), NSMaxRange(line))
        while end > outer.location, [10, 13].contains(original.character(at: end - 1)) { end -= 1 }
        append("\u{FFFC}", sourceRange: NSRange(location: outer.location, length: end - outer.location), kind: .attachment, identity: false)
        style = saved
    }
    mutating func visitSoftBreak(_ node: SoftBreak) { renderBreak(node) }
    mutating func visitLineBreak(_ node: LineBreak) { renderBreak(node) }
    mutating func renderBreak(_ node: Markup) {
        let sourceRange: NSRange
        if let explicit = coordinates.nsRange(node.range) { sourceRange = explicit }
        else {
            let start = segments.last.map { NSMaxRange($0.sourceNSRange) } ?? 0
            let end = node.parent.map { NSMaxRange(range($0)) } ?? sourceLength
            sourceRange = NSRange(location: start, length: max(0, end - start))
        }
        let original = raw(sourceRange) as NSString
        var newline = original.range(of: "\n")
        if newline.location == NSNotFound { newline = original.range(of: "\r") }
        guard newline.location != NSNotFound else {
            append("\n", sourceRange: NSRange(location: sourceRange.location, length: 0), kind: .decoration, identity: false)
            return
        }
        let crlf = newline.location != NSNotFound && newline.location > 0 && original.character(at: newline.location - 1) == 13
        let newlineStart = newline.location - (crlf ? 1 : 0)
        let hiddenBreak = original.substring(to: newlineStart)
        let hardBreak = node is LineBreak && (hiddenBreak == "\\" || hiddenBreak.allSatisfy { $0 == " " })
        if hiddenBreak.allSatisfy({ $0 == " " || $0 == "\t" }) {
            appendInlineWhitespace(from: sourceRange.location, to: sourceRange.location + newlineStart)
        }
        let start = hardBreak && hiddenBreak == "\\" ? sourceRange.location : sourceRange.location + newlineStart
        append("\n", sourceRange: NSRange(location: start, length: sourceRange.location + NSMaxRange(newline) - start), kind: .lineBreak)
    }
    mutating func visitInlineCode(_ node: InlineCode) {
        let saved = style; style.insert(.code)
        let start = text.length
        let outer = range(node)
        let rawText = raw(outer) as NSString
        var leading = 0
        while leading < rawText.length && rawText.character(at: leading) == 96 { leading += 1 }
        var content = NSRange(location: outer.location + leading, length: max(0, outer.length - leading * 2))
        if raw(content) != node.code {
            let found = (raw(content) as NSString).range(of: node.code)
            if found.location != NSNotFound { content = NSRange(location: content.location + found.location, length: found.length) }
        }
        literal(node.code, sourceRange: content, kind: .inlineCode)
        style = saved
        recordContainer(node, start: start)
    }
    mutating func visitCodeBlock(_ node: CodeBlock) {
        let saved = style; style.formUnion([.code, .codeBlock])
        let start = text.length
        let outer = range(node)
        let original = raw(outer) as NSString
        let firstLine = original.lineRange(for: NSRange(location: 0, length: 0))
        let opening = original.substring(with: firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        let fenced = opening.hasPrefix("```") || opening.hasPrefix("~~~")
        var cursor = fenced ? NSMaxRange(firstLine) : 0
        let lines = node.code.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1 && line.isEmpty { break }
            let value = String(line)
            guard cursor < original.length else { break }
            let physicalLine = original.lineRange(for: NSRange(location: cursor, length: 0))
            if !fenced { appendCodeIndentation(to: outer.location + cursor) }
            var found = value.isEmpty ? NSRange(location: cursor, length: 0) : original.range(of: value, range: physicalLine)
            var displayedValue = value
            if found.location == NSNotFound, !fenced {
                let body = String(value.drop(while: { $0 == " " || $0 == "\t" }))
                let bodyRange = original.range(of: body, range: physicalLine)
                if !body.isEmpty, bodyRange.location != NSNotFound, bodyRange.location >= cursor {
                    let indentation = original.substring(with: NSRange(location: cursor, length: bodyRange.location - cursor))
                    if indentation.contains("\t"), indentation.allSatisfy({ $0 == " " || $0 == "\t" }) {
                        let spaces = String(value.prefix { $0 == " " || $0 == "\t" })
                        append(spaces, sourceRange: NSRange(location: outer.location + cursor, length: bodyRange.location - cursor), kind: .code)
                        found = bodyRange
                        displayedValue = body
                    }
                }
            }
            guard found.location != NSNotFound else { continue }
            if !fenced { appendCodeIndentation(to: outer.location + found.location) }
            literal(displayedValue, sourceRange: NSRange(location: outer.location + found.location, length: found.length), kind: .code)
            cursor = NSMaxRange(physicalLine)
            if index < lines.count - 1 {
                var newline = original.range(of: "\n", range: physicalLine)
                if newline.location == NSNotFound { newline = original.range(of: "\r", range: physicalLine) }
                if newline.location != NSNotFound {
                    let crlf = original.character(at: newline.location) == 10 && newline.location > 0 && original.character(at: newline.location - 1) == 13
                    append("\n", sourceRange: NSRange(location: outer.location + newline.location - (crlf ? 1 : 0), length: crlf ? 2 : 1), kind: .code)
                }
            }
        }
        style = saved
        if fenced {
            recordContainer(node, start: start)
            let line = original.substring(with: firstLine)
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let fence = line.dropFirst(indent.count).prefix { $0 == opening.first }
            let after = line.dropFirst(indent.count + fence.count)
            let spacing = after.prefix { $0 == " " || $0 == "\t" }
            let label = after.dropFirst(spacing.count).prefix { !$0.isWhitespace }
            let location = outer.location + indent.utf16.count + fence.utf16.count + spacing.utf16.count
            let closing = original.substring(from: cursor).trimmingCharacters(in: .whitespaces)
            codeBlocks.append(CodeBlockSnapshot(language: node.language?.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? "",
                                                range: NSRange(location: start, length: text.length - start),
                                                languageSourceRange: NSRange(location: location, length: label.utf16.count),
                                                hasAdditionalInfo: after.dropFirst(spacing.count + label.count).contains { !$0.isWhitespace },
                                                closingFenceEnd: closing.count >= fence.count && closing.allSatisfy { $0 == fence.first }
                                                    ? NSMaxRange(outer) : nil))
        }
    }
    // Indented-code indentation is syntax, but showing it keeps the text where the source places it.
    mutating func appendCodeIndentation(to end: Int) {
        guard !style.contains(.quote) else { return }
        let lineStart = (source as NSString).lineRange(for: NSRange(location: end, length: 0)).location
        let start = max(lineStart, segments.last.map { NSMaxRange($0.sourceNSRange) } ?? 0)
        guard start < end else { return }
        let indentation = NSRange(location: start, length: end - start)
        let value = raw(indentation)
        guard value.allSatisfy({ $0 == " " || $0 == "\t" }) else { return }
        let saved = style; style.remove(.code)
        append(value, sourceRange: indentation, kind: .code)
        style = saved
    }
    mutating func visitOrderedList(_ node: OrderedList) {
        let saved = listNumber; listNumber = Int(node.startIndex); children(node, blockSpacing: true); listNumber = saved
    }
    mutating func visitUnorderedList(_ node: UnorderedList) { let saved = listNumber; listNumber = nil; children(node, blockSpacing: true); listNumber = saved }
    mutating func visitListItem(_ node: ListItem) {
        listDepth += 1
        defer { listDepth -= 1 }
        let start = range(node).location
        let prefix: String
        if let checkbox = node.checkbox { prefix = checkbox == .checked ? "\u{2611} " : "\u{2610} " }
        else if let number = listNumber { prefix = "\(number). "; listNumber = number + 1 }
        else { prefix = "\u{2022} " }
        var content = node.child(at: 0)?.child(at: 0).map { range($0).location } ?? NSMaxRange(range(node))
        if let block = node.child(at: 0) as? CodeBlock {
            content = range(block).location
        }
        if node.childCount == 0 {
            let line = original.lineRange(for: NSRange(location: start, length: 0))
            while content < NSMaxRange(line), [9, 32].contains(original.character(at: content)) { content += 1 }
        }
        var markerEnd = content
        if node.child(at: 0) is Paragraph || node.child(at: 0) is CodeBlock, content > start {
            let rawPrefix = raw(NSRange(location: start, length: content - start))
            if let match = Self.listMarker.firstMatch(in: rawPrefix, range: NSRange(location: 0, length: content - start)) {
                markerEnd = start + NSMaxRange(match.range)
            }
        }
        append(prefix, sourceRange: NSRange(location: start, length: max(0, markerEnd - start)), kind: .decoration, identity: false, isListMarker: true)
        let saved = continuationPrefix
        continuationPrefix += String(repeating: " ", count: max(2, content - start))
        let savedStyle = style
        style.insert(.list)
        children(node, blockSpacing: true)
        style = savedStyle
        continuationPrefix = saved
    }
    mutating func visitTable(_ node: Table) {
        let saved = style; style.insert(.table)
        let savedColumns = tableColumns
        let savedAlignments = tableAlignments
        tableColumns = node.head.childCount
        tableAlignments = node.columnAlignments.map {
            switch $0 {
            case .center: return .center
            case .right: return .right
            default: return .left
            }
        }
        tableIndex += 1
        tableRow = 0
        visit(node.head)
        for row in node.body.children {
            tableRow += 1
            visit(row)
        }
        style = saved
        tableColumns = savedColumns
        tableAlignments = savedAlignments
    }
    mutating func visitTableHead(_ node: Table.Head) { let saved = style; style.formUnion([.bold, .tableHeader]); cells(node); style = saved }
    mutating func visitTableRow(_ node: Table.Row) { cells(node) }
    mutating func visitTableCell(_ node: Table.Cell) {
        if let first = node.child(at: 0) {
            let start = range(node).location
            let end = range(first).location
            if end > start {
                let prefix = raw(NSRange(location: start, length: end - start))
                let separator = prefix.first == " " || prefix.first == "\t" ? 1 : 0
                appendInlineWhitespace(from: start + separator, to: end)
            }
        }
        children(node)
    }
    mutating func cells(_ node: Markup) {
        for (index, child) in node.children.enumerated() {
            let start = text.length
            visit(child)
            if child.childCount == 0 {
                if let cell = coordinates.nsRange(child.range) {
                    append(" ", sourceRange: NSRange(location: cell.location, length: 0), identity: false)
                } else { append(" ", sourceRange: NSRange(location: range(child).location, length: 0), kind: .decoration, identity: false) }
            }
            append("\n", sourceRange: NSRange(location: NSMaxRange(range(child)), length: 0), kind: .tableSeparator, identity: false)
            tableCells.append(TableCellSnapshot(table: tableIndex, row: tableRow, column: index, columns: tableColumns, range: NSRange(location: start, length: text.length - start), alignment: index < tableAlignments.count ? tableAlignments[index] : .left))
        }
    }
}