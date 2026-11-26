import AppKit
import Testing
@testable import EditorKit

@Suite struct CodeHighlightTests {
    @Test(arguments: [
        ("swift", "let value = 42"), ("py", "return 42"), ("js", "const value = 42;"),
        ("ts", "const value: number = 42;"), ("tsx", "const element = <div />;"),
        ("sh", "echo \"hello\""), ("json", "{\"value\": 42}"), ("html", "<p>Hello</p>"),
        ("css", "p { color: red; }"), ("java", "class Example { int value = 42; }"),
        ("go", "package main"), ("c", "int value = 42;"), ("c++", "int value = 42;"),
        ("rust", "fn main() { let value = 42; }"), ("yml", "enabled: true # comment"),
        ("toml", "[build]\nrelease = true"), ("docker", "FROM alpine:3\nRUN echo hello"),
        ("make", "all: demo\n\t@echo hello # comment"), ("cs", "class Example { int value = 42; }"),
        ("kt", "val value = 42"), ("php", "<?php function answer() { return 42; }"),
        ("rb", "def answer\n  42\nend"), ("dart", "void main() { print('hello'); }"),
        ("scala", "val answer: Int = 42"), ("objective-c", "@interface Example : NSObject\n@end"),
        ("sql", "SELECT 42 AS answer;"), ("r", "answer <- function() { 42 }"),
        ("jl", "function answer()\n    return 42\nend"), ("matlab", "answer = 42; % comment"),
        ("pwsh", "function Get-Answer { return 42 }"), ("lua", "local answer = 42"),
        ("fish", "function answer\n    echo 'hello'\nend"), ("verilog", "module demo(input wire ready); endmodule"),
        ("sv", "module demo; logic ready; endmodule"), ("vhd", "entity demo is\nend entity demo;"),
        ("gas", ".text\n.global main\nmain:\n    mov $42, %eax")
    ])
    func supportedLanguageProducesHighlights(language: String, code: String) async throws {
        let snapshot = MarkdownRenderer.snapshot(source: "Before\n\n```\(language)\n\(code)\n```\n\nAfter")
        let block = try #require(snapshot.codeBlocks.first)
        let grammar = try #require(CodeLanguage(label: language))
        try #require(grammar.highlightQueryURL != nil)
        let highlights = await CodeHighlighter().highlights(in: snapshot)
        #expect(!highlights.isEmpty)
        for highlight in highlights {
            #expect(NSIntersectionRange(block.range, highlight.range) == highlight.range)
        }
    }

    @Test(arguments: [
        ("php", "function answer() { return 42; }", "return", CodeHighlight.Kind.keyword),
        ("sql", "SELECT 42 AS answer;", "SELECT", .keyword),
        ("YML", "enabled: true # comment", "# comment", .comment),
        ("toml", "release = true", "true", .number),
        ("dockerfile", "FROM alpine:3", "FROM", .keyword),
        ("makefile", "# comment\nall:\n\t@echo hello", "# comment", .comment)
    ])
    func expandedGrammarHighlightsExpectedToken(language: String, code: String, token: String, kind: CodeHighlight.Kind) async {
        let snapshot = MarkdownRenderer.snapshot(source: "```\(language)\n\(code)\n```")
        let tokenRange = (snapshot.text as NSString).range(of: token)
        let highlights = await CodeHighlighter().highlights(in: snapshot)
        #expect(tokenRange.location != NSNotFound)
        #expect(highlights.contains { $0.kind == kind && NSIntersectionRange($0.range, tokenRange) == tokenRange })
    }

    @MainActor @Test func languageMenuIncludesEveryRegisteredGrammar() {
        let choices = MarkdownEditorController.codeBlockLanguages
        #expect(choices.count == CodeLanguage.allCases.count)
        #expect(Set(choices.map(\.label)) == Set(CodeLanguage.allCases.map(\.rawValue)))
        #expect(Set(choices.map(\.title)).count == choices.count)
    }

