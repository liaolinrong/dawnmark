import AppKit
import EditorKit
import Markdown
import Testing
import MarkdownEngine

@Suite(.serialized) @MainActor struct StandardMarkdownTests {
    private func parsed(_ source: String) -> Document {
        Document(parsing: source, options: [.disableSmartOpts])
    }
    private func text(_ node: Markup?) -> String {
        guard let node else { return "" }
        if let literal = node as? Markdown.Text { return literal.string }
        return node.children.map { text($0) }.joined()
    }

    @Test func insertedHorizontalRulesOnlyAddMissingBlankLineSeparators() {
        for newline in ["\n", "\r\n", "\r"] {
            for (before, after) in [
                ("", ""), ("Before", ""), ("", "After"), ("Before", "After"),
                ("Before" + newline, newline + "After"),
                ("Before" + newline + newline, newline + newline + "After"),
                ("Before" + String(repeating: newline, count: 3), String(repeating: newline, count: 3) + "After"),
                (newline + newline, newline + newline)
            ] {
                if newline != "\n", !before.contains(newline), !after.contains(newline) { continue }
                let source = before + "replace" + after
                let session = DocumentSession(source: source)
                session.undoManager.groupsByEvent = false
                session.undoManager.beginUndoGrouping()
                #expect(session.perform(.horizontalRule, in: NSRange(location: before.utf16.count, length: "replace".utf16.count)))
                session.undoManager.endUndoGrouping()
                let prefix = before.isEmpty ? "" : before.hasSuffix(newline + newline) ? before : "Before" + newline + newline
                let suffix = after.isEmpty ? "" : after.hasPrefix(newline + newline) ? after : newline + newline + "After"
                #expect(session.source == prefix + "---" + suffix)
                let document = parsed(session.source)
                #expect(document.children.filter { $0 is ThematicBreak }.count == 1)
                #expect(!document.children.contains { $0 is Heading })
                #expect(document.children.filter { $0 is Paragraph }.count == (before.contains("Before") ? 1 : 0) + (after.contains("After") ? 1 : 0))
                session.undoManager.undo()
                #expect(session.source == source)
                session.undoManager.redo()
                #expect(session.source == prefix + "---" + suffix)
            }
        }
        let empty = DocumentSession()
        #expect(empty.perform(.horizontalRule))
        #expect(empty.source == "---")
    }

