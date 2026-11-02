import Foundation
import Markdown

extension DocumentSession {
    @discardableResult public func continueList(in selection: NSRange? = nil) -> Bool {
        let selection = selection ?? selectedSourceRange
        guard canEdit, selection.length == 0, Range(selection, in: source) != nil else { return false }
        let original = source as NSString
        let line = original.lineRange(for: selection)
        let raw = original.substring(with: line)
        let coordinates = SourceCoordinates(source: source)
        var item: ListItem?
        func visit(_ node: Markup) {
            if let candidate = node as? ListItem, let range = coordinates.nsRange(candidate.range),
               original.lineRange(for: NSRange(location: range.location, length: 0)).location == line.location {
                item = candidate
            }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(source))
        guard let item else { return false }
        let regex = try! NSRegularExpression(pattern: "^([ \\t]*(?:>[ \\t]*)*)([-+*]|[0-9]+[.)])([ \\t]*)(?:\\[([ xX])\\](?:[ \\t]+|$))?")
        guard let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)),
              selection.location >= line.location + NSMaxRange(match.range) else { return false }
        let value = raw as NSString
        let prefix = value.substring(with: match.range(at: 1))
        if value.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let start = line.location + match.range(at: 2).location
            let end = line.location + NSMaxRange(match.range)
            return apply([SourcePatch(range: NSRange(location: start, length: end - start), replacement: "")], selectionAfter: NSRange(location: start, length: 0))
        }
        var marker = value.substring(with: match.range(at: 2))
        if let number = Int(marker.dropLast()), number < 999_999_999 { marker = "\(number + 1)" + String(marker.suffix(1)) }
        let spacing = value.substring(with: match.range(at: 3))
        let task = item.checkbox != nil ? "[ ] " : ""
        let newline = raw.hasSuffix("\r\n") || (!raw.hasSuffix("\n") && source.contains("\r\n")) ? "\r\n" : "\n"
        var insertion = selection.location
        if let paragraph = item.child(at: 0) as? Paragraph, let paragraphRange = coordinates.nsRange(paragraph.range) {
            var last: Markup = paragraph
            while last.childCount > 0, let child = last.child(at: last.childCount - 1) { last = child }
            if let range = coordinates.nsRange(last.range), insertion == NSMaxRange(range) { insertion = NSMaxRange(paragraphRange) }
        }
        let replacement = newline + prefix + marker + spacing + task
        return apply([SourcePatch(range: NSRange(location: insertion, length: 0), replacement: replacement)], selectionAfter: NSRange(location: insertion + replacement.utf16.count, length: 0))
    }

    @discardableResult public func toggleTaskCheckbox(atSourceOffset offset: Int) -> Bool {
        guard canEdit, offset >= 0, offset < source.utf16.count else { return false }
        let coordinates = SourceCoordinates(source: source)
        let original = source as NSString
        var marker: NSRange?
        func visit(_ node: Markup) {
            if let item = node as? ListItem, item.checkbox != nil,
               let outer = coordinates.nsRange(item.range) {
                let raw = original.substring(with: outer)
                let regex = try! NSRegularExpression(pattern: "^([-+*]|[0-9]+[.)])[ \\t]+(\\[[ xX]\\])")
                if let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)) {
                    let local = match.range(at: 2)
                    let range = NSRange(location: outer.location + local.location, length: local.length)
                    if NSLocationInRange(offset, range) { marker = range }
                }
            }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(source))
        guard let marker else { return false }
        let replacement = original.substring(with: marker) == "[ ]" ? "[x]" : "[ ]"
        return apply([SourcePatch(range: marker, replacement: replacement)], selectionAfter: selectedSourceRange)
    }

    func editTable(_ command: FormattingCommand, selection: NSRange, checkingOnly: Bool = false) -> Bool {
        guard canEdit, Range(selection, in: source) != nil else { return false }
        let coordinates = SourceCoordinates(source: source)
        var target: Table?
        func visit(_ node: Markup) {
            if let table = node as? Table, let range = coordinates.nsRange(table.range),
               selection.location >= range.location, NSMaxRange(selection) <= NSMaxRange(range) {
                target = table
            }
            for child in node.children { visit(child) }
        }
        visit(MarkdownParser.parse(source))
        guard let table = target, let headRange = coordinates.nsRange(table.head.range) else { return false }
        let original = source as NSString
        if case .tableDelete = command {
            guard let range = coordinates.nsRange(table.range) else { return false }
            if checkingOnly { return true }
            let lines = original.lineRange(for: range)
            return apply([SourcePatch(range: lines, replacement: "")], selectionAfter: NSRange(location: lines.location, length: 0))
        }
        let headLine = original.lineRange(for: NSRange(location: headRange.location, length: 0))
        guard NSMaxRange(headLine) < original.length else { return false }
        let delimiterLine = original.lineRange(for: NSRange(location: NSMaxRange(headLine), length: 0))
        let prefixLength = headRange.location - headLine.location
        guard let head = TableSourceRow(original: original, line: headLine, prefixLength: prefixLength),
              let delimiter = TableSourceRow(original: original, line: delimiterLine, prefixLength: prefixLength),
              head.cells.count == table.head.childCount, delimiter.cells.count == head.cells.count else { return false }
        var rows = [head, delimiter]
        for row in table.body.children {
            guard let range = coordinates.nsRange(row.range) else { return false }
            let line = original.lineRange(for: NSRange(location: range.location, length: 0))
            guard let parsed = TableSourceRow(original: original, line: line, prefixLength: range.location - line.location) else { return false }
            rows.append(parsed)
        }
        guard let rowIndex = rows.firstIndex(where: { selection.location >= $0.line.location && selection.location < NSMaxRange($0.line) })
                ?? (selection.location == NSMaxRange(rows.last!.content) ? rows.count - 1 : nil) else { return false }
        let row = rows[rowIndex]
        let column = row.cells.firstIndex(where: { selection.location <= NSMaxRange($0) }) ?? min(row.cells.count, head.cells.count) - 1
        guard column < head.cells.count else { return false }
        switch command {
        case .tableInsertRow:
            guard table.body.childCount < 1000 else { return false }
            if checkingOnly { return true }
            let anchor = rows[max(1, rowIndex)]
            let newline = anchor.newline.isEmpty ? head.newline : anchor.newline
            let prefix = original.substring(with: NSRange(location: anchor.line.location, length: anchor.content.location - anchor.line.location))
            let value = prefix + "|" + String(repeating: "   |", count: head.cells.count)
            let replacement = anchor.newline.isEmpty ? newline + value : value + newline
            let insertion = NSMaxRange(anchor.line)
            let caret = insertion + (anchor.newline.isEmpty ? newline.utf16.count : 0) + prefix.utf16.count + 1
            return apply([SourcePatch(range: NSRange(location: insertion, length: 0), replacement: replacement)], selectionAfter: NSRange(location: caret, length: 0))
        case .tableDeleteRow:
            guard rowIndex >= 2 else { return false }
            if checkingOnly { return true }
            return apply([SourcePatch(range: row.line, replacement: "")], selectionAfter: NSRange(location: rows[rowIndex - 1].cells[0].location, length: 0))
        case .tableInsertColumn:
            guard head.cells.count < 64 else { return false }
            if checkingOnly { return true }
            return apply(rows.enumerated().map { index, row in
                let existingColumn = min(column, row.cells.count - 1)
                let count = column - existingColumn + 1
                return SourcePatch(range: NSRange(location: NSMaxRange(row.cells[existingColumn]), length: 0), replacement: String(repeating: index == 1 ? "| --- " : "|   ", count: count))
            })
        case .tableDeleteColumn:
            guard head.cells.count > 1 else { return false }
            if checkingOnly { return true }
            return apply(rows.compactMap { row -> SourcePatch? in
                guard column < row.cells.count else { return nil }
                let cell = row.cells[column]
                let range = row.cells.count == 1 ? cell : column == 0
                    ? NSRange(location: cell.location, length: row.cells[1].location - cell.location)
                    : NSRange(location: NSMaxRange(row.cells[column - 1]), length: NSMaxRange(cell) - NSMaxRange(row.cells[column - 1]))
                return SourcePatch(range: range, replacement: "")
            })
        default: return false
        }
    }
}

