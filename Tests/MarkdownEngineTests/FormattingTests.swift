import AppKit
import Testing
import MarkdownEngine
import EditorKit

@Suite(.serialized) @MainActor struct FormattingTests {
    @Test func pendingWhitespaceAndMultilineNeverWriteInvalidMarkers() {
        for sourceMode in [false, true] {
            for (text, expected) in [(" text ", " **text** "), (" ", " "), ("one\n\ntwo", "one\n\ntwo")] {
                let session = DocumentSession()
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                if sourceMode { controller.mode = .source }
                _ = controller.view
                #expect(controller.perform(.bold))
                controller.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
                #expect(session.source == expected)
                #expect(controller.pendingStyles.isEmpty)
                #expect(MarkdownRenderer.snapshot(source: session.source).text == MarkdownRenderer.snapshot(source: text).text)
            }
        }
    }

    @Test func headingBodyHandlesAllSyntaxWithoutClearingInline() {
        for (source, expected) in [("## **bold** ##\n\nkeep", "**bold**\n\nkeep"), ("**bold**\n===\n\nkeep", "**bold**\n\nkeep"), ("##\n\nkeep", "\n\nkeep"), ("> ## **bold**\n\nkeep", "> **bold**\n\nkeep")] {
            let session = DocumentSession(source: source)
            #expect(session.perform(.body, in: NSRange(location: 0, length: source.utf16.count)))
            #expect(session.source == expected)
        }
        let code = DocumentSession(source: "```\n# **literal**\n```")
        #expect(code.perform(.body, in: NSRange(location: 0, length: code.source.utf16.count)))
        #expect(code.source == "```\n# **literal**\n```")
    }

    @Test func pendingCombinationEscapingAndNoRenderedSnapshot() {
        for sourceMode in [false, true] {
            let session = DocumentSession()
            let controller = MarkdownEditorController(session: session)
            if sourceMode { controller.mode = .source }
            #expect(controller.perform(.italic))
            #expect(controller.perform(.bold))
            #expect(controller.perform(.strikethrough))
            _ = controller.view
            controller.textView.insertText("text*", replacementRange: NSRange(location: 0, length: 0))
            #expect(MarkdownRenderer.snapshot(source: session.source).text == "text*")
            for command in [FormattingCommand.bold, .italic, .strikethrough] {
                #expect(controller.formattingState(command) == .on)
            }
            controller.textView.insertText("next", replacementRange: controller.textView.selectedRange())
            #expect(MarkdownRenderer.snapshot(source: session.source).text == "text*next")
            for command in [FormattingCommand.bold, .italic, .strikethrough] {
                #expect(controller.formattingState(command) == .on)
            }
        }
    }

    @Test func controllerStatesMapUnicodeAndMixedSelections() {
        let session = DocumentSession(source: "**中文😀** plain\n\n- one\n\nnormal")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.setSelectedRange((controller.textView.string as NSString).range(of: "中文😀"))
        #expect(controller.formattingState(.bold) == .on)
        controller.mode = .source
        #expect(controller.formattingState(.bold) == .on)
        controller.mode = .richText
        controller.textView.setSelectedRange((controller.textView.string as NSString).range(of: "中文😀 plain"))
        #expect(controller.formattingState(.bold) == .mixed)
        let listAndPlain = (session.source as NSString).range(of: "- one\n\nnormal")
        #expect(session.formattingState(.unorderedList, in: listAndPlain) == .mixed)
        controller.canEdit = false
        #expect(controller.formattingState(.bold) == .unavailable)
        #expect(controller.pendingStyles.isEmpty)
    }

    @Test func tableColumnLimitAndDelimiterProtection() {
        let source = "|" + String(repeating: " A |", count: 64) + "\n|" + String(repeating: " --- |", count: 64) + "\n"
        let session = DocumentSession(source: source)
        #expect(session.formattingState(.tableInsertColumn) == .unavailable)
        #expect(!session.perform(.tableInsertColumn))
        let delimiter = (source as NSString).range(of: "---")
        #expect(session.formattingState(.tableDeleteRow, in: delimiter) == .unavailable)
        #expect(!session.perform(.tableDeleteRow, in: delimiter))
    }

    @Test func existingLinksEditDestinationWithoutNesting() {
        let source = "before [**label**](old \"title\") after\n\n<!--keep-->"
        for selectWholeLink in [false, true] {
            let session = DocumentSession(source: source)
            let selection = (source as NSString).range(of: selectWholeLink ? "[**label**](old \"title\")" : "label")
            #expect(session.perform(.insertLink(destination: "new path(a)>"), in: selection))
            #expect(session.source == "before [**label**](<new path(a)%3E> \"title\") after\n\n<!--keep-->")
            #expect(MarkdownRenderer.snapshot(source: session.source).text == MarkdownRenderer.snapshot(source: source).text)
        }
        let reference = DocumentSession(source: "[label][id]\n\n[id]: old")
        #expect(reference.perform(.insertLink(destination: "new"), in: NSRange(location: 2, length: 0)))
        #expect(reference.source == "[label](<new>)\n\n[id]: old")
    }

    @Test func attachmentImageCommandReplacesExistingImage() {
        let source = "before ![alt](old.png \"caption\") after"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let attachment = session.renderSnapshot!.sourceMap.segments.first { $0.kind == .attachment }!
        controller.textView.setSelectedRange(attachment.displayedNSRange)
        #expect(controller.perform(.insertImage(path: "new image.png")))
        #expect(session.source == "before ![alt](<new image.png> \"caption\") after")
        #expect(controller.textView.string == "before \u{FFFC} after")
        session.undoManager.undo()
        #expect(session.source == source)
    }

