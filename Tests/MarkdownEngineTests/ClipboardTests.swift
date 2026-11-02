import AppKit
import Testing
import MarkdownEngine
import EditorKit

@Suite(.serialized) @MainActor struct ClipboardTests {
    @Test func blocksCopyBetweenDocumentsAndSourceModeDoesNotImportPrivateFormatting() throws {
        for source in ["## Heading **bold**", "- first\n- **second**", "| ID | Text |\n| --- | --- |\n| 1 | **bold** |", "```swift\nlet value = 1\n```"] {
            let originSession = DocumentSession(source: source)
            originSession.renderNow()
            let origin = MarkdownEditorController(session: originSession)
            _ = origin.view
            origin.canEdit = false
            origin.textView.setSelectedRange(NSRange(location: 0, length: origin.textView.string.utf16.count))
            let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            defer { board.releaseGlobally() }
            #expect(origin.textView.writeSelection(to: board, types: origin.textView.writablePasteboardTypes))
            let targetSession = DocumentSession()
            targetSession.renderNow()
            let target = MarkdownEditorController(session: targetSession)
            _ = target.view
            #expect(target.textView.readSelection(from: board, type: MarkdownTextView.formattedMarkdownType))
            #expect(targetSession.source == source)
            #expect(target.textView.string == origin.textView.string)
            targetSession.undoManager.undo()
            targetSession.renderNow()
            #expect(targetSession.source.isEmpty)
            target.mode = .source
            #expect(!target.textView.readSelection(from: board, type: MarkdownTextView.formattedMarkdownType))
            #expect(target.textView.readSelection(from: board, type: .string))
            #expect(targetSession.source == origin.textView.string)
            origin.mode = .source
            #expect(!origin.textView.writablePasteboardTypes.contains(MarkdownTextView.formattedMarkdownType))
        }
    }

    @Test func internalCopyKeepsFormattingWhileExternalTextDoesNot() throws {
        let source = "**中文😀** and *italic*"
        let originSession = DocumentSession(source: source)
        originSession.renderNow()
        let origin = MarkdownEditorController(session: originSession)
        _ = origin.view
        origin.textView.setSelectedRange(NSRange(location: 0, length: origin.textView.string.utf16.count))
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        #expect(origin.textView.writeSelection(to: board, types: origin.textView.writablePasteboardTypes))
        #expect(board.string(forType: MarkdownTextView.formattedMarkdownType) == source)
        let session = DocumentSession(source: "replace")
        session.renderNow()
        let destination = MarkdownEditorController(session: session)
        _ = destination.view
        destination.textView.setSelectedRange(NSRange(location: 0, length: 7))
        #expect(destination.textView.readSelection(from: board, type: MarkdownTextView.formattedMarkdownType))
        #expect(session.source == source)
        let font = try #require(destination.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        session.undoManager.undo()
        session.renderNow()
        #expect(session.source == "replace")
        board.clearContents()
        board.setString("**outside**", forType: .string)
        destination.textView.setSelectedRange(NSRange(location: 0, length: 7))
        #expect(destination.textView.readSelection(from: board, type: .string))
        session.renderNow()
        #expect(destination.textView.string == "**outside**")
        #expect(session.source == "\\*\\*outside\\*\\*")
        destination.canEdit = false
        #expect(!destination.textView.readSelection(from: board, type: MarkdownTextView.formattedMarkdownType))
    }

    @Test func partialFormattedCopyAndCutRetainTheirMarkdown() throws {
        let session = DocumentSession(source: "**abcdef** tail")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let selection = NSRange(location: 1, length: 3)
        controller.textView.setSelectedRange(selection)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        #expect(controller.textView.writeSelection(to: board, types: controller.textView.writablePasteboardTypes))
        #expect(board.string(forType: MarkdownTextView.formattedMarkdownType) == "**bcd**")
        controller.textView.delete(nil)
        session.renderNow()
        #expect(session.source == "**aef** tail")
        controller.textView.setSelectedRange(NSRange(location: controller.textView.string.utf16.count, length: 0))
        #expect(controller.textView.readSelection(from: board, type: MarkdownTextView.formattedMarkdownType))
        #expect(session.source == "**aef** tail**bcd**")
    }

    @Test func textCopiesAndPastesInBothModesAndSupportsUndo() throws {
        for mode in [EditorMode.source, .richText] {
            let source = "**中文😀** tail"
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            controller.mode = mode
            _ = controller.view
            let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            defer { board.releaseGlobally() }
            let visible = controller.textView.string
            controller.textView.setSelectedRange(NSRange(location: 0, length: visible.utf16.count))
            board.declareTypes([.string], owner: nil)
            #expect(controller.textView.writeSelection(to: board, type: .string))
            #expect(board.string(forType: .string) == visible)
            board.clearContents()
            #expect(controller.textView.writeSelection(to: board, types: controller.textView.writablePasteboardTypes))
            #expect(board.string(forType: .string) == visible)
            board.clearContents()
            let pasted = "第一行😀\nsecond *literal* | text"
            board.setString(pasted, forType: .string)
            #expect(controller.textView.readSelection(from: board, type: .string))
            session.renderNow()
            #expect(controller.textView.string == pasted)
            if mode == .source { #expect(session.source == pasted) }
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
            controller.canEdit = false
            controller.textView.setSelectedRange(NSRange(location: 0, length: controller.textView.string.utf16.count))
            board.declareTypes([.string], owner: nil)
            #expect(controller.textView.writeSelection(to: board, type: .string))
            #expect(!controller.textView.readSelection(from: board, type: .string))
            #expect(session.source == source)
            controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(!controller.textView.writeSelection(to: board, type: .string))
        }
    }

    @Test func richClipboardPastesAsPlainText() throws {
        let session = DocumentSession(source: "Before")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.setSelectedRange(NSRange(location: 0, length: 6))
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        let text = NSAttributedString(string: "中文😀 *text*\nNext", attributes: [.font: NSFont.boldSystemFont(ofSize: 40)])
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(data, forType: .rtf)
        #expect(controller.textView.readSelection(from: board, type: .rtf))
        session.renderNow()
        #expect(controller.textView.string == text.string)
        let font = try #require(controller.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize == Typography.body)
        #expect(!NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }
}