private struct TableSourceRow {
    let line: NSRange
    let content: NSRange
    let cells: [NSRange]
    let newline: String

    init?(original: NSString, line: NSRange, prefixLength: Int) {
        var end = NSMaxRange(line)
        while end > line.location, [10, 13].contains(original.character(at: end - 1)) { end -= 1 }
        guard prefixLength >= 0, line.location + prefixLength < end else { return nil }
        self.line = line
        content = NSRange(location: line.location + prefixLength, length: end - line.location - prefixLength)
        newline = original.substring(with: NSRange(location: end, length: NSMaxRange(line) - end))
        var pipes: [Int] = []
        var escaped = false
        for offset in content.location..<end {
            let character = original.character(at: offset)
            if character == 124 && !escaped { pipes.append(offset) }
            escaped = character == 92 && !escaped
        }
        var start = content.location
        var finish = end
        if let first = pipes.first, original.substring(with: NSRange(location: start, length: first - start)).trimmingCharacters(in: .whitespaces).isEmpty {
            start = first + 1
            pipes.removeFirst()
        }
        if let last = pipes.last, original.substring(with: NSRange(location: last + 1, length: end - last - 1)).trimmingCharacters(in: .whitespaces).isEmpty {
            finish = last
            pipes.removeLast()
        }
        var spans: [NSRange] = []
        for pipe in pipes {
            spans.append(NSRange(location: start, length: pipe - start))
            start = pipe + 1
        }
        guard finish >= start else { return nil }
        spans.append(NSRange(location: start, length: finish - start))
        cells = spans
    }
}