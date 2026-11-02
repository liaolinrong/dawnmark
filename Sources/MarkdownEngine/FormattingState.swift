import Foundation
import Markdown

public enum FormattingState: Sendable, Equatable {
    case on, off, mixed, unavailable
}

extension DocumentSession {
    public func formattingState(_ command: FormattingCommand, in selection: NSRange? = nil) -> FormattingState {
        let selection = selection ?? selectedSourceRange
        guard Range(selection, in: source) != nil else { return .unavailable }
        switch command {
        case .tableInsertRow, .tableDeleteRow, .tableInsertColumn, .tableDeleteColumn, .tableDelete:
            return canEdit && editTable(command, selection: selection, checkingOnly: true) ? .off : .unavailable
        case .heading(let level) where !(1...6).contains(level): return .unavailable
        default: break
        }
        let coordinates = SourceCoordinates(source: source)
        var matches: [NSRange] = []
        var codeIntersects = false
        func intersects(_ range: NSRange) -> Bool {
            selection.length == 0
                ? selection.location >= range.location && selection.location <= NSMaxRange(range)
                : NSIntersectionRange(range, selection).length > 0
        }
        func visit(_ node: Markup) {
            if let range = coordinates.nsRange(node.range), intersects(range) {
                if node is CodeBlock { codeIntersects = true }
                let matched: Bool
                switch command {
                case .heading(let level): matched = (node as? Heading)?.level == level
                case .body: matched = node is Heading
                case .bold: matched = node is Strong
                case .italic: matched = node is Emphasis
                case .strikethrough: matched = node is Strikethrough
                case .inlineCode: matched = node is InlineCode
                case .codeBlock: matched = node is CodeBlock
                case .quote: matched = node is BlockQuote
                case .unorderedList: matched = node is UnorderedList
                case .orderedList: matched = node is OrderedList
                case .taskList: matched = (node as? ListItem)?.checkbox != nil
                default: matched = false
                }
                if matched { matches.append(range) }
            }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(source))
        switch command {
        case .bold, .italic, .strikethrough, .inlineCode, .insertLink, .insertImage:
            if codeIntersects { return .unavailable }
        default: break
        }
        let isBody: Bool
        switch command { case .body: isBody = true; default: isBody = false }
        guard !matches.isEmpty else { return isBody ? .on : .off }
        if selection.length == 0 { return isBody ? .off : .on }
        let original = source as NSString
        var cursor = selection.location
        var uncovered = false
        for range in matches.sorted(by: { $0.location < $1.location }) {
            let clipped = NSIntersectionRange(range, selection)
            if clipped.location > cursor {
                let gap = original.substring(with: NSRange(location: cursor, length: clipped.location - cursor))
                uncovered = uncovered || !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            cursor = max(cursor, NSMaxRange(clipped))
        }
        if cursor < NSMaxRange(selection) {
            let gap = original.substring(with: NSRange(location: cursor, length: NSMaxRange(selection) - cursor))
            uncovered = uncovered || !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return uncovered ? .mixed : (isBody ? .off : .on)
    }
}