    @Test func incrementalResultMatchesFreshParseAfterCrossLineEdit() async throws {
        let highlighter = CodeHighlighter()
        let before = MarkdownRenderer.snapshot(source: "```c\n/* old 📝 */\nint hidden = 1;\n/* end */\nint visible = 2;\n```")
        let after = MarkdownRenderer.snapshot(source: "```c\n/* old 📘 \nint hidden = 1;\n/* end */\nint visible = 2;\n```")
        _ = await highlighter.highlights(in: before)
        let incremental = await highlighter.highlights(in: after)
        let fresh = await CodeHighlighter().highlights(in: after)
        #expect(incremental == fresh)
        let hidden = (after.text as NSString).range(of: "hidden")
        #expect(incremental.contains { $0.kind == .comment && NSIntersectionRange($0.range, hidden) == hidden })

        let moved = MarkdownRenderer.snapshot(source: "Paragraph 📝\n\n" + after.source)
        let movedHighlights = await highlighter.highlights(in: moved)
        let offset = try #require(moved.codeBlocks.first).range.location - #require(after.codeBlocks.first).range.location
        #expect(movedHighlights == incremental.map {
            CodeHighlight(range: NSRange(location: $0.range.location + offset, length: $0.range.length), kind: $0.kind)
        })
    }

    @Test func unmarkedUnknownAndOversizedCodeRemainPlain() async {
        let source = "```\nlet plain = 1\n```\n\n```unknown\nlet unknown = 2\n```\n\n```swift\n"
            + String(repeating: " ", count: CodeHighlighter.maximumBlockLength) + "let large = 3\n```"
        let snapshot = MarkdownRenderer.snapshot(source: source)
        #expect(snapshot.codeBlocks.map(\.language) == ["", "unknown", "swift"])
        await #expect(CodeHighlighter().highlights(in: snapshot).isEmpty)
    }

    @MainActor @Test func codeBlockLanguageEditsOnlyFenceAndSupportsUndo() throws {
        let source = "> ~~~~ Swift title=example\r\n> let value = 42\r\n> ~~~~\r\n"
        let session = DocumentSession(source: source)
        session.renderNow()
        let snapshot = try #require(session.renderSnapshot)
        let block = try #require(snapshot.codeBlocks.first)
        let value = (source as NSString).range(of: "value")
        session.selectedSourceRange = value
        #expect(!session.setCodeBlockLanguage("bad\nlabel", in: block))
        #expect(!session.setCodeBlockLanguage("", in: block))
        #expect(session.setCodeBlockLanguage("javascript", in: block))
        #expect(session.source == source.replacingOccurrences(of: "Swift", with: "javascript"))
        #expect(session.selectedSourceRange == (session.source as NSString).range(of: "value"))
        session.undoManager.undo()
        #expect(session.source == source)
        #expect(session.selectedSourceRange == value)
    }

    @MainActor @Test func codeBlockContextMenuTargetsHitBlockWithoutMovingSelection() throws {
        let session = DocumentSession(source: "```swift\nlet first = 1\n```\n\n```\nlet second = 2\n```\n")
        let editor = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.view
        window.contentView?.layoutSubtreeIfNeeded()
        session.renderNow()
        let view = try #require(editor.textView)
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        var clicked: CodeBlockSnapshot?
        editor.codeBlockMenu = { block in
            clicked = block
            let menu = NSMenu()
            menu.addItem(withTitle: "code-language-test", action: nil, keyEquivalent: "")
            return menu
        }
        let selection = NSRange(location: 0, length: 0)
        view.setSelectedRange(selection)
        #expect(editor.currentCodeBlock?.language == "swift")
        let range = (view.string as NSString).range(of: "second")
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let point = view.convert(NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(view.menu(for: event)?.items.first?.title == "code-language-test")
        #expect(view.selectedRange() == selection)
        let block = try #require(clicked)
        #expect(block.language.isEmpty)
        #expect(editor.setCodeBlockLanguage("python", in: block))
        #expect(session.source == "```swift\nlet first = 1\n```\n\n```python\nlet second = 2\n```\n")
        #expect(view.selectedRange() == selection)
    }

    @MainActor @Test func codeBlockLanguageCanBeAddedRemovedAndInserted() throws {
        let session = DocumentSession(source: "```\nvalue\n```\n")
        session.renderNow()
        let block = try #require(session.codeBlock(atDisplayedOffset: 0))
        #expect(session.setCodeBlockLanguage("cpp", in: block))
        #expect(session.source == "```cpp\nvalue\n```\n")
        session.renderNow()
        #expect(session.setCodeBlockLanguage("", in: try #require(session.codeBlock(atDisplayedOffset: 0))))
        #expect(session.source == "```\nvalue\n```\n")
        let insertion = DocumentSession(source: "value")
        #expect(insertion.insertCodeBlock(language: "swift", in: NSRange(location: 0, length: 5)))
        insertion.renderNow()
        #expect(insertion.renderSnapshot?.codeBlocks.first?.language == "swift")
        let empty = DocumentSession(source: "")
        let editor = MarkdownEditorController(session: empty)
        _ = editor.view
        #expect(editor.insertCodeBlock(language: "swift"))
        let emptyBlock = try #require(editor.currentCodeBlock)
        #expect(editor.setCodeBlockLanguage("python", in: emptyBlock))
        #expect(empty.source.contains("```python\n\n```"))
    }

    @MainActor @Test func codeLanguagePickerAcceptsTypedLanguageOnReturn() throws {
        let source = "Intro\n\n```\nvalue\n```\n\n```Custom title=example\nother\n```\n"
        let session = DocumentSession(source: source)
        let editor = MarkdownEditorController(session: session)
        editor.codeLanguagePickerLabels = { ("Code Block Language", "No Language") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.view
        session.renderNow()
        let view = try #require(editor.textView)
        let picker = editor.codeLanguagePicker
        #expect(picker.isHidden)

        let value = (view.string as NSString).range(of: "value")
        view.setSelectedRange(value)
        #expect(!picker.isHidden)
        #expect(picker.input.placeholderString == "No Language")
        #expect(picker.superview === view)
        let layout = try #require(view.layoutManager)
        let first = layout.glyphIndexForCharacter(at: value.location)
        let line = layout.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        #expect(picker.frame.minY < line.minY)
        #expect(picker.frame.maxY < line.minY)
        let firstPickerTop = picker.frame.minY
        #expect(window.makeFirstResponder(picker.input))
        let field = try #require(picker.input.currentEditor())
        field.insertText("ZiG")
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(session.source == source.replacingOccurrences(of: "```\nvalue", with: "```ZiG\nvalue"))
        #expect(view.selectedRange() == value)
        #expect(picker.input.stringValue == "ZiG")
        session.undoManager.undo()
        #expect(session.source == source)
        #expect(picker.input.stringValue.isEmpty)

        view.setSelectedRange((view.string as NSString).range(of: "other"))
        #expect(picker.frame.minY > firstPickerTop)
        #expect(picker.input.stringValue == "Custom")
        #expect(picker.input.placeholderString == nil)
        #expect(window.makeFirstResponder(picker.input))
        let otherField = try #require(picker.input.currentEditor())
        otherField.selectAll(nil)
        otherField.insertText("two words")
        otherField.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(session.source == source)
        #expect(picker.input.stringValue == "Custom")
        editor.canEdit = false
        #expect(picker.isHidden)
        editor.canEdit = true
        #expect(!picker.isHidden)
        editor.mode = .source
        #expect(picker.isHidden)
    }

    @MainActor @Test func codeLanguagePickerAppliesSelectionWithoutConfirmation() throws {
        let source = "```\nvalue\n```\n"
        let session = DocumentSession(source: source)
        let editor = MarkdownEditorController(session: session)
        editor.codeLanguagePickerLabels = { ("Code Block Language", "No Language") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.view
        session.renderNow()
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let picker = editor.codeLanguagePicker
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try #require(window.makeFirstResponder(picker.input))
        let field = try #require(picker.input.currentEditor())
        field.insertText("g")
        let table = picker.suggestionTable
        #expect(table.window?.isVisible == true)
        #expect(picker.input.currentEditor() === field)
        #expect(field.selectedRange == NSRange(location: 1, length: 0))
        #expect(table.numberOfRows == 1)
        let go = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSButton)
        #expect(go.title == "Go")
        table.window?.contentView?.layoutSubtreeIfNeeded()
        let visible = try #require(table.enclosingScrollView?.documentVisibleRect)
        #expect(visible.contains(table.rect(ofRow: 0).insetBy(dx: 1, dy: 0)))
        #expect(session.source == source)
        go.performClick(nil)
        #expect(session.source == "```go\nvalue\n```\n")
        #expect(picker.input.stringValue == "Go")
        session.undoManager.undo()
        #expect(session.source == source)
    }

    @MainActor @Test(arguments: [false, true]) func codeLanguagePickerCentersText(inline: Bool) throws {
        let picker = CodeLanguagePicker(frame: .zero, inline: inline)
        picker.setFrameSize(picker.intrinsicContentSize)
        picker.configure(original: "go", hasAdditionalInfo: false, title: "Code Block Language", noLanguage: "No Language")
        let window = NSWindow(contentRect: picker.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = picker
        picker.layoutSubtreeIfNeeded()
        let cell = try #require(picker.input.cell)
        let bounds = picker.input.bounds
        #expect(abs(cell.drawingRect(forBounds: bounds).midY - bounds.midY) <= 0.5)
        try #require(window.makeFirstResponder(picker.input))
        let field = try #require(picker.input.currentEditor() as? NSTextView)
        let layout = try #require(field.layoutManager)
        let container = try #require(field.textContainer)
        layout.ensureLayout(for: container)
        let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let fieldLine = line.offsetBy(dx: field.textContainerOrigin.x, dy: field.textContainerOrigin.y)
        #expect(abs(field.convert(fieldLine, to: picker.input).midY - bounds.midY) <= 1)
    }

    @MainActor @Test func codeLanguagePickerInlineShowsCommonNamesAndStoresFenceTags() throws {
        let picker = CodeLanguagePicker(frame: .zero, inline: true)
        picker.setFrameSize(picker.intrinsicContentSize)
        picker.configure(original: "c++", hasAdditionalInfo: false, title: "Code Block Language", noLanguage: "No Language")
        #expect(picker.input.stringValue == "C++")
        #expect(picker.language == "c++")
        let alert = NSAlert()
        alert.messageText = "Code Block Language"
        alert.accessoryView = picker
        let confirm = alert.addButton(withTitle: "Confirm")
        var committed: [String] = []
        picker.onCommit = { committed.append($0.language) }
        alert.layout()
        alert.window.makeKeyAndOrderFront(nil)
        defer { alert.window.orderOut(nil) }
        picker.layoutSubtreeIfNeeded()
        let table = picker.suggestionTable
        let tableFrame = table.convert(table.visibleRect, to: nil)
        #expect(!tableFrame.intersects(confirm.convert(confirm.bounds, to: nil)))

        for (query, title, tag) in [("C++", "C++", "cpp"), ("csharp", "C#", "csharp"),
                        ("Assembly", "Assembly (GNU)", "asm"), ("asm", "Assembly (GNU)", "asm")] {
            try #require(alert.window.makeFirstResponder(picker.input))
            let field = try #require(picker.input.currentEditor())
            field.selectAll(nil)
            field.insertText(query)
            table.layoutSubtreeIfNeeded()
            #expect(table.numberOfRows == 1)
            let visible = try #require(table.enclosingScrollView?.documentVisibleRect)
            #expect(visible.contains(table.rect(ofRow: 0).insetBy(dx: 1, dy: 0)))
            let button = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSButton)
            #expect(button.title == title)
            button.performClick(nil)
            #expect(committed.last == tag)
            #expect(picker.input.stringValue == title)
        }
    }

    @MainActor @Test func codeLanguagePickerCanInsertUnknownLanguageWithoutHighlighting() async throws {
        let session = DocumentSession(source: "const value = 42;")
        let editor = MarkdownEditorController(session: session)
        let picker = CodeLanguagePicker(frame: .zero)
        picker.configure(original: "", hasAdditionalInfo: false, title: "Code Block Language", noLanguage: "No Language")
        picker.input.stringValue = "No Language"
        #expect(picker.language.isEmpty)
        picker.input.stringValue = "zig"
        _ = editor.view
        editor.textView.selectAll(nil)
        #expect(editor.insertCodeBlock(language: picker.language))
        #expect(session.source.contains("```zig\nconst value = 42;\n```"))
        let snapshot = try #require(session.renderSnapshot)
        await #expect(CodeHighlighter().highlights(in: snapshot).isEmpty)
    }

    @MainActor @Test func customLanguageCannotExtendATildeFence() throws {
        let session = DocumentSession(source: "~~~\nvalue\n~~~\n")
        session.renderNow()
        let block = try #require(session.renderSnapshot?.codeBlocks.first)
        #expect(session.setCodeBlockLanguage("~custom", in: block))
        session.renderNow()
        #expect(session.source == "~~~ ~custom\nvalue\n~~~\n")
        #expect(session.renderSnapshot?.codeBlocks.first?.language == "~custom")
    }

    @MainActor @Test func codeLanguagePickerAtDocumentStartDoesNotMoveText() throws {
        let session = DocumentSession(source: "```javascript\nlet value = 42\n```\n\nAfter")
        let editor = MarkdownEditorController(session: session)
        editor.codeLanguagePickerLabels = { ("Code Block Language", "No Language") }
        _ = editor.view
        session.renderNow()
        let view = try #require(editor.textView)
        let picker = editor.codeLanguagePicker
        let layout = try #require(view.layoutManager)
        let after = (view.string as NSString).range(of: "After")
        try #require(after.location != NSNotFound)
        view.setSelectedRange(NSRange(location: after.location, length: 0))
        #expect(picker.isHidden)
        let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!picker.isHidden)
        #expect(picker.frame.height >= picker.intrinsicContentSize.height)
        #expect(picker.frame.height >= CodeBlockTextBlock.languagePickerHeight)
        picker.layoutSubtreeIfNeeded()
        let font = try #require(picker.input.font)
        let cell = try #require(picker.input.cell)
        let textRect = cell.drawingRect(forBounds: picker.input.bounds)
        #expect(picker.input.stringValue == "JavaScript")
        #expect(textRect.height >= ceil(font.ascender - font.descender) + 2)
        #expect(picker.frame.minY >= view.bounds.minY)
        #expect(picker.frame.maxY < line.minY + view.textContainerOrigin.y)
        #expect(layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil) == line)
        view.setSelectedRange(NSRange(location: after.location, length: 0))
        #expect(picker.isHidden)
    }

    @MainActor @Test func codeLanguagePickerFollowsBlockThroughScrollAndResize() throws {
        let source = String(repeating: "Paragraph\n\n", count: 25)
            + "```swift\nlet value = \"" + String(repeating: "long line ", count: 20) + "\"\n```\n\n"
            + String(repeating: "Paragraph\n\n", count: 25)
        let session = DocumentSession(source: source)
        let editor = MarkdownEditorController(session: session)
        editor.codeLanguagePickerLabels = { ("Code Block Language", "No Language") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.view
        session.renderNow()
        let view = try #require(editor.textView)
        let picker = editor.codeLanguagePicker
        let layout = try #require(view.layoutManager)
        let clip = try #require(view.enclosingScrollView?.contentView)
        let range = (view.string as NSString).range(of: "let value")
        view.setSelectedRange(NSRange(location: range.location, length: 0))

        for width in [800, 360] {
            window.setContentSize(NSSize(width: width, height: 400))
            editor.view.layoutSubtreeIfNeeded()
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let paragraph = try #require(view.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            let block = try #require(paragraph.textBlocks.first as? CodeBlockTextBlock)
            #expect(block.width(for: .margin, edge: .minY) == CodeBlockTextBlock().width(for: .margin, edge: .minY))
            let origin = view.textContainerOrigin
            let bounds = block.backgroundRect(for: layout.boundsRect(for: block, at: glyph, effectiveRange: nil)).offsetBy(dx: origin.x, dy: origin.y)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            #expect(!bounds.intersects(picker.frame))
            #expect(abs(picker.frame.maxX - bounds.maxX) < 1)
            #expect(abs(bounds.minY - picker.frame.maxY - CodeBlockTextBlock.languagePickerGap) < 1)
            #expect(picker.frame.maxX <= view.bounds.maxX)
            #expect(view.bounds.maxX - bounds.maxX < 32)
            #expect(line.minY - bounds.minY < 20)
            #expect(line.maxX <= bounds.maxX)
        }

        let before = picker.convert(picker.bounds, to: clip).minY - clip.bounds.minY
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: picker.frame.minY - 30))
        let after = picker.convert(picker.bounds, to: clip).minY - clip.bounds.minY
        #expect(abs(after - 30) < 1)
        #expect(abs(before - after) > 10)
    }

    @Test(arguments: ["ts", "tsx", "cpp"])
    func derivedGrammarIncludesBaseKeywordsAndNumbers(language: String) async {
        let code = language == "cpp" ? "int main() { return 42; }" : "const value: number = 42;"
        let snapshot = MarkdownRenderer.snapshot(source: "```\(language)\n\(code)\n```")
        let highlights = await CodeHighlighter().highlights(in: snapshot)
        let text = snapshot.text as NSString
        #expect(highlights.contains { $0.kind == .keyword && text.substring(with: $0.range) == (language == "cpp" ? "return" : "const") })
        #expect(highlights.contains { $0.kind == .number && text.substring(with: $0.range) == "42" })
    }

    @MainActor @Test func editorColorsAreTemporaryAndRichTextOnly() async throws {
        let source = "Before 📝\n\n```swift\nlet value = 42\n```\n\nAfter"
        let session = DocumentSession(source: source)
        let editor = MarkdownEditorController(session: session)
        _ = editor.view
        session.renderNow()
        await editor.waitForCodeHighlights()
        let layout = try #require(editor.textView.layoutManager)
        let snapshot = try #require(session.renderSnapshot)
        let keyword = (editor.textView.string as NSString).range(of: "let")
        #expect(editor.textView.string == snapshot.text)
        #expect(session.source == source)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: keyword.location, effectiveRange: nil) as? NSColor == .systemPurple)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        editor.imageProvider = { _ in nil }
        await editor.waitForCodeHighlights()
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: keyword.location, effectiveRange: nil) as? NSColor == .systemPurple)

        let language = (source as NSString).range(of: "swift")
        #expect(editor.insertMarkdown("unknown", in: language))
        await editor.waitForCodeHighlights()
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: keyword.location, effectiveRange: nil) == nil)
        #expect(editor.insertMarkdown("swift", in: NSRange(location: language.location, length: "unknown".utf16.count)))
        editor.mode = .source
        await editor.waitForCodeHighlights()
        #expect(editor.textView.string == source)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: keyword.location, effectiveRange: nil) == nil)
    }
}