    @Test func insertedTablesOnlyAddMissingBlankLineSeparators() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let table = ["|   |   |", "| --- | --- |", "|   |   |"].joined(separator: newline)
            for (before, after) in [
                ("", ""), ("Before", ""), ("", "After"), ("Before", "After"),
                ("Before" + newline, newline + "After"),
                ("Before" + newline + newline, newline + newline + "After"),
                ("Before" + String(repeating: newline, count: 3), String(repeating: newline, count: 3) + "After"),
                (newline + newline, newline + newline)
            ] {
                if newline != "\n", !before.contains(newline), !after.contains(newline) { continue }
                let source = before + "replace" + after
                let selection = NSRange(location: before.utf16.count, length: "replace".utf16.count)
                let session = DocumentSession(source: source)
                session.undoManager.groupsByEvent = false
                session.undoManager.beginUndoGrouping()
                #expect(session.perform(.insertTable(columns: 2, rows: 1), in: selection))
                session.undoManager.endUndoGrouping()
                let prefix = before.isEmpty ? "" : before.hasSuffix(newline + newline) ? before : "Before" + newline + newline
                let suffix = after.isEmpty ? "" : after.hasPrefix(newline + newline) ? after : newline + newline + "After"
                #expect(session.source == prefix + table + suffix)
                let document = parsed(session.source)
                #expect(document.children.filter { $0 is Table }.count == 1)
                #expect(document.children.filter { $0 is Paragraph }.count == (before.contains("Before") ? 1 : 0) + (after.contains("After") ? 1 : 0))
                session.undoManager.undo()
                #expect(session.source == source)
                session.undoManager.redo()
                #expect(session.source == prefix + table + suffix)
            }
        }
        let empty = DocumentSession()
        #expect(empty.perform(.insertTable(columns: 2, rows: 1)))
        #expect(empty.source == "|   |   |\n| --- | --- |\n|   |   |")
    }

    @Test func menuIndentNeverTurnsParagraphsIntoCodeBlocks() throws {
        let paragraph = DocumentSession(source: "Before\n\nplain text\n")
        paragraph.renderNow()
        let editor = MarkdownEditorController(session: paragraph)
        _ = editor.view
        editor.textView.setSelectedRange(NSRange(location: (editor.textView.string as NSString).range(of: "plain").location, length: 0))
        #expect(!editor.perform(.indent))
        #expect(paragraph.source == "Before\n\nplain text\n")
        #expect(!(parsed(paragraph.source).child(at: 1) is CodeBlock))

        let list = DocumentSession(source: "- one\n- two\n")
        list.renderNow()
        let listEditor = MarkdownEditorController(session: list)
        _ = listEditor.view
        listEditor.textView.setSelectedRange(NSRange(location: (listEditor.textView.string as NSString).range(of: "two").location, length: 0))
        #expect(listEditor.perform(.indent))
        let item = try #require((parsed(list.source).child(at: 0) as? UnorderedList)?.child(at: 0) as? ListItem)
        #expect(item.children.contains { $0 is UnorderedList })
        let nested = (listEditor.textView.string as NSString).range(of: "two")
        let paragraphStyle = try #require(listEditor.textView.textStorage?.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraphStyle.firstLineHeadIndent == 32)
    }

    @Test func orderedListIndentCreatesStandardSublist() throws {
        for delimiter in [".", ")"] {
            for number in [2, 10] {
                for multiple in [false, true] {
                    let source = "1\(delimiter) parent\n\(number)\(delimiter) child\n\(number + 1)\(delimiter) sibling\n\(number + 2)\(delimiter) peer\n"
                    let session = DocumentSession(source: source)
                    session.undoManager.groupsByEvent = false
                    session.renderNow()
                    let editor = MarkdownEditorController(session: session)
                    _ = editor.view
                    let displayed = editor.textView.string as NSString
                    let child = displayed.range(of: "child")
                    let sibling = displayed.range(of: "sibling")
                    let selection = NSRange(location: child.location, length: multiple ? NSMaxRange(sibling) - child.location : 0)
                    editor.textView.setSelectedRange(selection)
                    session.undoManager.beginUndoGrouping()
                    #expect(editor.perform(.indent))
                    session.undoManager.endUndoGrouping()
                    var expected = source.replacingOccurrences(of: "\(number)\(delimiter) child", with: "    1\(delimiter) child")
                    if multiple {
                        expected = expected.replacingOccurrences(of: "\(number + 1)\(delimiter) sibling", with: "    \(number + 1)\(delimiter) sibling")
                    }
                    #expect(session.source == expected)
                    let parent = try #require((parsed(session.source).child(at: 0) as? OrderedList)?.child(at: 0) as? ListItem)
                    let nested = try #require(parent.children.first { $0 is OrderedList } as? OrderedList)
                    #expect(nested.startIndex == 1)
                    #expect(nested.childCount == (multiple ? 2 : 1))
                    if !multiple {
                        #expect(editor.textView.selectedRange().location == (editor.textView.string as NSString).range(of: "child").location)
                    }
                    session.undoManager.undo()
                    session.renderNow()
                    #expect(session.source == source)
                }
            }
        }
    }

    @Test func sourceModeIndentWorksAfterRichTextRejection() throws {
        for block in ["plain text", "# heading", "> quoted", "first\nsecond", "first\r\nsecond"] {
            let source = "Before\n\n" + block + "\n\nAfter"
            let session = DocumentSession(source: source)
            session.undoManager.groupsByEvent = false
            session.renderNow()
            let editor = MarkdownEditorController(session: session)
            _ = editor.view
            let selection = (source as NSString).range(of: block)
            editor.textView.setSelectedRange(session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: selection))
            #expect(!editor.perform(.indent))
            #expect(session.source == source)
            editor.mode = .source
            editor.textView.setSelectedRange(selection)
            session.undoManager.beginUndoGrouping()
            #expect(editor.perform(.indent))
            session.undoManager.endUndoGrouping()
            let indented = "    " + block.replacingOccurrences(of: "\n", with: "\n    ")
            #expect(session.source == "Before\n\n" + indented + "\n\nAfter")
            #expect(editor.textView.string == session.source)
            session.undoManager.beginUndoGrouping()
            #expect(editor.perform(.outdent))
            session.undoManager.endUndoGrouping()
            #expect(session.source == source)
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == "Before\n\n" + indented + "\n\nAfter")
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
            let caret = NSRange(location: selection.location + min(2, selection.length), length: 0)
            editor.textView.setSelectedRange(caret)
            session.undoManager.beginUndoGrouping()
            #expect(editor.perform(.indent))
            session.undoManager.endUndoGrouping()
            #expect(editor.textView.selectedRange() == NSRange(location: caret.location + 4, length: 0))
            session.undoManager.beginUndoGrouping()
            #expect(editor.perform(.outdent))
            session.undoManager.endUndoGrouping()
            #expect(session.source == source)
            #expect(editor.textView.selectedRange() == caret)
        }
    }

    @Test func generatedLinkLabelsPreserveBracketsAndInlineFormatting() {
        for source in ["a]b", "a[b", "[label]", "**a]b**", "a\\]b", "`a]b`", "![alt](image.png)"] {
            let session = DocumentSession(source: source)
            #expect(session.perform(.insertLink(destination: "https://example.com"), in: NSRange(location: 0, length: source.utf16.count)))
            let paragraph = parsed(session.source).child(at: 0) as? Paragraph
            let link = paragraph?.child(at: 0) as? Markdown.Link
            #expect(paragraph?.childCount == 1)
            #expect(link?.destination == "https://example.com")
            #expect(link?.plainText == (parsed(source).child(at: 0) as? Paragraph)?.plainText)
            if source.hasPrefix("**") { #expect(link?.child(at: 0) is Strong) }
            if source.hasPrefix("`") { #expect(link?.child(at: 0) is InlineCode) }
            if source.hasPrefix("![") { #expect(link?.child(at: 0) is Image) }
        }
    }

    @Test func generatedEmphasisExcludesBoundaryWhitespace() {
        for command in [FormattingCommand.bold, .italic, .strikethrough] {
            for source in [" word ", " 中文😀 \t", "\nword\n"] {
                let session = DocumentSession(source: source)
                #expect(session.perform(command, in: NSRange(location: 0, length: source.utf16.count)))
                let paragraph = parsed(session.source).child(at: 0) as? Paragraph
                switch command {
                case .bold: #expect(paragraph?.child(at: 0) is Strong)
                case .italic: #expect(paragraph?.child(at: 0) is Emphasis)
                case .strikethrough: #expect(paragraph?.child(at: 0) is Strikethrough)
                default: break
                }
                #expect(text(paragraph) == text(parsed(source).child(at: 0)))
            }
        }
    }

    @Test func togglingATXHeadingRemovesClosingSyntax() {
        for (source, level) in [("# title ###\n", 1), ("## **title** ##\r\n", 2)] {
            let session = DocumentSession(source: source)
            #expect(session.perform(.heading(level: level), in: NSRange(location: 0, length: source.utf16.count)))
            #expect(parsed(session.source).child(at: 0) is Paragraph)
            #expect((parsed(session.source).child(at: 0) as? Paragraph)?.plainText == "title")
            #expect(!session.source.contains("#"))
        }
    }

    @Test func clearingATXHeadingDoesNotLeaveClosingHashes() {
        for source in ["# title ###\n", "## **title** ##\r\n"] {
            let session = DocumentSession(source: source)
            #expect(session.perform(.clearFormatting, in: NSRange(location: 0, length: source.utf16.count)))
            #expect((parsed(session.source).child(at: 0) as? Paragraph)?.plainText == "title")
            #expect(!session.source.contains("#"))
        }
    }

    @Test func generatedFencesPreserveCodeLineEndingsWithoutExtraBlankLine() {
        for source in ["code", "code\n", "code\r\n", "code\n\n", "```\ncode\n"] {
            let session = DocumentSession(source: source)
            #expect(session.perform(.codeBlock, in: NSRange(location: 0, length: source.utf16.count)))
            let code = parsed(session.source).child(at: 0) as? CodeBlock
            let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            #expect(code?.code == normalized + (normalized.hasSuffix("\n") ? "" : "\n"))
            if source.contains("\r\n") {
                #expect(!session.source.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            }
        }
    }

    @Test func codeRenderingUsesStandardParsedContent() {
        for source in ["\tcode\n", "\t\tcode\n", "    code\n", "- \t\tcode\n", "1. \t\tcode\n", "```\n\tcode\n```\n"] {
            var blocks: [CodeBlock] = []
            func visit(_ node: Markup) {
                if let code = node as? CodeBlock { blocks.append(code) }
                for child in node.children { visit(child) }
            }
            visit(parsed(source))
            #expect(blocks.count == 1)
            let snapshot = MarkdownRenderer.snapshot(source: source)
            let codeText = snapshot.runs.filter { $0.style.contains(.code) }.map {
                (snapshot.text as NSString).substring(with: $0.range)
            }.joined()
            let terminated = codeText + (codeText.hasSuffix("\n") ? "" : "\n")
            #expect(terminated == blocks.first?.code, "Source: \(source.debugDescription), displayed: \(codeText.debugDescription)")
            if source == "\tcode\n" || source == "    code\n" { #expect(snapshot.text == source) }
            let body = (snapshot.text as NSString).range(of: "code")
            #expect(body.location != NSNotFound)
            let firstCharacter = NSRange(location: body.location, length: 1)
            let session = DocumentSession(source: source)
            session.renderNow()
            #expect(session.editRendered(range: firstCharacter, replacement: ""))
            #expect(session.source == source.replacingOccurrences(of: "code", with: "ode"))
        }
    }

    @Test func normalizedInlineCodeStillHasEditableBodyCharacters() {
        for source in ["`a\nb`", "`a\r\nb`", "`a\\*\nb`", "`a&amp;\nb`", "` a `"] {
            let paragraph = parsed(source).child(at: 0) as? Paragraph
            let code = paragraph?.child(at: 0) as? InlineCode
            let snapshot = MarkdownRenderer.snapshot(source: source)
            #expect(snapshot.text == code?.code)
            let body = (snapshot.text as NSString).range(of: "a")
            let session = DocumentSession(source: source)
            session.renderNow()
            #expect(session.editRendered(range: body, replacement: ""), "Source: \(source.debugDescription), map: \(snapshot.sourceMap.segments)")
            let expected = code?.code == "a" ? "" : source.replacingOccurrences(of: "a", with: "", options: .literal, range: source.startIndex..<source.index(after: source.firstIndex(of: "a")!))
            #expect(session.source == expected)
        }
    }

    @Test func gfmTableAlignmentUsesParsedColumnSemantics() {
        let source = "| Left | Center | Right |\n| :--- | :---: | ---: |\n| a | b | c |\n"
        let snapshot = MarkdownRenderer.snapshot(source: source)
        let rendered = MarkdownRenderer.render(snapshot: snapshot)
        let expected: [NSTextAlignment] = [.left, .center, .right]
        #expect(snapshot.tableCells.count == 6)
        for cell in snapshot.tableCells {
            let paragraph = rendered.attributedString.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(paragraph?.alignment == expected[cell.column])
        }
        #expect(snapshot.source == source)
    }

    @Test func looseListSourceGapsRemainMappedWithoutCustomCollapse() {
        let source = "1. first\n2. second\n3. third\n4. fourth\n5. fifth\n\n\n\n4. aaa\n"
        let snapshot = MarkdownRenderer.snapshot(source: source)
        #expect(snapshot.text.contains("5. fifth\n\n\n\n6. aaa"))
        let markers = snapshot.sourceMap.segments.filter { $0.isListMarker }
        #expect(markers.count == 6)
        #expect((source as NSString).substring(with: markers.last!.sourceNSRange) == "4. ")
        let gap = (snapshot.text as NSString).range(of: "\n\n\n\n")
        #expect(snapshot.sourceMap.segments.filter { NSIntersectionRange($0.displayedNSRange, gap).length > 0 }.allSatisfy { $0.kind == .lineBreak && $0.isIdentity })
    }

    @Test func formattingDoesNotGenerateInvalidCrossParagraphMarkers() {
        let source = "one\n\ntwo"
        for command in [FormattingCommand.bold, .italic, .strikethrough, .insertLink(destination: "https://example.com")] {
            let session = DocumentSession(source: source)
            #expect(!session.perform(command, in: NSRange(location: 0, length: source.utf16.count)))
            #expect(session.source == source)
        }
    }

    @Test func standardLineEndingsHaveCompleteSourceMappings() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "one" + newline + "two"
            let snapshot = MarkdownRenderer.snapshot(source: source)
            #expect(snapshot.text == "one\ntwo")
            let session = DocumentSession(source: source)
            session.renderNow()
            let body = (snapshot.text as NSString).range(of: "two")
            #expect(session.editRendered(range: body, replacement: "changed"))
            #expect(session.source == "one" + newline + "changed")
            let fenced = "```" + newline + "one" + newline + "two" + newline + "```"
            let code = DocumentSession(source: fenced)
            code.renderNow()
            let separator = (code.renderSnapshot!.text as NSString).range(of: "\n")
            #expect(separator.location != NSNotFound)
            #expect(code.editRendered(range: separator, replacement: ""))
            #expect(code.source == "```" + newline + "onetwo" + newline + "```", "Line ending: \(newline.debugDescription), source: \(code.source.debugDescription)")
        }
    }
}