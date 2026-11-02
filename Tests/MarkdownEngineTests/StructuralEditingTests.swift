import AppKit
import Testing
import MarkdownEngine
import EditorKit
import CoreText

@Suite(.serialized) @MainActor struct StructuralEditingTests {
    @Test func returnAfterApplyingQuoteShowsEditableNewLine() {
        for source in ["hello", "你好", "**hello**"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let editor = controller.textView!
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            #expect(controller.perform(.quote))
            let quoted = session.source
            let before = String(editor.string)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertNewline(nil)
            #expect(session.source == quoted + "\n> ")
            #expect(editor.string == before + "\n")
            #expect(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText("next", replacementRange: editor.selectedRange())
            session.renderNow()
            #expect(session.source == quoted + "\n> next")
            #expect(editor.string == before + "\nnext")
        }
    }

    @Test func emptyQuoteContinuationSupportsRepeatedReturnDeleteAndUndo() {
        for source in ["> hello", "> > hello", "> hello\n\nAfter"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            session.undoManager.groupsByEvent = false
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let editor = controller.textView!
            let location = NSMaxRange((editor.string as NSString).range(of: "hello"))
            editor.setSelectedRange(NSRange(location: location, length: 0))
            let before = String(editor.string)
            let prefix = source.hasPrefix("> >") ? "> > " : "> "
            session.undoManager.beginUndoGrouping()
            editor.insertNewline(nil)
            session.undoManager.endUndoGrouping()
            let expected = (before as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "\n")
            #expect(editor.string == expected)
            #expect(session.source == source.replacingOccurrences(of: "hello", with: "hello\n" + prefix))
            #expect(editor.selectedRange() == NSRange(location: location + 1, length: 0))
            session.undoManager.beginUndoGrouping()
            editor.insertNewline(nil)
            session.undoManager.endUndoGrouping()
            #expect(editor.selectedRange().location == location + 2)
            session.undoManager.undo()
            session.renderNow()
            #expect(editor.string == expected)
            session.undoManager.beginUndoGrouping()
            editor.deleteBackward(nil)
            session.undoManager.endUndoGrouping()
            session.renderNow()
            #expect(session.source == source)
            #expect(editor.string == before)
            session.undoManager.undo()
            session.renderNow()
            #expect(editor.string == expected)
        }
    }

    @Test func listTypographyPreservesSourceAndMarkerMapping() {
        let source = "Body\ntext\n\n- Item\n- [ ] Task\n- [x] Done\n\n1. Number\n"
        let snapshot = MarkdownRenderer.snapshot(source: source)
        let rendered = MarkdownRenderer.render(snapshot: snapshot).attributedString
        let body = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        #expect(body.lineSpacing == 3)
        for marker in snapshot.sourceMap.segments where marker.isListMarker {
            let range = marker.displayedNSRange
            let paragraph = rendered.attribute(.paragraphStyle, at: NSMaxRange(range), effectiveRange: nil) as! NSParagraphStyle
            #expect(paragraph.lineSpacing > body.lineSpacing)
            #expect(paragraph.paragraphSpacing > body.paragraphSpacing)
            #expect(rendered.attribute(.kern, at: NSMaxRange(range) - 1, effectiveRange: nil) as? Int == 5)
        }
        let task = (rendered.string as NSString).range(of: "\u{2610}")
        #expect(rendered.attribute(.markdownCheckbox, at: task.location, effectiveRange: nil) as? Bool == false)
        let done = (rendered.string as NSString).range(of: "\u{2611}")
        #expect(rendered.attribute(.markdownCheckbox, at: done.location, effectiveRange: nil) as? Bool == true)
        let taskFont = rendered.attribute(.font, at: task.location, effectiveRange: nil) as! NSFont
        let doneFont = rendered.attribute(.font, at: done.location, effectiveRange: nil) as! NSFont
        #expect(taskFont == doneFont)
        #expect(taskFont.coveredCharacterSet.contains(UnicodeScalar(0x2610)!))
        #expect(taskFont.coveredCharacterSet.contains(UnicodeScalar(0x2611)!))
        #expect(snapshot.source == source)
    }

