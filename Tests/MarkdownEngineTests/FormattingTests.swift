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

    @Test func insertingLinkAtEmptySelectionUsesVisibleDestination() {
        for sourceMode in [false, true] {
            for source in ["", "\n\n", "Before\n\n\nAfter", "中文 😀 "] {
                for destination in ["https://example.com", "https://example.com/a[b]?q=中文&name=*test*"] {
                    let session = DocumentSession(source: source)
                    session.undoManager.groupsByEvent = false
                    session.renderNow()
                    let controller = MarkdownEditorController(session: session)
                    _ = controller.view
                    if sourceMode { controller.mode = .source }
                    let editor = controller.textView!
                    let insertion = source == "Before\n\n\nAfter" ? 8 : source.utf16.count
                    editor.setSelectedRange(NSRange(location: insertion, length: 0))
                    session.undoManager.beginUndoGrouping()
                    #expect(controller.perform(.insertLink(destination: destination)))
                    session.undoManager.endUndoGrouping()
                    let snapshot = MarkdownRenderer.snapshot(source: session.source)
                    #expect(snapshot.text == (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: destination))
                    #expect(snapshot.runs.contains { $0.destination == destination && $0.range.length > 0 })
                    if !sourceMode {
                        #expect(editor.string == snapshot.text)
                        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == destination)
                    }
                    session.undoManager.undo()
                    #expect(session.source == source)
                    session.undoManager.redo()
                    #expect(MarkdownRenderer.snapshot(source: session.source).text == snapshot.text)
                    session.undoManager.beginUndoGrouping()
                    editor.insertText("Label", replacementRange: editor.selectedRange())
                    session.undoManager.endUndoGrouping()
                    session.renderNow()
                    let renamed = MarkdownRenderer.snapshot(source: session.source)
                    #expect(renamed.text == (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "Label"))
                    #expect(renamed.runs.contains { $0.destination == destination })
                    session.undoManager.undo()
                    #expect(MarkdownRenderer.snapshot(source: session.source).text == snapshot.text)
                }
            }
        }
    }

    @Test func explicitLinkDisplayTextIsLiteralAndUndoable() {
        for sourceMode in [false, true] {
            for source in ["", "before selected after", "before [**selected**](old \"title\") after"] {
                for label in ["显示文字 😀", "[name] *literal* &amp; `code`", ""] {
                    let destination = "https://example.com/a(b)?q=中文"
                    let session = DocumentSession(source: source)
                    session.undoManager.groupsByEvent = false
                    session.renderNow()
                    let controller = MarkdownEditorController(session: session)
                    _ = controller.view
                    if sourceMode { controller.mode = .source }
                    let editor = controller.textView!
                    let selection = source.isEmpty ? NSRange(location: 0, length: 0) : (editor.string as NSString).range(of: "selected")
                    editor.setSelectedRange(selection)
                    session.undoManager.beginUndoGrouping()
                    #expect(controller.perform(.insertLink(destination: destination, label: label)))
                    session.undoManager.endUndoGrouping()
                    let visible = label.isEmpty ? destination : label
                    let snapshot = MarkdownRenderer.snapshot(source: session.source)
                    #expect(snapshot.text == (source.isEmpty ? visible : "before " + visible + " after"))
                    #expect(snapshot.runs.contains { $0.destination == destination })
                    #expect(snapshot.runs.allSatisfy { !$0.style.contains(.bold) && !$0.style.contains(.italic) && !$0.style.contains(.code) })
                    if source.contains("\"title\"") { #expect(session.source.contains("\"title\"")) }
                    if !sourceMode { #expect((editor.string as NSString).substring(with: editor.selectedRange()) == visible) }
                    let inserted = session.source
                    session.undoManager.undo()
                    #expect(session.source == source)
                    session.undoManager.redo()
                    #expect(session.source == inserted)
                }
            }
        }
    }

    @Test func linkContextAndRemovalPreserveInlineFormatting() throws {
        for source in ["before [**中文 😀** and *text*](https://example.com \"title\") after",
                       "before [**中文 😀** and *text*][id] after\n\n[id]: https://example.com \"title\""] {
            let session = DocumentSession(source: source)
            let selection = (source as NSString).range(of: "中文 😀")
            let link = try #require(session.link(in: selection))
            #expect(link.displayText == "中文 😀 and text")
            #expect(link.destination == "https://example.com")
            #expect(session.link(in: NSRange(location: selection.location, length: 0)) != nil)
            #expect(session.link(in: NSRange(location: 0, length: 0)) == nil)
            #expect(session.link(in: NSRange(location: NSMaxRange(link.sourceRange), length: 0)) == nil)
            #expect(session.removeLink(in: selection))
            #expect(session.source.hasPrefix("before **中文 😀** and *text* after"))
            #expect(!MarkdownRenderer.snapshot(source: session.source).runs.contains { $0.destination != nil })
            session.undoManager.undo()
            #expect(session.source == source)
            session.canEdit = false
            #expect(!session.removeLink(in: selection))
            #expect(session.source == source)
        }
        for source in ["`[text](url)`", "![alt](image.png)", "plain"] {
            let session = DocumentSession(source: source)
            #expect(session.link(in: NSRange(location: 2, length: 0)) == nil)
            #expect(!session.removeLink(in: NSRange(location: 2, length: 0)))
        }
    }

    @Test func removingLinkClearsNativeLinkDrawingAttributes() throws {
        for label in ["百度", "**百度**", "Baidu 中文 😀"] {
            let source = "[previous](https://previous.example)\n\n\n[\(label)](https://baidu.com)\n\n[dddd](https://next.example)"
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = controller.view
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            window.contentView?.layoutSubtreeIfNeeded()
            let editor = controller.textView!
            editor.appearance = NSAppearance(named: .aqua)
            let layout = try #require(editor.layoutManager)
            let container = try #require(editor.textContainer)
            layout.ensureLayout(for: container)
            window.displayIfNeeded()
            let range = (editor.string as NSString).range(of: label.contains("Baidu") ? "Baidu 中文 😀" : "百度")
            func bluePixels(in range: NSRange) throws -> Int {
                layout.ensureLayout(for: container)
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    .insetBy(dx: -2, dy: -8)
                let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: rect))
                editor.cacheDisplay(in: rect, to: bitmap)
                var count = 0
                for vertical in 0..<bitmap.pixelsHigh {
                    for horizontal in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: horizontal, y: vertical)?.usingColorSpace(.deviceRGB),
                           color.blueComponent > color.redComponent + 0.2,
                           color.blueComponent > color.greenComponent + 0.05 { count += 1 }
                    }
                }
                return count
            }
            #expect(try bluePixels(in: range) > 0)
            let link = try #require(controller.link(atDisplayedOffset: range.location))
            #expect(controller.removeLink(in: link.sourceRange))
            window.displayIfNeeded()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(try bluePixels(in: range) == 0)
            let storage = try #require(editor.textStorage)
            for offset in range.location..<NSMaxRange(range) {
                #expect(storage.attribute(.link, at: offset, effectiveRange: nil) == nil)
                #expect(storage.attribute(.underlineStyle, at: offset, effectiveRange: nil) == nil)
                #expect(layout.temporaryAttribute(.link, atCharacterIndex: offset, effectiveRange: nil) == nil)
                #expect(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: offset, effectiveRange: nil) == nil)
            }
            let next = (editor.string as NSString).range(of: "dddd")
            #expect(storage.attribute(.link, at: next.location, effectiveRange: nil) != nil)
            #expect(try bluePixels(in: next) > 0)
            func visibleBluePixels() throws -> Set<Int> {
                layout.ensureLayout(for: container)
                let rect = editor.visibleRect
                let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: rect))
                editor.cacheDisplay(in: rect, to: bitmap)
                var pixels: Set<Int> = []
                for vertical in 0..<bitmap.pixelsHigh {
                    for horizontal in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: horizontal, y: vertical)?.usingColorSpace(.deviceRGB),
                           color.blueComponent > color.redComponent + 0.2,
                           color.blueComponent > color.greenComponent + 0.05 {
                            pixels.insert(vertical * bitmap.pixelsWide + horizontal)
                        }
                    }
                }
                return pixels
            }
            let removedSource = session.source
            let selection = editor.selectedRange()
            let scrollOrigin = editor.enclosingScrollView!.contentView.bounds.origin
            let removedPixels = try visibleBluePixels()
            controller.mode = .source
            controller.mode = .richText
            #expect(try visibleBluePixels() == removedPixels)
            #expect(session.source == removedSource)
            #expect(editor.selectedRange() == selection)
            #expect(editor.enclosingScrollView!.contentView.bounds.origin == scrollOrigin)
            session.undoManager.undo()
            #expect(session.source == source)
            #expect(storage.attribute(.link, at: range.location, effectiveRange: nil) != nil)
            session.undoManager.redo()
            #expect(storage.attribute(.link, at: range.location, effectiveRange: nil) == nil)
        }
    }

    @Test func removingURLLabelsDoesNotLeaveAnAutomaticLink() {
        for source in ["[https://example.com](https://example.com)", "<https://example.com>", "<test@example.com>"] {
            let session = DocumentSession(source: source)
            let original = MarkdownRenderer.snapshot(source: source)
            #expect(session.removeLink(in: NSRange(location: 2, length: 0)))
            let snapshot = MarkdownRenderer.snapshot(source: session.source)
            #expect(snapshot.text == original.text)
            #expect(!snapshot.runs.contains { $0.destination != nil })
        }
    }

    @Test func linkContextMenusUseHitLinkAndPreserveSelection() throws {
        for mode in [EditorMode.richText, .source] {
            let source = "before [**中文 😀**](https://first.example) and [second](https://second.example) after"
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            controller.mode = mode
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = controller.view
            window.contentView?.layoutSubtreeIfNeeded()
            let editor = controller.textView!
            let layout = try #require(editor.layoutManager)
            let container = try #require(editor.textContainer)
            var hitDestination: String?
            controller.linkMenu = { link in
                hitDestination = link.destination
                let menu = NSMenu()
                menu.addItem(withTitle: "link-test", action: nil, keyEquivalent: "")
                return menu
            }
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            for (text, destination) in [("中文", "https://first.example"), ("second", "https://second.example")] {
                let range = (editor.string as NSString).range(of: text)
                #expect(controller.link(atDisplayedOffset: range.location)?.destination == destination)
                layout.ensureLayout(for: container)
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let point = editor.convert(NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y), to: nil)
                let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                #expect(editor.menu(for: event)?.items.first?.title == "link-test")
                #expect(hitDestination == destination)
                #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
                editor.setSelectedRange(NSRange(location: range.location, length: 0))
                #expect(controller.currentLink?.destination == destination)
                editor.setSelectedRange(NSRange(location: 0, length: 0))
            }
            let link = try #require(controller.link(atDisplayedOffset: (editor.string as NSString).range(of: "中文").location))
            #expect(controller.updateLink(in: link.sourceRange, destination: "https://updated.example", label: nil))
            #expect(session.source.contains("[**中文 😀**](<https://updated.example>)"))
            session.undoManager.undo()
            #expect(session.source == source)
            #expect(controller.removeLink(in: link.sourceRange))
            #expect(session.source.hasPrefix("before **中文 😀** and"))
            session.undoManager.undo()
            #expect(session.source == source)
            controller.canEdit = false
            #expect(!controller.removeLink(in: link.sourceRange))
            #expect(!controller.updateLink(in: link.sourceRange, destination: "new", label: nil))
            window.orderOut(nil)
        }
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
