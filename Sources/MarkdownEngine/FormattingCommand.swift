import Foundation
import Markdown

public enum FormattingCommand: Sendable {
    case body
    case heading(level: Int)
    case bold, italic, strikethrough, inlineCode
    case unorderedList, orderedList, taskList, quote, codeBlock, horizontalRule
    case indent, outdent, clearFormatting
    case insertLink(destination: String, label: String? = nil)
    case insertImage(path: String)
    case insertTable(columns: Int = 2, rows: Int = 2)
    case tableInsertRow, tableDeleteRow, tableInsertColumn, tableDeleteColumn, tableDelete
    case tableInsertRowAbove, tableInsertColumnBefore
}

public struct MarkdownLinkContext: Sendable {
    public let sourceRange: NSRange
    public let labelSourceRange: NSRange
    public let displayText: String
    public let destination: String
}

extension DocumentSession {
    public func link(in selection: NSRange) -> MarkdownLinkContext? {
        guard Range(selection, in: source) != nil else { return nil }
        let coordinates = SourceCoordinates(source: source)
        var result: MarkdownLinkContext?
        func visit(_ node: Markup) {
            if let link = node as? Markdown.Link, let outer = coordinates.nsRange(link.range),
               outer.location <= selection.location, selection.location < NSMaxRange(outer),
               NSMaxRange(selection) <= NSMaxRange(outer), let destination = link.destination {
                let label: NSRange
                if let first = link.child(at: 0), let last = link.child(at: link.childCount - 1),
                   let start = coordinates.nsRange(first.range), let end = coordinates.nsRange(last.range) {
                    label = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
                } else {
                    label = NSRange(location: outer.location + 1, length: 0)
                }
                result = MarkdownLinkContext(sourceRange: outer, labelSourceRange: label,
                                             displayText: link.plainText, destination: destination)
            }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(source))
        return result
    }

    @discardableResult public func removeLink(in selection: NSRange) -> Bool {
        guard canEdit, let link = link(in: selection) else { return false }
        let label = (source as NSString).substring(with: link.labelSourceRange)
        return apply([SourcePatch(range: link.sourceRange, replacement: label)],
                     selectionAfter: NSRange(location: link.sourceRange.location, length: label.utf16.count))
    }

    @discardableResult public func indentList(in selection: NSRange, outdent: Bool) -> Bool {
        guard Range(selection, in: source) != nil else { return false }
        let coordinates = SourceCoordinates(source: source)
        var insideList = false
        var insideCode = false
        var indentedList = false
        func visit(_ node: Markup) {
            if let range = coordinates.nsRange(node.range),
               selection.length == 0 ? selection.location >= range.location && selection.location <= NSMaxRange(range)
                   : NSIntersectionRange(range, selection).length > 0 {
                if node is ListItem { insideList = true }
                if node is CodeBlock {
                    insideCode = true
                    let original = source as NSString
                    let start = original.lineRange(for: NSRange(location: range.location, length: 0)).location
                    let raw = original.substring(with: NSRange(location: start, length: NSMaxRange(range) - start))
                    indentedList = outdent && raw.range(of: "^[ \\t]+(?:[-+*]|[0-9]+[.)])[ \\t]+", options: .regularExpression) != nil
                }
            }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(source))
        guard insideCode ? indentedList : insideList else { return false }
        if outdent { return perform(.outdent, in: selection) }
        return formatLines(.indent, selection: selection, startingOrderedSublist: true)
    }