    @Test func roundedTaskControlsRespectReadOnlyAndSourceMode() throws {
        _ = NSApplication.shared
        let source = "## Lists\n\nBody text wraps naturally with a little more breathing room.\nSecond body line.\n\n- First item\n- Second item\n\n1. First ordered item\n2. Second ordered item\n\n- [ ] Pending task\n- [x] Completed task\n"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        let layout = try #require(editor.layoutManager as? TableLayoutManager)
        layout.ensureLayout(for: editor.textContainer!)
        let task = (editor.string as NSString).range(of: "\u{2610}").location
        let bounds = try #require(layout.checkboxRect(at: task))
        #expect(bounds.size == NSSize(width: 16, height: 16))
        #expect(layout.checkboxRect(at: 0) == nil)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        controller.canEdit = false
        #expect(!controller.toggleCheckbox(atDisplayedOffset: task))
        #expect(session.source == source)
        controller.mode = .source
        #expect(layout.checkboxRect(at: task) == nil)
        window.contentViewController = nil
    }

    @Test func taskCursorRectsHandleClippedAndOffscreenControls() throws {
        _ = NSApplication.shared
        let session = DocumentSession(source: String(repeating: "- [ ] Task\n", count: 80))
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        let layout = try #require(editor.layoutManager as? TableLayoutManager)
        layout.ensureLayout(for: editor.textContainer!)
        let snapshot = try #require(session.renderSnapshot)
        let marker = try #require(snapshot.sourceMap.segments.first { $0.isListMarker })
        let bounds = try #require(layout.checkboxRect(at: marker.displayedNSRange.location))
        let origin = editor.textContainerOrigin
        for offset in [CGFloat(0), bounds.minY + origin.y + 1, bounds.maxY + origin.y + 0.5, CGFloat(1000)] {
            editor.scroll(NSPoint(x: 0, y: offset))
            editor.resetCursorRects()
        }
        controller.canEdit = false
        editor.resetCursorRects()
        controller.mode = .source
        editor.resetCursorRects()
        #expect(session.source == String(repeating: "- [ ] Task\n", count: 80))
        window.contentViewController = nil
    }

    @Test func taskAlignmentHoverAndToggleKeepViewportStable() throws {
        _ = NSApplication.shared
        let session = DocumentSession(source: String(repeating: "Paragraph above tasks.\n\n", count: 50) + "- [ ] 中文任务\n- [ ] English task\n" + String(repeating: "Paragraph below tasks.\n\n", count: 50))
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        let layout = try #require(editor.layoutManager as? TableLayoutManager)
        let storage = try #require(editor.textStorage)
        let clip = try #require(editor.enclosingScrollView?.contentView)
        clip.postsBoundsChangedNotifications = true
        session.undoManager.groupsByEvent = false
        layout.ensureLayout(for: editor.textContainer!)
        func lineGeometry() -> [NSRect] {
            var rectangles: [NSRect] = []
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, used, _, _, _ in
                rectangles.append(rect)
                rectangles.append(used)
            }
            return rectangles
        }
        for marker in session.renderSnapshot!.sourceMap.segments where marker.isListMarker {
            let character = marker.displayedNSRange.location
            let bounds = try #require(layout.checkboxRect(at: character))
            let reference = NSMaxRange(marker.displayedNSRange)
            let glyph = layout.glyphIndexForCharacter(at: reference)
            let baseline = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + layout.location(forGlyphAt: glyph).y
            let sample = storage.attributedSubstring(from: (storage.string as NSString).rangeOfComposedCharacterSequence(at: reference))
            let ink = CTLineGetImageBounds(CTLineCreateWithAttributedString(sample), nil)
            #expect(abs(bounds.midY - (baseline - ink.midY)) < 0.01)
            editor.scroll(NSPoint(x: 0, y: bounds.minY + editor.textContainerOrigin.y - 80))
            let point = editor.convert(NSPoint(x: bounds.midX + editor.textContainerOrigin.x, y: bounds.midY + editor.textContainerOrigin.y), to: nil)
            let hover = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
            editor.cursorUpdate(with: hover)
            #expect(NSCursor.current == NSCursor.pointingHand)
            NSCursor.iBeam.set()
            editor.mouseMoved(with: hover)
            #expect(NSCursor.current == NSCursor.pointingHand)
            let before = clip.bounds.origin
            let geometry = lineGeometry()
            let selected = editor.selectedRange()
            let recorder = StorageEditRecorder()
            let scrolling = ViewportChangeRecorder()
            NotificationCenter.default.addObserver(scrolling, selector: #selector(ViewportChangeRecorder.changed(_:)), name: NSView.boundsDidChangeNotification, object: clip)
            storage.delegate = recorder
            session.undoManager.beginUndoGrouping()
            #expect(controller.toggleCheckbox(atDisplayedOffset: character))
            session.undoManager.endUndoGrouping()
            layout.ensureLayout(for: editor.textContainer!)
            #expect(lineGeometry() == geometry)
            #expect(clip.bounds.origin == before)
            #expect(editor.selectedRange() == selected)
            #expect(recorder.characterEdits == 1)
            #expect(recorder.editedRanges == [NSRange(location: character, length: 1)])
            session.undoManager.undo()
            session.renderNow()
            layout.ensureLayout(for: editor.textContainer!)
            #expect(lineGeometry() == geometry)
            session.undoManager.redo()
            session.renderNow()
            layout.ensureLayout(for: editor.textContainer!)
            #expect(lineGeometry() == geometry)
            #expect(clip.bounds.origin == before)
            #expect(scrolling.origins.allSatisfy { $0 == before })
            NotificationCenter.default.removeObserver(scrolling)
            storage.delegate = nil
        }
        window.contentViewController = nil
    }

