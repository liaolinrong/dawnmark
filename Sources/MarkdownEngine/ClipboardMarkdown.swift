import Foundation
import Markdown

public enum ClipboardMarkdown {
    public static func extract(snapshot: RenderSnapshot, displayedRange: NSRange) -> String? {
        guard displayedRange.location >= 0, displayedRange.length > 0,
              displayedRange.location <= snapshot.text.utf16.count,
              displayedRange.length <= snapshot.text.utf16.count - displayedRange.location,
              Range(displayedRange, in: snapshot.text) != nil,
              (snapshot.text as NSString).rangeOfComposedCharacterSequences(for: displayedRange) == displayedRange else { return nil }
        for segment in snapshot.sourceMap.segments {
            let intersection = NSIntersectionRange(displayedRange, segment.displayedNSRange)
            guard intersection.length > 0 else { continue }
            if segment.kind == .attachment { return nil }
            if !segment.isIdentity && intersection != segment.displayedNSRange { return nil }
        }
        let extractor = Extractor(snapshot: snapshot, selection: displayedRange)
        if displayedRange == NSRange(location: 0, length: snapshot.text.utf16.count) {
            return snapshot.source
        }
        return extractor.render(MarkdownParser.parse(snapshot.source))?.markdown
    }
}

private struct Extractor {
    struct Fragment {
        let range: NSRange
        let markdown: String
    }

    let snapshot: RenderSnapshot
    let selection: NSRange
    let coordinates: SourceCoordinates

    init(snapshot: RenderSnapshot, selection: NSRange) {
        self.snapshot = snapshot
        self.selection = selection
        coordinates = SourceCoordinates(source: snapshot.source)
    }

    func segments(in sourceRange: NSRange) -> [MappingSegment] {
        snapshot.sourceMap.segments.filter {
            if $0.sourceNSRange.length == 0 {
                return NSLocationInRange($0.sourceNSRange.location, sourceRange)
            }
            return NSIntersectionRange($0.sourceNSRange, sourceRange).length > 0
        }
    }

    func span(_ node: Markup) -> NSRange? {
        guard let sourceRange = coordinates.nsRange(node.range) else { return nil }
        if let container = snapshot.sourceMap.containers.first(where: { $0.sourceNSRange == sourceRange }) {
            return container.displayedNSRange
        }
        let mapped = segments(in: sourceRange)
        guard let first = mapped.first, let last = mapped.last else { return nil }
        var result = NSUnionRange(first.displayedNSRange, last.displayedNSRange)
        if node is Table, last.kind == .tableSeparator {
            result.length -= last.displayedNSRange.length
        }
        return result
    }

    func raw(_ range: NSRange) -> String {
        guard let indices = Range(range, in: snapshot.source) else { return "" }
        return String(snapshot.source[indices])
    }

    func literal(_ range: NSRange, code: Bool = false) -> String {
        let result = snapshot.sourceMap.segments.compactMap { segment -> String? in
            guard segment.kind != .decoration else { return nil }
            let intersection = NSIntersectionRange(range, segment.displayedNSRange)
            guard intersection.length > 0, let indices = Range(intersection, in: snapshot.text) else { return nil }
            let text = String(snapshot.text[indices])
            return code ? text : SourceMap.escapeText(text)
        }.joined()
        return result
    }

    func wrap(_ content: String, delimiter: String) -> String {
        let leading = content.prefix { $0.isWhitespace }
        let remaining = content.dropFirst(leading.count)
        let trailing = remaining.reversed().prefix { $0.isWhitespace }.reversed()
        let body = remaining.dropLast(trailing.count)
        guard !body.isEmpty else { return content }
        return String(leading) + delimiter + body + delimiter + String(trailing)
    }

    func needsLinkDefinition(_ node: Markup) -> Bool {
        if let link = node as? Markdown.Link,
           let sourceRange = coordinates.nsRange(link.range) {
            let lastChild = link.childCount > 0 ? link.child(at: link.childCount - 1) : nil
            let end = lastChild.flatMap { coordinates.nsRange($0.range) }.map { NSMaxRange($0) }
                ?? sourceRange.location + 1
            let suffix = raw(NSRange(location: end, length: max(0, NSMaxRange(sourceRange) - end)))
            return !suffix.hasPrefix("](")
        }
        return node.children.contains { needsLinkDefinition($0) }
    }