    @discardableResult public func perform(_ command: FormattingCommand, in selection: NSRange? = nil) -> Bool {
        let selection = selection ?? selectedSourceRange
        guard canEdit, let selectedRange = Range(selection, in: source) else { return false }
        guard formattingState(command, in: selection) != .unavailable else { return false }
        let selected = String(source[selectedRange])
        switch command {
        case .tableInsertRow, .tableInsertRowAbove, .tableDeleteRow, .tableInsertColumn, .tableInsertColumnBefore, .tableDeleteColumn, .tableDelete:
            return editTable(command, selection: selection)
        case .bold: return toggleInline(selection, marker: "**", matches: { $0 is Strong })
        case .italic: return toggleInline(selection, marker: "*", matches: { $0 is Emphasis })
        case .strikethrough: return toggleInline(selection, marker: "~~", matches: { $0 is Strikethrough })
        case .inlineCode:
            if removeInline(selection, matches: { $0 is InlineCode }) { return true }
            guard selection.length > 0 else { return false }
            let marker = String(repeating: "`", count: longestRun(of: "`", in: selected) + 1)
            let padded = selected.hasPrefix("`") || selected.hasSuffix("`") || (selected.hasPrefix(" ") && selected.hasSuffix(" ") && !selected.allSatisfy({ $0 == " " }))
            return wrap(selection, prefix: marker + (padded ? " " : ""), suffix: (padded ? " " : "") + marker)
        case .insertLink(let destination, let displayText):
            let explicitLabel = displayText.map { $0.isEmpty ? destination : $0 }
            if replaceDestination(in: selection, destination: destination, image: false, displayText: explicitLabel) { return true }
            let label = explicitLabel.map(SourceMap.escapeText) ?? (selected.isEmpty ? SourceMap.escapeText(destination) : escapedLinkLabel(selected))
            let replacement = "[" + label + "](<\(escapedDestination(destination))>)"
            let parsed = MarkdownParser.parse(replacement)
            guard parsed.childCount == 1, let paragraph = parsed.child(at: 0) as? Paragraph,
                  paragraph.childCount == 1, paragraph.child(at: 0) is Markdown.Link else { return false }
            return apply([SourcePatch(range: selection, replacement: replacement)], selectionAfter: NSRange(location: selection.location + 1, length: label.utf16.count))
        case .insertImage(let path):
            if replaceDestination(in: selection, destination: path, image: true) { return true }
            return apply([SourcePatch(range: selection, replacement: "![\(SourceMap.escapeText(selected))](<\(escapedDestination(path))>)")])
        case .horizontalRule:
            let newline = source.contains("\r\n") ? "\r\n" : source.contains("\r") && !source.contains("\n") ? "\r" : "\n"
            return insertSeparatedBlock("***", in: selection, newline: newline)
        case .insertTable(let columns, let rows):
            guard columns > 0, columns <= 64, rows > 0, rows <= 1000 else { return false }
            let newline = source.contains("\r\n") ? "\r\n" : source.contains("\r") && !source.contains("\n") ? "\r" : "\n"
            let row = "|" + String(repeating: "   |", count: columns)
            let delimiter = "|" + String(repeating: " --- |", count: columns)
            let table = ([row, delimiter] + Array(repeating: row, count: rows - 1)).joined(separator: newline)
            return insertSeparatedBlock(table, in: selection, newline: newline)
        case .codeBlock:
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: selected) + 1))
            let newline = selected.contains("\r\n") || source.contains("\r\n") ? "\r\n" : "\n"
            let closingBreak = !selected.isEmpty && ((selected as NSString).hasSuffix("\n") || (selected as NSString).hasSuffix("\r")) ? "" : newline
            return wrap(selection, prefix: newline + fence + newline, suffix: closingBreak + fence + newline)
        case .clearFormatting: return clearFormatting(selection)
        default: return formatLines(command, selection: selection)
        }
    }

    private func insertSeparatedBlock(_ block: String, in selection: NSRange, newline: String) -> Bool {
        guard let range = Range(selection, in: source) else { return false }
        let before = source[..<range.lowerBound]
        let after = source[range.upperBound...]
        let leading = before.isEmpty ? 0 : max(0, 2 - before.reversed().prefix { $0.isNewline }.count)
        let trailing = after.isEmpty ? 0 : max(0, 2 - after.prefix { $0.isNewline }.count)
        let replacement = String(repeating: newline, count: leading) + block + String(repeating: newline, count: trailing)
        return apply([SourcePatch(range: selection, replacement: replacement)])
    }

    private func replaceDestination(in selection: NSRange, destination: String, image: Bool, displayText: String? = nil) -> Bool {
        let coordinates = SourceCoordinates(source: source)
        var candidate: Markup?
        func visit(_ node: Markup) {
            if let range = coordinates.nsRange(node.range), range.location <= selection.location,
               NSMaxRange(range) >= NSMaxRange(selection), image ? node is Image : node is Markdown.Link {
                candidate = node
            }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(source))
        guard let node = candidate, let outer = coordinates.nsRange(node.range) else { return false }
        let label: NSRange
        if let first = node.child(at: 0), let last = node.child(at: node.childCount - 1),
           let start = coordinates.nsRange(first.range), let end = coordinates.nsRange(last.range) {
            label = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        } else {
            label = NSRange(location: outer.location + (image ? 2 : 1), length: 0)
        }
        let title = (node as? Markdown.Link)?.title ?? (node as? Image)?.title
        let escapedTitle = title.map {
            " \"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        } ?? ""
        let prefix = image ? "![" : "["
        let labelText = displayText.map(SourceMap.escapeText) ?? (source as NSString).substring(with: label)
        let replacement = prefix + labelText + "](<\(escapedDestination(destination))>\(escapedTitle))"
        let start = max(label.location, min(selection.location, NSMaxRange(label)))
        let end = max(start, min(NSMaxRange(selection), NSMaxRange(label)))
        let selectionAfter = image ? NSRange(location: outer.location, length: replacement.utf16.count)
            : displayText != nil ? NSRange(location: outer.location + prefix.utf16.count, length: labelText.utf16.count)
            : NSRange(location: outer.location + prefix.utf16.count + start - label.location, length: end - start)
        return apply([SourcePatch(range: outer, replacement: replacement)], selectionAfter: selectionAfter)
    }

    private func escapedDestination(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\r", with: "%0D")
    }
    private func escapedLinkLabel(_ value: String) -> String {
        let coordinates = SourceCoordinates(source: value)
        var protected: [NSRange] = []
        func visit(_ node: Markup) {
            if node is InlineCode || node is Image, let range = coordinates.nsRange(node.range) {
                protected.append(range)
                return
            }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(value))
        var result = ""
        var escaped = false
        var offset = 0
        for character in value {
            if !escaped, !protected.contains(where: { NSLocationInRange(offset, $0) }),
               character == "[" || character == "]" { result.append("\\") }
            result.append(character)
            offset += String(character).utf16.count
            if character == "\\" { escaped.toggle() }
            else { escaped = false }
        }
        return result
    }
    private func longestRun(of marker: Character, in value: String) -> Int {
        var longest = 0; var current = 0
        for character in value { current = character == marker ? current + 1 : 0; longest = max(longest, current) }
        return longest
    }
    private func wrap(_ range: NSRange, prefix: String, suffix: String) -> Bool {
        let value = (source as NSString).substring(with: range)
        return apply([SourcePatch(range: range, replacement: prefix + value + suffix)], selectionAfter: NSRange(location: range.location + prefix.utf16.count, length: range.length))
    }
    private func toggleInline(_ selection: NSRange, marker: String, matches: (Markup) -> Bool) -> Bool {
        if removeInline(selection, matches: matches) { return true }
        guard selection.length > 0 else { return false }
        let value = (source as NSString).substring(with: selection)
        let leading = value.prefix { $0.isWhitespace }.utf16.count
        let trailing = value.reversed().prefix { $0.isWhitespace }.reduce(0) { $0 + String($1).utf16.count }
        guard leading + trailing < selection.length else { return false }
        let content = NSRange(location: selection.location + leading, length: selection.length - leading - trailing)
        let replacement = marker + (source as NSString).substring(with: content) + marker
        let candidate = (source as NSString).replacingCharacters(in: content, with: replacement)
        let coordinates = SourceCoordinates(source: candidate)
        let expected = NSRange(location: content.location, length: replacement.utf16.count)
        var valid = false
        func visit(_ node: Markup) {
            if matches(node), let range = coordinates.nsRange(node.range),
               NSIntersectionRange(range, expected) == expected { valid = true }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(candidate))
        guard valid else { return false }
        return wrap(content, prefix: marker, suffix: marker)
    }
    private func removeInline(_ selection: NSRange, matches: (Markup) -> Bool) -> Bool {
        let coordinates = SourceCoordinates(source: source)
        var candidate: Markup?
        func visit(_ node: Markup) {
            guard let range = coordinates.nsRange(node.range), range.location <= selection.location, NSMaxRange(range) >= NSMaxRange(selection) else { return }
            if matches(node) { candidate = node }
            for child in node.children { visit(child) }
        }
        for node in MarkdownParser.parse(source).children { visit(node) }
        guard let node = candidate, let outer = coordinates.nsRange(node.range) else { return false }
        let content: NSRange
        if let code = node as? InlineCode {
            let raw = (source as NSString).substring(with: outer) as NSString
            let found = raw.range(of: code.code)
            guard found.location != NSNotFound else { return false }
            content = NSRange(location: outer.location + found.location, length: found.length)
        } else {
            guard let first = node.child(at: 0), let last = node.child(at: node.childCount - 1),
                  let start = coordinates.nsRange(first.range), let end = coordinates.nsRange(last.range) else { return false }
            content = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        }
        let prefix = NSRange(location: outer.location, length: content.location - outer.location)
        let suffix = NSRange(location: NSMaxRange(content), length: NSMaxRange(outer) - NSMaxRange(content))
        let start = max(content.location, min(selection.location, NSMaxRange(content)))
        let end = max(start, min(NSMaxRange(selection), NSMaxRange(content)))
        return apply([SourcePatch(range: prefix, replacement: ""), SourcePatch(range: suffix, replacement: "")], selectionAfter: NSRange(location: start - prefix.length, length: end - start))
    }

    private func formatLines(_ command: FormattingCommand, selection: NSRange, startingOrderedSublist: Bool = false) -> Bool {
        if case .body = command { return removeHeadingSyntax(in: selection) }
        if case .heading = command, formattingState(command, in: selection) == .on {
            return removeHeadingSyntax(in: selection)
        }
        let original = source as NSString
        let probe = NSRange(location: selection.location, length: selection.length > 0 ? selection.length - 1 : 0)
        let lineRange = original.lineRange(for: probe)
        let value = original.substring(with: lineRange)
        var lines = value.components(separatedBy: "\n")
        let hasFinalNewline = (value as NSString).hasSuffix("\n")
        if hasFinalNewline { lines.removeLast() }
        let pattern: String
        let prefix: (Int) -> String
        switch command {
        case .heading(let level):
            guard (1...6).contains(level) else { return false }
            pattern = "^ {0,3}#{1,6}[ \\t]+"; prefix = { _ in String(repeating: "#", count: level) + " " }
        case .unorderedList: pattern = "^([ \\t]*)([-+*]|[0-9]+[.)])[ \\t]+(\\[[ xX]\\][ \\t]+)?"; prefix = { _ in "- " }
        case .orderedList: pattern = "^([ \\t]*)([-+*]|[0-9]+[.)])[ \\t]+(\\[[ xX]\\][ \\t]+)?"; prefix = { "\($0 + 1). " }
        case .taskList: pattern = "^([ \\t]*)([-+*]|[0-9]+[.)])[ \\t]+(\\[[ xX]\\][ \\t]+)?"; prefix = { _ in "- [ ] " }
        case .quote: pattern = "^ {0,3}>[ \\t]?"; prefix = { _ in "> " }
        case .indent: pattern = "^"; prefix = { _ in "    " }
        case .outdent: pattern = "^( {1,4}|\\t)"; prefix = { _ in "" }
        default: return false
        }
        let regex = try! NSRegularExpression(pattern: pattern)
        let toggleOff = lines.enumerated().allSatisfy { $0.element.hasPrefix(prefix($0.offset)) } && {
            switch command { case .body, .indent, .outdent: return false; default: return true }
        }()
        if case .heading = command, toggleOff { return removeHeadingSyntax(in: selection) }
        var caretAdjustment = 0
        let result = lines.enumerated().map { index, line in
            var cleaned = regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: line.utf16.count), withTemplate: "")
            if startingOrderedSublist, index == 0,
               let marker = try? NSRegularExpression(pattern: "^[ \\t]*([0-9]{1,9})[.)][ \\t]+"),
               let match = marker.firstMatch(in: cleaned, range: NSRange(location: 0, length: cleaned.utf16.count)) {
                let number = match.range(at: 1)
                let start = lineRange.location + number.location
                if selection.location > start {
                    caretAdjustment = max(start + 1, selection.location + 1 - number.length) - selection.location
                }
                cleaned = (cleaned as NSString).replacingCharacters(in: number, with: "1")
            }
            return (toggleOff ? "" : prefix(index)) + cleaned
        }.joined(separator: "\n") + (hasFinalNewline ? "\n" : "")
        var selectionAfter = NSRange(location: lineRange.location, length: result.utf16.count)
        if selection.length == 0 {
            switch command {
            case .indent:
                selectionAfter = NSRange(location: selection.location + 4 + caretAdjustment, length: 0)
            case .outdent:
                let firstLine = lines.first ?? ""
                let removed = regex.firstMatch(in: firstLine, range: NSRange(location: 0, length: firstLine.utf16.count))?.range.length ?? 0
                selectionAfter = NSRange(location: max(lineRange.location, selection.location - removed), length: 0)
            default: break
            }
        }
        if selection.length == 0, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch command {
            case .unorderedList, .orderedList, .taskList:
                selectionAfter = NSRange(location: lineRange.location + prefix(0).utf16.count, length: 0)
            default: break
            }
        }
        return apply([SourcePatch(range: lineRange, replacement: result)], selectionAfter: selectionAfter)
    }

    private func headingSyntaxEnd(outer: NSRange, contentEnd: Int) -> Int {
        let original = source as NSString
        let line = original.lineRange(for: NSRange(location: contentEnd, length: 0))
        var end = max(NSMaxRange(outer), NSMaxRange(line))
        while end > contentEnd, [10, 13].contains(original.character(at: end - 1)) { end -= 1 }
        return end
    }

    private func removeHeadingSyntax(in selection: NSRange) -> Bool {
        let coordinates = SourceCoordinates(source: source)
        var removals: [NSRange] = []
        func visit(_ node: Markup) {
            if node is Heading, let outer = coordinates.nsRange(node.range),
               NSIntersectionRange(outer, selection).length > 0
                || (selection.length == 0 && selection.location >= outer.location && selection.location <= NSMaxRange(outer)) {
                if let first = node.child(at: 0), let last = node.child(at: node.childCount - 1),
                   let start = coordinates.nsRange(first.range), let end = coordinates.nsRange(last.range) {
                    removals.append(NSRange(location: outer.location, length: start.location - outer.location))
                    let contentEnd = NSMaxRange(end)
                    let suffixEnd = headingSyntaxEnd(outer: outer, contentEnd: contentEnd)
                    if suffixEnd > contentEnd {
                        removals.append(NSRange(location: contentEnd, length: suffixEnd - contentEnd))
                    }
                } else {
                    removals.append(outer)
                }
            }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(source))
        removals = removals.filter { $0.length > 0 }
        guard !removals.isEmpty else { return true }
        func adjusted(_ position: Int) -> Int {
            position - removals.reduce(0) { $0 + max(0, min(position, NSMaxRange($1)) - $1.location) }
        }
        let start = adjusted(selection.location)
        let end = adjusted(NSMaxRange(selection))
        return apply(removals.map { SourcePatch(range: $0, replacement: "") }, selectionAfter: NSRange(location: start, length: max(0, end - start)))
    }

    private func clearFormatting(_ selection: NSRange) -> Bool {
        let coordinates = SourceCoordinates(source: source)
        var removals: [NSRange] = []
        func visit(_ node: Markup) {
            guard let outer = coordinates.nsRange(node.range) else { return }
            let intersects = NSIntersectionRange(outer, selection).length > 0
                || (selection.length == 0 && selection.location >= outer.location && selection.location <= NSMaxRange(outer))
            guard intersects else { return }
            if node is Strong || node is Emphasis || node is Strikethrough || node is Markdown.Link || node is Heading {
                if let first = node.child(at: 0), let last = node.child(at: node.childCount - 1),
                   let start = coordinates.nsRange(first.range), let end = coordinates.nsRange(last.range) {
                    removals.append(NSRange(location: outer.location, length: start.location - outer.location))
                    let contentEnd = NSMaxRange(end)
                    let suffixEnd = node is Heading ? headingSyntaxEnd(outer: outer, contentEnd: contentEnd) : NSMaxRange(outer)
                    removals.append(NSRange(location: contentEnd, length: suffixEnd - contentEnd))
                }
            } else if let code = node as? InlineCode {
                let raw = (source as NSString).substring(with: outer) as NSString
                let found = raw.range(of: code.code)
                if found.location != NSNotFound {
                    removals.append(NSRange(location: outer.location, length: found.location))
                    removals.append(NSRange(location: outer.location + NSMaxRange(found), length: outer.length - NSMaxRange(found)))
                }
            } else if node is ListItem, let first = node.child(at: 0)?.child(at: 0), let content = coordinates.nsRange(first.range) {
                removals.append(NSRange(location: outer.location, length: content.location - outer.location))
            } else if node is BlockQuote {
                let original = source as NSString
                var cursor = outer.location
                while cursor < NSMaxRange(outer) {
                    let line = original.lineRange(for: NSRange(location: cursor, length: 0))
                    let value = original.substring(with: line)
                    let regex = try! NSRegularExpression(pattern: "^( {0,3}>[ \\t]?)+")
                    if let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)) {
                        removals.append(NSRange(location: line.location + match.range.location, length: match.range.length))
                    }
                    cursor = NSMaxRange(line)
                }
            }
            for child in node.children { visit(child) }
        }
        for child in MarkdownParser.parse(source).children { visit(child) }
        let ordered = removals.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ordered {
            if let last = merged.last, range.location <= NSMaxRange(last) { merged[merged.count - 1] = NSUnionRange(last, range) }
            else { merged.append(range) }
        }
        guard !merged.isEmpty else { return false }
        func adjusted(_ position: Int) -> Int {
            position - merged.reduce(0) { $0 + max(0, min(position, NSMaxRange($1)) - $1.location) }
        }
        let start = adjusted(selection.location)
        let end = adjusted(NSMaxRange(selection))
        return apply(merged.map { SourcePatch(range: $0, replacement: "") }, selectionAfter: NSRange(location: start, length: max(0, end - start)))
    }
}