    @Test func orderedListSpacesAndTabKeepCollapsedCaret() {
        for source in ["1. ", "1. hello", "Before\n\n1. ", "1. first\n2. "] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let markers = session.sourceMap!.segments.filter(\.isListMarker)
            let marker = markers.last!
            controller.textView.setSelectedRange(NSRange(location: NSMaxRange(marker.displayedNSRange), length: 0))
            let insertion = NSMaxRange(marker.sourceNSRange)
            for count in 1...3 {
                controller.textView.insertText(" ", replacementRange: controller.textView.selectedRange())
                session.renderNow()
                let expected = (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: String(repeating: " ", count: count))
                #expect(session.source == expected)
                #expect(controller.textView.selectedRange().length == 0)
                #expect(controller.selectedSourceRange().location == insertion + count)
            }
        }
        for source in ["1. ", "1. hello", "1. first\n2. hello"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let marker = session.sourceMap!.segments.last(where: \.isListMarker)!
            controller.textView.setSelectedRange(NSRange(location: NSMaxRange(marker.displayedNSRange), length: 0))
            controller.textView.insertTab(nil)
            session.renderNow()
            #expect(controller.textView.selectedRange().length == 0)
            let anchor = controller.selectedSourceRange().location
            let before = session.source
            controller.textView.insertText("X", replacementRange: controller.textView.selectedRange())
            session.renderNow()
            #expect(session.source == (before as NSString).replacingCharacters(in: NSRange(location: anchor, length: 0), with: "X"))
        }
    }

    @Test func spaceInsideOrderedMarkerIsInsertedAfterMarker() {
        let session = DocumentSession(source: "1. hello")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.setSelectedRange(NSRange(location: 1, length: 0))
        controller.textView.insertText(" ", replacementRange: controller.textView.selectedRange())
        #expect(controller.textView.string.hasPrefix("1. "))
        #expect(controller.textView.selectedRange().length == 0)
        controller.textView.insertText("X", replacementRange: controller.textView.selectedRange())
        session.renderNow()
        #expect(session.source == "1.  Xhello")
        #expect(controller.textView.string.hasPrefix("1. "))
    }

    @Test func incompleteEntityAfterOrderedListCanBeDeleted() {
        let source = "1. 哈哈哈\n2. 哈哈等等\n&#3\n\n点多到\n"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let range = (controller.textView.string as NSString).range(of: "&#3")
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound else { return }
        for segment in session.sourceMap!.segments where NSIntersectionRange(segment.displayedNSRange, range).length > 0 {
            #expect(segment.isIdentity, "Mapping: \(segment), raw: \((source as NSString).substring(with: segment.sourceNSRange))")
        }
        controller.textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        for remaining in ["&#", "&", ""] {
            controller.textView.deleteBackward(nil)
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: "&#3", with: remaining))
        }
    }

    @Test func incompleteEntityListContinuationSupportsSelectionUndoAndRapidDeletion() {
        for marker in ["1.", "10.", "-"] {
            let source = "Before\n\n" + marker + " 哈哈等等\n&#3\n\nAfter"
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let range = (controller.textView.string as NSString).range(of: "&#3")
            #expect(range.location != NSNotFound)
            guard range.location != NSNotFound else { continue }
            session.undoManager.groupsByEvent = false
            controller.textView.setSelectedRange(range)
            session.undoManager.beginUndoGrouping()
            controller.textView.deleteBackward(nil)
            session.undoManager.endUndoGrouping()
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: "&#3", with: ""))
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
            controller.textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            session.undoManager.beginUndoGrouping()
            for _ in 0..<3 { controller.textView.deleteBackward(nil) }
            session.undoManager.endUndoGrouping()
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: "&#3", with: ""))
        }
    }

    @Test func tabSpacedOrderedListKeepsExistingChineseAndNewItems() {
        let source = "Before\n\n1. \t\t点多到等等\n\nAfter"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let originalWord = (controller.textView.string as NSString).range(of: "点多到等等")
        #expect(originalWord.location != NSNotFound)
        guard originalWord.location != NSNotFound else { return }
        controller.textView.setSelectedRange(NSRange(location: NSMaxRange(originalWord), length: 0))
        controller.textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: controller.textView.selectedRange())
        controller.textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        session.renderNow()
        #expect(session.source == source.replacingOccurrences(of: "点多到等等", with: "点多到等等中文"))
        #expect(controller.textView.string.contains("点多到等等中文"))
        controller.textView.insertNewline(nil)
        session.renderNow()
        #expect(session.source.contains("点多到等等中文\n2. \t\t"))
        let caret = controller.textView.selectedRange()
        controller.textView.setMarkedText("xin", selectedRange: NSRange(location: 3, length: 0), replacementRange: caret)
        controller.textView.insertText("新项", replacementRange: NSRange(location: NSNotFound, length: 0))
        session.renderNow()
        #expect(session.source.contains("2. \t\t新项"))
        #expect(controller.textView.string.contains("新项"))
    }

    @Test func orderedListChineseCompositionAndReturnStayOnTheItem() {
        for source in ["1. ", "1. \n\nAfter", "Before\n\n1. \n\nAfter", "1. \t\t点多到等等\n\nAfter"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let marker = (controller.textView.string as NSString).range(of: "1. ")
            let body = (controller.textView.string as NSString).range(of: "点多到等等")
            let offset = body.location == NSNotFound ? NSMaxRange(marker) : body.location
            controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
            let insertion = controller.selectedSourceRange().location
            controller.textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: offset, length: 0))
            #expect(session.source == source)
            controller.textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
            session.renderNow()
            #expect(session.source == (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "中文"))
            #expect(controller.textView.string.contains("中文"))
            #expect(controller.textView.string == MarkdownRenderer.snapshot(source: session.source).text)
            #expect(controller.textView.selectedRange() == session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: NSRange(location: insertion + 2, length: 0)))
            controller.textView.insertNewline(nil)
            session.renderNow()
            #expect(session.source.contains("中文\n2. "))
            #expect(controller.textView.string.contains("中文\n2. "))
        }
    }

    @Test func orderedListCreatedFromMenuCanBeEditedAndRemoved() {
        let session = DocumentSession()
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        #expect(controller.perform(.orderedList))
        session.undoManager.endUndoGrouping()
        #expect(controller.textView.selectedRange() == NSRange(location: 3, length: 0))
        session.undoManager.beginUndoGrouping()
        controller.textView.insertText("中文😀", replacementRange: controller.textView.selectedRange())
        session.undoManager.endUndoGrouping()
        session.renderNow()
        #expect(session.source == "1. 中文😀")
        session.undoManager.beginUndoGrouping()
        controller.textView.setSelectedRange(NSRange(location: 0, length: controller.textView.string.utf16.count))
        controller.textView.deleteBackward(nil)
        session.undoManager.endUndoGrouping()
        session.renderNow()
        #expect(session.source.isEmpty)
        session.undoManager.undo()
        session.renderNow()
        #expect(session.source == "1. 中文😀")
        controller.textView.setSelectedRange(NSRange(location: controller.textView.string.utf16.count, length: 0))
        session.undoManager.beginUndoGrouping()
        controller.textView.insertNewline(nil)
        session.undoManager.endUndoGrouping()
        session.renderNow()
        #expect(session.source == "1. 中文😀\n2. ")
        session.undoManager.beginUndoGrouping()
        controller.textView.insertNewline(nil)
        session.undoManager.endUndoGrouping()
        session.renderNow()
        #expect(session.source == "1. 中文😀\n")
    }

    @Test func orderedListAcceptsTypingReturnAndMarkerDeletion() {
        for prefix in ["", "Before\n\n"] {
            let session = DocumentSession(source: prefix + "1. ")
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            controller.textView.setSelectedRange(NSRange(location: controller.textView.string.utf16.count, length: 0))
            controller.textView.insertText("hello", replacementRange: controller.textView.selectedRange())
            session.renderNow()
            #expect(session.source == prefix + "1. hello")
            controller.textView.insertNewline(nil)
            session.renderNow()
            #expect(session.source == prefix + "1. hello\n2. ")
            controller.textView.insertText("next", replacementRange: controller.textView.selectedRange())
            session.renderNow()
            #expect(session.source == prefix + "1. hello\n2. next")
        }
        for source in ["1. ", "1.", "1. hello", "Before\n\n1. hello"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let marker = (controller.textView.string as NSString).range(of: "1. ")
            controller.textView.setSelectedRange(NSRange(location: NSMaxRange(marker), length: 0))
            controller.textView.deleteBackward(nil)
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: source.hasSuffix("1.") ? "1." : "1. ", with: ""))
        }
    }

    @Test func emptyListWithoutTrailingSpaceExitsAndEmptyCheckboxToggles() {
        for source in ["-", "1.", "- ", "- [ ] "] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            controller.textView.setSelectedRange(NSRange(location: controller.textView.string.utf16.count, length: 0))
            controller.textView.insertNewline(nil)
            #expect(session.source == "")
        }
        let task = DocumentSession(source: "- [ ] ")
        task.renderNow()
        let controller = MarkdownEditorController(session: task)
        _ = controller.view
        #expect(controller.toggleCheckbox(atDisplayedOffset: 0))
        #expect(task.source == "- [x] ")
        controller.mode = .source
        #expect(!controller.toggleCheckbox(atDisplayedOffset: 0))
    }

    @Test func nativeEditUndoInvalidatesRenderedCache() {
        let session = DocumentSession(source: "**body**")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.insertText("x", replacementRange: NSRange(location: 1, length: 0))
        #expect(controller.textView.string == "bxody")
        session.undoManager.undo()
        #expect(session.source == "**body**")
        #expect(controller.textView.string == "body")
        #expect(controller.selectedSourceRange() == session.selectedSourceRange)
    }

    @Test func raggedTableColumnsAndNestedTablePrefixes() {
        let source = "| A | B |\n| --- | --- |\n| short |\n| one | two | extra |\n"
        let session = DocumentSession(source: source)
        #expect(session.perform(.tableInsertColumn, in: (source as NSString).range(of: "B")))
        #expect(session.source.contains("| short |   |   |\n"))
        #expect(session.source.contains("| one | two |   | extra |\n"))
        let deletion = DocumentSession(source: source)
        #expect(deletion.perform(.tableDeleteColumn, in: (source as NSString).range(of: "B")))
        #expect(deletion.source.contains("| short |\n"))
        #expect(deletion.source.contains("| one | extra |\n"))
        let quoted = DocumentSession(source: "> | A | B |\n> | --- | --- |\n> | one | two |\n\nkeep")
        #expect(quoted.perform(.tableInsertRow, in: (quoted.source as NSString).range(of: "one")))
        #expect(quoted.source.contains("> | one | two |\n> |   |   |\n\nkeep"))
        #expect(quoted.perform(.tableInsertColumn, in: (quoted.source as NSString).range(of: "A")))
        #expect(quoted.source.hasPrefix("> | A |   | B |\n> | --- | --- | --- |"))
    }

    @Test func repeatedRenderingDoesNotReplaceStorageOrReloadImages() {
        let session = DocumentSession(source: "![alt](image.png) **body**")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        var requests = 0
        controller.imageProvider = { _ in requests += 1; return NSImage(size: NSSize(width: 20, height: 20)) }
        _ = controller.view
        let recorder = StorageEditRecorder()
        controller.textView.textStorage?.delegate = recorder
        session.renderNow()
        session.renderNow()
        session.canEdit = false
        session.canEdit = true
        #expect(recorder.characterEdits == 0)
        #expect(requests == 1)
        controller.imageProvider = { _ in requests += 1; return nil }
        #expect(requests == 2)
        #expect(recorder.characterEdits == 1)
        controller.mode = .source
        recorder.characterEdits = 0
        session.renderNow()
        session.canEdit = false
        #expect(recorder.characterEdits == 0)
        controller.textView.textStorage?.delegate = nil
    }

    @Test func checkboxMouseDownHitsActualGlyph() {
        _ = NSApplication.shared
        let session = DocumentSession(source: "- [ ] task")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        let layout = editor.layoutManager!
        layout.ensureLayout(for: editor.textContainer!)
        let glyph = layout.glyphIndexForCharacter(at: 0)
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: editor.textContainer!)
        let point = editor.convert(NSPoint(x: bounds.midX + editor.textContainerOrigin.x, y: bounds.midY + editor.textContainerOrigin.y), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        editor.mouseDown(with: event)
        #expect(session.source == "- [x] task")
        #expect(editor.string.hasPrefix("\u{2611}"))
        window.contentViewController = nil
    }

    @Test func codeFenceSafetyRemainsIntact() {
        let session = DocumentSession(source: "```swift\nvalue\n```\n")
        session.renderNow()
        let value = (session.renderSnapshot!.text as NSString).range(of: "value")
        #expect(!session.editRendered(range: value, replacement: "```"))
        #expect(!session.editRendered(range: value, replacement: "ok\n~~~"))
        #expect(session.source == "```swift\nvalue\n```\n")
        let wrapped = DocumentSession(source: "```\ninside")
        #expect(wrapped.perform(.codeBlock, in: NSRange(location: 0, length: wrapped.source.utf16.count)))
        #expect(wrapped.source.hasPrefix("\n````\n"))
    }

    @Test func richListReturnExitTabAndCheckbox() {
        for (source, expected) in [("- first", "- first\n- "), ("9) first", "9) first\n10) "), ("- [x] first", "- [x] first\n- [ ] "), ("  - child", "  - child\n  - "), ("> - first", "> - first\n> - "), ("- **bold**", "- **bold**\n- ")] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            controller.textView.setSelectedRange(NSRange(location: controller.textView.string.utf16.count, length: 0))
            controller.textView.insertNewline(nil)
            #expect(session.source == expected)
            controller.textView.insertNewline(nil)
            #expect(!session.source.hasSuffix("- "))
            #expect(!session.source.hasSuffix("[ ] "))
        }
        let session = DocumentSession(source: "- [ ] task\n\nplain [ ]")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        #expect(!controller.toggleCheckbox(atDisplayedOffset: 1))
        #expect(!controller.toggleCheckbox(atDisplayedOffset: 2))
        #expect(controller.toggleCheckbox(atDisplayedOffset: 0))
        #expect(session.source == "- [x] task\n\nplain [ ]")
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        controller.textView.insertTab(nil)
        #expect(session.source.hasPrefix("    - [x] task"))
        controller.textView.insertBacktab(nil)
        #expect(session.source == "- [x] task\n\nplain [ ]")
        session.canEdit = false
        #expect(!controller.toggleCheckbox(atDisplayedOffset: 0))
        controller.textView.insertNewline(nil)
        #expect(session.source == "- [x] task\n\nplain [ ]")
    }

    @Test func returnBeforeFollowingListItemDoesNotAddBlankLine() {
        for suffix in ["4. aaa\n", "4. \n\n\n4. aaa\n    \n\n\n点多到", "4. aaa\n    5  等等. \n", "\n4. aaa\n", "\n\n4. aaa\n", "", "\n\n点多到"] {
            let source = "1. 哈哈哈\n2. 哈哈等等\n3. 点多到\n" + suffix
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let word = (controller.textView.string as NSString).range(of: "3. 点多到")
            controller.textView.setSelectedRange(NSRange(location: NSMaxRange(word), length: 0))
            let insertion = NSMaxRange((source as NSString).range(of: "3. 点多到"))
            session.undoManager.groupsByEvent = false
            session.undoManager.beginUndoGrouping()
            controller.textView.insertNewline(nil)
            session.undoManager.endUndoGrouping()
            #expect(session.source == (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "\n4. "))
            let expectedPrefix = "1. 哈哈哈\n2. 哈哈等等\n3. 点多到\n4. "
            #expect(controller.textView.string.hasPrefix(expectedPrefix))
            if suffix.contains("4. ") {
                #expect(controller.textView.string.hasPrefix(expectedPrefix + "\n" + String(suffix.prefix { $0 == "\n" }) + "5. "))
            }
            if suffix.hasPrefix("4. \n\n\n4. aaa") {
                #expect(controller.textView.string.contains("4. \n5. \n\n\n6. aaa"))
            }
            session.renderNow()
            #expect(controller.textView.string.hasPrefix(expectedPrefix))
            session.undoManager.beginUndoGrouping()
            controller.textView.insertText("新项", replacementRange: controller.textView.selectedRange())
            session.undoManager.endUndoGrouping()
            session.renderNow()
            #expect(session.source.contains("3. 点多到\n4. 新项\n"))
            #expect(controller.textView.string.contains("3. 点多到\n4. 新项\n"))
            session.undoManager.undo()
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
        }
    }

    @Test func orderedListUsesStandardSequentialNumbersWithoutChangingSource() {
        for source in ["1. 哈哈哈\n2. 哈哈等等\n3. 点多到\n4. 点多到\n5. 大敌当前\n\n\n\n4. aaa\n", "1. first\n1. second\n9. aaa\n", "3) first\n7) aaa\n", "1. first\n   8. child\n   2. nested\n4. aaa\n"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let markers = session.renderSnapshot!.sourceMap.segments.filter { $0.isListMarker }
            let expectedNumbers = source.hasPrefix("3)") ? [3, 4] : source.contains("child") ? [1, 2] : source.contains("哈哈哈") ? [1, 2, 3, 4, 5, 6] : [1, 2, 3]
            #expect(markers.map { (controller.textView.string as NSString).substring(with: $0.displayedNSRange) } == expectedNumbers.map { "\($0). " })
            #expect(session.source == source)
            let word = (controller.textView.string as NSString).range(of: "aaa")
            controller.textView.setSelectedRange(NSRange(location: NSMaxRange(word), length: 0))
            let insertion = NSMaxRange((source as NSString).range(of: "aaa"))
            session.undoManager.groupsByEvent = false
            session.undoManager.beginUndoGrouping()
            controller.textView.insertText("X", replacementRange: controller.textView.selectedRange())
            session.undoManager.endUndoGrouping()
            session.renderNow()
            #expect(session.source == (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "X"))
            session.undoManager.beginUndoGrouping()
            controller.textView.insertNewline(nil)
            session.undoManager.endUndoGrouping()
            session.renderNow()
            let nextNumber = expectedNumbers.last! + 1
            #expect(controller.textView.string.contains("aaaX\n\(nextNumber). "))
            session.undoManager.undo()
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
        }
    }

    @Test func listContinuationCannotChangeCodeOrPlainText() {
        for source in ["plain - item", "```\n- item\n```", "- first\n  ```\n  - code\n  ```"] {
            let session = DocumentSession(source: source)
            let offset = (source as NSString).range(of: source.contains("code") ? "code" : "item").location
            #expect(!session.continueList(in: NSRange(location: offset + 4, length: 0)))
            #expect(session.source == source)
        }
        let session = DocumentSession(source: "- first\r\n- second")
        #expect(session.continueList(in: NSRange(location: 7, length: 0)))
        #expect(session.source == "- first\r\n- \r\n- second")
    }

    @Test func tableCommandsPreserveEscapesCodeAndSurroundingSource() {
        let source = "before\n\n| A | B |\n| :--- | ---: |\n| a\\|b | `c\\|d` |\n| last | value |\n\n<!--keep-->\n"
        let session = DocumentSession(source: source)
        #expect(session.perform(.tableInsertColumn, in: (source as NSString).range(of: "a\\|b")))
        #expect(session.source == "before\n\n| A |   | B |\n| :--- | --- | ---: |\n| a\\|b |   | `c\\|d` |\n| last |   | value |\n\n<!--keep-->\n")
        #expect(session.perform(.tableDeleteColumn, in: (session.source as NSString).range(of: "`c\\|d`")))
        #expect(session.source.contains("| a\\|b |   |\n"))
        #expect(session.source.hasSuffix("\n<!--keep-->\n"))
        let rowSession = DocumentSession(source: source)
        #expect(rowSession.perform(.tableInsertRow, in: (source as NSString).range(of: "A")))
        #expect(rowSession.source == source.replacingOccurrences(of: "| :--- | ---: |\n", with: "| :--- | ---: |\n|   |   |\n"))
        #expect(rowSession.perform(.tableDeleteRow, in: (rowSession.source as NSString).range(of: "a\\|b")))
        #expect(!rowSession.source.contains("a\\|b"))
        #expect(rowSession.source.contains("| last | value |"))
    }

    @Test func tableBoundaryProtectionAndCRLF() {
        let source = "A | B\r\n--- | ---\r\none | two"
        let session = DocumentSession(source: source)
        #expect(!session.perform(.tableDeleteRow, in: NSRange(location: 0, length: 0)))
        #expect(session.perform(.tableInsertRow, in: (source as NSString).range(of: "two")))
        #expect(session.source == source + "\r\n|   |   |")
        #expect(session.perform(.tableDeleteColumn, in: NSRange(location: 0, length: 0)))
        #expect(session.source.hasPrefix(" B\r\n ---\r\n"))
        #expect(!session.perform(.tableDeleteColumn, in: NSRange(location: 1, length: 0)))
        session.canEdit = false
        #expect(!session.perform(.tableInsertRow, in: NSRange(location: 1, length: 0)))
        let plain = DocumentSession(source: "not | a table\n")
        #expect(!plain.perform(.tableInsertColumn))
    }

    @Test func checkboxOnlyPatchesTaskMarker() {
        let source = "- [ ] **task**\n  - [X] nested\n\nplain [ ]\n\n```\n- [ ] code\n```\n"
        let session = DocumentSession(source: source)
        let marker = (source as NSString).range(of: "[ ]")
        #expect(session.toggleTaskCheckbox(atSourceOffset: marker.location))
        #expect(session.source == (source as NSString).replacingCharacters(in: marker, with: "[x]"))
        #expect(!session.toggleTaskCheckbox(atSourceOffset: (session.source as NSString).range(of: "task").location))
        #expect(!session.toggleTaskCheckbox(atSourceOffset: (session.source as NSString).range(of: "plain [ ]").location + 6))
        #expect(!session.toggleTaskCheckbox(atSourceOffset: (session.source as NSString).range(of: "[ ] code").location))
        session.undoManager.undo()
        #expect(session.source == source)
        let nested = (source as NSString).range(of: "[X]")
        #expect(session.toggleTaskCheckbox(atSourceOffset: nested.location + 1))
        #expect(session.source.contains("- [ ] nested"))
        session.canEdit = false
        let before = session.source
        #expect(!session.toggleTaskCheckbox(atSourceOffset: marker.location))
        #expect(session.source == before)
    }
}

@MainActor private final class ViewportChangeRecorder: NSObject {
    var origins: [NSPoint] = []

    @objc func changed(_ notification: Notification) {
        if let clip = notification.object as? NSClipView { origins.append(clip.bounds.origin) }
    }
}

@MainActor private final class StorageEditRecorder: NSObject, @preconcurrency NSTextStorageDelegate {
    var characterEdits = 0
    var editedRanges: [NSRange] = []

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) {
            characterEdits += 1
            editedRanges.append(editedRange)
        }
    }
}