    func render(_ node: Markup) -> Fragment? {
        if node is Document {
            if let fragment = children(node, within: selection) { return fragment }
            let content = literal(selection)
            return content.isEmpty ? nil : Fragment(range: selection, markdown: content)
        }
        guard let bounds = span(node) else { return nil }
        let selected = NSIntersectionRange(selection, bounds)
        guard selected.length > 0 else { return nil }
        if selected == bounds, !(node is Markdown.Text), !(node is Table.Cell),
           !(node is Table.Row), !(node is Table.Head), !(node is Table.Body),
              !needsLinkDefinition(node),
           var sourceRange = coordinates.nsRange(node.range) {
            let mappedEnd = segments(in: sourceRange)
                .filter { NSIntersectionRange(selected, $0.displayedNSRange).length > 0 }
                .map { NSMaxRange($0.sourceNSRange) }.max() ?? NSMaxRange(sourceRange)
            while NSMaxRange(sourceRange) > mappedEnd,
                  raw(NSRange(location: NSMaxRange(sourceRange) - 1, length: 1)).allSatisfy({ $0.isNewline }) {
                sourceRange.length -= 1
            }
            if node is Heading {
                let physical = (snapshot.source as NSString).lineRange(for: sourceRange)
                let suffixRange = NSRange(location: NSMaxRange(sourceRange), length: NSMaxRange(physical) - NSMaxRange(sourceRange))
                let suffix = raw(suffixRange).trimmingCharacters(in: .newlines)
                if suffix.contains("#"), suffix.allSatisfy({ $0 == "#" || $0 == " " || $0 == "\t" }) {
                    sourceRange.length += suffix.utf16.count
                }
            }
            return Fragment(range: selected, markdown: raw(sourceRange))
        }

        let content = children(node, within: selected)?.markdown ?? literal(selected)
        let markdown: String
        if node is Strong { markdown = wrap(content, delimiter: "**") }
        else if node is Emphasis { markdown = wrap(content, delimiter: "*") }
        else if node is Strikethrough { markdown = wrap(content, delimiter: "~~") }
        else if let heading = node as? Heading, selected == bounds {
            markdown = String(repeating: "#", count: heading.level) + " " + content
        }
        else if let link = node as? Markdown.Link {
            let destination = (link.destination ?? "")
                .replacingOccurrences(of: "<", with: "%3C")
                .replacingOccurrences(of: ">", with: "%3E")
                .replacingOccurrences(of: "\n", with: "%0A")
                .replacingOccurrences(of: "\\", with: "%5C")
            let title = link.title.map { " \"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? ""
            markdown = "[" + content + "](<" + destination + ">" + title + ")"
        } else if node is InlineCode {
            let code = literal(selected, code: true).replacingOccurrences(of: "\n", with: " ")
            let longest = code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: longest + 1)
            let padding = code.hasPrefix("`") || code.hasSuffix("`") || (code.hasPrefix(" ") && code.hasSuffix(" ") && !code.allSatisfy { $0 == " " }) ? " " : ""
            markdown = fence + padding + code + padding + fence
        } else if let block = node as? CodeBlock {
            let code = literal(selected, code: true)
            let longest = code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            markdown = fence + (block.language ?? "") + "\n" + code + (code.hasSuffix("\n") ? "" : "\n") + fence
        } else if node is BlockQuote {
            markdown = "> " + content.replacingOccurrences(of: "\n", with: "\n> ")
        } else if node is ListItem,
                  let sourceRange = coordinates.nsRange(node.range),
                  let decoration = segments(in: sourceRange).first,
                  decoration.kind == .decoration,
                  NSIntersectionRange(selection, decoration.displayedNSRange) == decoration.displayedNSRange {
            markdown = raw(decoration.sourceNSRange) + content
        } else {
            markdown = content
        }
        return Fragment(range: selected, markdown: markdown)
    }

    func children(_ node: Markup, within bounds: NSRange) -> Fragment? {
        let fragments = node.children.compactMap { render($0) }
        guard !fragments.isEmpty else { return nil }
        var cursor = bounds.location
        var result = ""
        for fragment in fragments {
            if fragment.range.location > cursor {
                result += literal(NSRange(location: cursor, length: fragment.range.location - cursor))
            }
            result += fragment.markdown
            cursor = max(cursor, NSMaxRange(fragment.range))
        }
        if cursor < NSMaxRange(bounds) {
            result += literal(NSRange(location: cursor, length: NSMaxRange(bounds) - cursor))
        }
        return Fragment(range: bounds, markdown: result)
    }
}