    @Test func emptyDocumentPendingFormattingFirstInput() {
        for sourceMode in [false, true] {
            for (command, expected) in [(FormattingCommand.bold, "**text**"), (.italic, "*text*"), (.strikethrough, "~~text~~"), (.inlineCode, "`text`")] {
                let session = DocumentSession()
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                if sourceMode { controller.mode = .source }
                _ = controller.view
                controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
                #expect(controller.perform(command))
                #expect(controller.formattingState(command) == .on)
                #expect(session.source == "")
                controller.textView.insertText("text", replacementRange: NSRange(location: 0, length: 0))
                #expect(session.source == expected)
                #expect(controller.pendingStyles.isEmpty)
                #expect(controller.formattingState(command) == .on)
                #expect(MarkdownRenderer.snapshot(source: session.source).text == "text")
                controller.textView.insertText("more", replacementRange: controller.textView.selectedRange())
                #expect(MarkdownRenderer.snapshot(source: session.source).text == "textmore")
            }
        }
    }

    @Test func pendingToggleOffSelectionAndCodeProtection() {
        let session = DocumentSession(source: "plain\n\n```\ncode\n```")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(controller.perform(.bold))
        #expect(controller.pendingStyles == [.bold])
        #expect(controller.perform(.bold))
        #expect(controller.formattingState(.bold) == .off)
        controller.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(session.source.hasPrefix("xplain"))
        #expect(controller.perform(.bold))
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(controller.pendingStyles.isEmpty)
        let code = (controller.textView.string as NSString).range(of: "code")
        controller.textView.setSelectedRange(NSRange(location: code.location, length: 0))
        #expect(controller.formattingState(.bold) == .unavailable)
        #expect(!controller.perform(.bold))
        let empty = DocumentSession()
        #expect(!empty.perform(.bold))
        #expect(!empty.perform(.inlineCode))
        #expect(empty.source == "")
    }

    @Test func pendingFormattingComposesAndUndoesAtomically() {
        let session = DocumentSession()
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        #expect(controller.perform(.bold))
        controller.textView.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(session.source == "")
        controller.textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(session.source == "**中文**")
        #expect(controller.textView.string == "中文")
        session.undoManager.undo()
        #expect(session.source == "")
    }

    @Test func sourceGeometryStates() {
        let source = "# **bold** plain\n\n*italic* ~~strike~~ `code`\n\n- item\n\n1. ordered\n\n- [ ] task\n\n> quote"
        let session = DocumentSession(source: source)
        for (text, command) in [("bold", FormattingCommand.bold), ("italic", .italic), ("strike", .strikethrough), ("code", .inlineCode), ("item", .unorderedList), ("ordered", .orderedList), ("task", .taskList), ("quote", .quote)] {
            let range = (source as NSString).range(of: text)
            #expect(session.formattingState(command, in: range) == .on)
            #expect(session.formattingState(command, in: NSRange(location: range.location, length: 0)) == .on)
            #expect(session.formattingState(command, in: (source as NSString).range(of: "plain")) == .off)
        }
        #expect(session.formattingState(.bold, in: (source as NSString).range(of: "**bold** plain")) == .mixed)
        #expect(session.formattingState(.heading(level: 1), in: (source as NSString).range(of: "plain")) == .on)
        #expect(session.formattingState(.heading(level: 2), in: (source as NSString).range(of: "plain")) == .off)
        #expect(session.formattingState(.bold, in: NSRange(location: NSNotFound, length: 0)) == .unavailable)
        #expect(session.formattingState(.indent) == .off)
        let adjacent = DocumentSession(source: "**one** **two**")
        #expect(adjacent.formattingState(.bold, in: NSRange(location: 0, length: adjacent.source.utf16.count)) == .on)
    }

    @Test func codeBlocksDisableInlineCommands() {
        let session = DocumentSession(source: "```\nvalue\n```\n\nplain")
        let range = (session.source as NSString).range(of: "value")
        for command in [FormattingCommand.bold, .italic, .strikethrough, .inlineCode] {
            #expect(session.formattingState(command, in: range) == .unavailable)
            #expect(!session.perform(command, in: range))
        }
        #expect(session.formattingState(.codeBlock, in: range) == .on)
    }

    @Test func bodyPreservesInlineFormatting() {
        let session = DocumentSession(source: "## **bold** and *italic*\n\nkeep")
        #expect(session.formattingState(.body) == .off)
        #expect(session.perform(.body))
        #expect(session.source == "**bold** and *italic*\n\nkeep")
        #expect(session.formattingState(.body) == .on)
    }

    @Test func tableAvailabilityMatchesExecution() {
        let source = "| A | B |\n| --- | --- |\n| one | two |\n\nplain"
        let session = DocumentSession(source: source)
        #expect(session.formattingState(.tableDeleteRow, in: (source as NSString).range(of: "A")) == .unavailable)
        #expect(session.formattingState(.tableDeleteRow, in: (source as NSString).range(of: "one")) == .off)
        #expect(session.formattingState(.tableInsertColumn, in: (source as NSString).range(of: "two")) == .off)
        #expect(session.formattingState(.tableInsertRow, in: (source as NSString).range(of: "plain")) == .unavailable)
        #expect(session.source == source)
        let single = DocumentSession(source: "| A |\n| --- |\n| one |")
        #expect(single.formattingState(.tableDeleteColumn) == .unavailable)
    }
}