import AppKit
import Testing
import MarkdownEngine
import EditorKit

@Suite(.serialized) @MainActor struct EngineTests {
    @Test func sourceOffsetsPreferContainingSegmentsOverEarlierUnmappedNodes() {
        let map = SourceMap(segments: [
            MappingSegment(displayedNSRange: NSRange(location: 0, length: 3), sourceNSRange: NSRange(location: 0, length: 3), kind: .text, isIdentity: true),
            MappingSegment(displayedNSRange: NSRange(location: 3, length: 1), sourceNSRange: NSRange(location: 40, length: 0), kind: .attachment, isIdentity: false),
            MappingSegment(displayedNSRange: NSRange(location: 4, length: 10), sourceNSRange: NSRange(location: 4, length: 10), kind: .text, isIdentity: true)
        ], sourceLength: 40, displayedLength: 14)
        #expect(map.displayedOffset(forSourceOffset: 6) == 6)
        #expect(map.displayedOffset(forSourceOffset: 3) == 4)
        #expect(map.displayedOffset(forSourceOffset: 40) == 14)
        #expect(map.sourceOffset(forDisplayedOffset: map.displayedOffset(forSourceOffset: 6)) == 6)
    }

    @Test func returnBeforeThirdSpacedChineseWordKeepsCaretVisible() async throws {
        let line = "点多到      点多到      点多到      点多到       "
        let table = "| | | |\n| --- | --- | --- |\n| | | |\n| | | |\n| | | |\n\n"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try String(contentsOf: root.appendingPathComponent("TestDoc/测试文档/测试文档.md"), encoding: .utf8)
        let sources = [line + "\n\n" + table, table + line + "\n\n" + table,
                       String(repeating: "## Heading\n\nParagraph text.\n\n", count: 40) + table + line + "\n\n" + table, fixture]
        for source in sources {
            let session = DocumentSession(source: source)
            session.undoManager.groupsByEvent = false
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            let image = NSImage(size: NSSize(width: 720, height: 500))
            controller.imageProvider = { _ in image }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentViewController = nil }
            controller.view.layoutSubtreeIfNeeded()
            let editor = controller.textView!
            window.makeFirstResponder(editor)
            let layout = try #require(editor.layoutManager)
            let container = try #require(editor.textContainer)
            let lineRange = (source as NSString).range(of: line)
            #expect(lineRange.location != NSNotFound)
            let sourceCaret = lineRange.location + "点多到      点多到      ".utf16.count
            let selection = session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: NSRange(location: sourceCaret, length: 0))
            editor.setSelectedRange(selection)
            #expect(controller.selectedSourceRange() == NSRange(location: sourceCaret, length: 0))
            layout.ensureLayout(for: container)
            editor.sizeToFit()
            editor.scrollRangeToVisible(selection)
            session.undoManager.beginUndoGrouping()
            editor.insertNewline(nil)
            session.undoManager.endUndoGrouping()
            let expected = (source as NSString).replacingCharacters(in: NSRange(location: sourceCaret, length: 0), with: "\n")
            if session.source != expected {
                Issue.record("Return source mismatch: insertion=\(sourceCaret), selected=\(session.selectedSourceRange), display=\(selection)")
            }
            for wait in [false, true] {
                if wait { await session.waitForRendering() }
                layout.ensureLayout(for: container)
                editor.sizeToFit()
                let displayed = editor.string as NSString
                let start = displayed.range(of: "点多到      点多到").location
                let expectedCaret = displayed.range(of: "\n", range: NSRange(location: start, length: displayed.length - start)).location + 1
                #expect(editor.selectedRange() == NSRange(location: expectedCaret, length: 0))
                #expect(window.firstResponder === editor)
                let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
                #expect(caret.height > 0 && caret.minX.isFinite && caret.minY.isFinite)
                let local = editor.convert(window.convertFromScreen(caret), from: nil)
                #expect(editor.visibleRect.intersects(local.insetBy(dx: -1, dy: 0)))
            }
            session.undoManager.beginUndoGrouping()
            editor.insertText("X", replacementRange: editor.selectedRange())
            session.undoManager.endUndoGrouping()
            if session.source != (expected as NSString).replacingCharacters(in: NSRange(location: sourceCaret + 1, length: 0), with: "X") {
                Issue.record("Typing after Return did not insert at source \(sourceCaret + 1)")
            }
            session.undoManager.undo()
            if session.source != expected { Issue.record("Undo typing did not restore expected Return source") }
            session.undoManager.undo()
            #expect(session.source == source)
        }
    }

    @Test func typingReparseDoesNotReplaceUnchangedDisplayedCharacters() async throws {
        @MainActor final class Edits {
            var ranges: [NSRange] = []
            let storage: NSTextStorage
            init(storage: NSTextStorage) { self.storage = storage }
        }
        _ = NSApplication.shared
        let session = DocumentSession(source: String(repeating: "## Heading\n\nParagraph **bold** text.\n\n***\n\n", count: 40))
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let editor = controller.textView!
        window.makeFirstResponder(editor)
        defer { window.orderOut(nil); window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let clip = try #require(editor.enclosingScrollView?.contentView)
        let storage = try #require(editor.textStorage)
        layout.ensureLayout(for: container)
        editor.sizeToFit()
        let caret = (editor.string as NSString).range(of: "Paragraph", options: [], range: NSRange(location: storage.length / 2, length: storage.length - storage.length / 2)).location + 4
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        let origin = clip.bounds.origin
        let edits = Edits(storage: storage)
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in
            MainActor.assumeIsolated {
            let storage = edits.storage
                if storage.editedMask.contains(.editedCharacters) { edits.ranges.append(storage.editedRange) }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        for character in ["x", "中", "y"] {
            edits.ranges.removeAll()
            let insertion = editor.selectedRange().location
            editor.insertText(character, replacementRange: editor.selectedRange())
            layout.ensureLayout(for: container)
            editor.sizeToFit()
            #expect(abs(clip.bounds.minY - origin.y) < 1)
            await session.waitForRendering()
            layout.ensureLayout(for: container)
            editor.sizeToFit()
            #expect(edits.ranges == [NSRange(location: insertion, length: character.utf16.count)])
            #expect(abs(clip.bounds.minY - origin.y) < 1)
            #expect(editor.selectedRange() == NSRange(location: insertion + character.utf16.count, length: 0))
        }
    }

    @Test func horizontalRuleCaretHasDistinctSidesAndKeyboardEntry() throws {
        _ = NSApplication.shared
        let session = DocumentSession(source: "Before\n\n***\n\nAfter")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let editor = controller.textView!
        window.makeFirstResponder(editor)
        defer { window.orderOut(nil); window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        let layout = try #require(editor.layoutManager as? TableLayoutManager)
        layout.ensureLayout(for: editor.textContainer!)
        let rule = (editor.string as NSString).range(of: "\u{FFFC}").location
        let before = editor.firstRect(forCharacterRange: NSRange(location: rule, length: 0), actualRange: nil)
        let after = editor.firstRect(forCharacterRange: NSRange(location: rule + 1, length: 0), actualRange: nil)
        #expect(after.minX - before.minX > 300)
        editor.setSelectedRange(NSRange(location: rule - 1, length: 0))
        editor.moveDown(nil)
        #expect(editor.selectedRange() == NSRange(location: rule, length: 0))
        editor.setSelectedRange(NSRange(location: rule + 2, length: 0))
        editor.moveUp(nil)
        #expect(editor.selectedRange() == NSRange(location: rule, length: 0))
        editor.deleteBackward(nil)
        #expect(session.source == "Before\n***\n\nAfter")
        session.undoManager.undo()
        editor.setSelectedRange(NSRange(location: rule, length: 0))
        let originalRect = try #require(layout.horizontalRuleRect(at: rule))
        editor.insertNewline(nil)
        layout.ensureLayout(for: editor.textContainer!)
        #expect(session.source == "Before\n\n\n***\n\nAfter")
        let movedRect = try #require(layout.horizontalRuleRect(at: rule + 1))
        #expect(movedRect.minY > originalRect.minY + 10)
        session.undoManager.undo()
        editor.setSelectedRange(NSRange(location: rule + 2, length: 0))
        editor.deleteBackward(nil)
        layout.ensureLayout(for: editor.textContainer!)
        #expect(session.source == "Before\n\n***\nAfter")
        #expect(editor.selectedRange() == NSRange(location: rule + 1, length: 0))
        let deletedBlankCaret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        #expect(deletedBlankCaret.minX - before.minX > 300)
    }

    @Test func thematicBreaksPreserveBlankLinesBetweenRules() {
        for newline in ["\n", "\r\n", "\r"] {
            for count in 1...5 {
                let source = "------" + String(repeating: newline, count: count) + "---"
                let snapshot = MarkdownRenderer.snapshot(source: source)
                #expect(snapshot.text == "\u{FFFC}" + String(repeating: "\n", count: count) + "\u{FFFC}")
                #expect(snapshot.source == source)
                let breaks = snapshot.sourceMap.segments.filter { $0.kind == .lineBreak }
                #expect(breaks.count == count)
                #expect(breaks.allSatisfy { (source as NSString).substring(with: $0.sourceNSRange) == newline })
                let storage = NSTextStorage(attributedString: MarkdownRenderer.render(snapshot: snapshot).attributedString)
                let layout = NSLayoutManager()
                let container = NSTextContainer(size: NSSize(width: 520, height: 10_000))
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
                layout.ensureLayout(for: container)
                var lineCount = 0
                layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in
                    lineCount += 1
                }
                #expect(lineCount == count + 1)
            }
        }
        let source = "------\n\n\n\n---"
        let session = DocumentSession(source: source)
        session.undoManager.groupsByEvent = false
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        session.undoManager.beginUndoGrouping()
        controller.textView.insertText("中", replacementRange: controller.textView.selectedRange())
        session.undoManager.endUndoGrouping()
        session.renderNow()
        #expect(session.source == "------\n中\n\n\n---")
        session.undoManager.beginUndoGrouping()
        controller.textView.deleteBackward(nil)
        session.undoManager.endUndoGrouping()
        session.renderNow()
        #expect(session.source == source)
        session.undoManager.undo()
        session.renderNow()
        #expect(session.source == "------\n中\n\n\n---")
        session.undoManager.undo()
        session.renderNow()
        #expect(session.source == source)
    }

    @Test func horizontalRuleUndoKeepsViewportStable() async throws {
        _ = NSApplication.shared
        let source = String(repeating: "## Heading\n\nParagraph **bold** text.\n\n", count: 60) + "---\n\nAfter rule\n\n" + String(repeating: "Following paragraph.\n\n", count: 60)
        let session = DocumentSession(source: source)
        session.undoManager.groupsByEvent = false
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        let layout = try #require(editor.layoutManager as? TableLayoutManager)
        let container = try #require(editor.textContainer)
        let clip = try #require(editor.enclosingScrollView?.contentView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        defer { window.orderOut(nil) }
        layout.ensureLayout(for: container)
        editor.sizeToFit()
        let character = (editor.string as NSString).range(of: "\u{FFFC}").location
        let rule = try #require(layout.horizontalRuleRect(at: character))
        editor.setSelectedRange(NSRange(location: character + 1, length: 0))
        editor.scroll(NSPoint(x: 0, y: rule.minY + editor.textContainerOrigin.y - 120))
        let before = clip.bounds.origin
        #expect(before.y > 1000)
        session.undoManager.beginUndoGrouping()
        editor.deleteBackward(nil)
        session.undoManager.endUndoGrouping()
        session.renderNow()
        layout.ensureLayout(for: container)
        editor.sizeToFit()
        let deletedSource = session.source
        session.undoManager.undo()
        layout.ensureLayout(for: container)
        editor.sizeToFit()
        #expect(abs(clip.bounds.minY - before.y) < 1)
        await session.waitForRendering()
        layout.ensureLayout(for: container)
        editor.sizeToFit()
        #expect(session.source == source)
        #expect(editor.selectedRange() == NSRange(location: character + 1, length: 0))
        #expect(abs(clip.bounds.minY - before.y) < 1)
        session.undoManager.redo()
        layout.ensureLayout(for: container)
        editor.sizeToFit()
        #expect(abs(clip.bounds.minY - before.y) < 1)
        await session.waitForRendering()
        layout.ensureLayout(for: container)
        editor.sizeToFit()
        #expect(session.source == deletedSource)
        #expect(abs(clip.bounds.minY - before.y) < 1)
        window.contentViewController = nil
    }

    @Test func horizontalRulesDrawAcrossEditorAndResize() throws {
        _ = NSApplication.shared
        let source = "## Heading\n\nBefore\n\n---\n\nAfter\n\n> ## Quoted heading\n>\n> ---\n>\n> Quoted body"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        let editor = controller.textView!
        let layout = try #require(editor.layoutManager as? TableLayoutManager)
        let container = try #require(editor.textContainer)
        let character = (editor.string as NSString).range(of: "\u{FFFC}").location
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            editor.appearance = NSAppearance(named: appearance)
            for width in [520, 280] {
                window.setContentSize(NSSize(width: width, height: 400))
                controller.view.layoutSubtreeIfNeeded()
                layout.ensureLayout(for: container)
                let rect = try #require(layout.horizontalRuleRect(at: character))
                #expect(abs(rect.width - (container.size.width - 2 * container.lineFragmentPadding)) < 1)
                let heading = try #require(layout.headingSeparatorRect(at: 0))
                #expect(heading.height == 1)
                #expect(rect.height == 2)
                let before = (editor.string as NSString).range(of: "Before").location
                let after = (editor.string as NSString).range(of: "After").location
                let beforeLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: before), effectiveRange: nil)
                let afterLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: after), effectiveRange: nil)
                #expect(rect.minY - beforeLine.maxY >= 12)
                #expect(afterLine.minY - rect.maxY >= 12)
                let quotedCharacter = (editor.string as NSString).range(of: "\u{FFFC}", options: .backwards).location
                let quoted = try #require(layout.horizontalRuleRect(at: quotedCharacter))
                let quotedHeading = try #require(layout.headingSeparatorRect(at: (editor.string as NSString).range(of: "Quoted heading").location))
                #expect(quoted.height == 2)
                #expect(quoted.minX > rect.minX)
                #expect(abs(quoted.minX - quotedHeading.minX) < 1)
                #expect(abs(quoted.maxX - quotedHeading.maxX) < 1)
                #expect(quoted.maxX <= rect.maxX + 1)
                let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                let scaleX = CGFloat(bitmap.pixelsWide) / editor.bounds.width
                let scaleY = CGFloat(bitmap.pixelsHigh) / editor.bounds.height
                var background: NSColor!
                editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                    background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)
                }
                for fraction in [CGFloat(0.1), 0.5, 0.9] {
                    let horizontal = Int((rect.minX + rect.width * fraction + editor.textContainerOrigin.x) * scaleX)
                    let vertical = Int((rect.midY + editor.textContainerOrigin.y) * scaleY)
                    let color = try #require(bitmap.colorAt(x: horizontal, y: vertical)?.usingColorSpace(.deviceRGB))
                    #expect(max(abs(color.redComponent - background.redComponent), abs(color.greenComponent - background.greenComponent), abs(color.blueComponent - background.blueComponent)) > 0.02)
                    let headingColor = try #require(bitmap.colorAt(x: Int((heading.minX + heading.width * fraction + editor.textContainerOrigin.x) * scaleX),
                                                                  y: Int((heading.midY + editor.textContainerOrigin.y) * scaleY))?.usingColorSpace(.deviceRGB))
                    #expect(max(abs(color.redComponent - headingColor.redComponent), abs(color.greenComponent - headingColor.greenComponent), abs(color.blueComponent - headingColor.blueComponent)) > 0.02)
                    for inset in [CGFloat(0.5), 1.5] {
                        let edge = try #require(bitmap.colorAt(x: horizontal, y: Int((rect.minY + inset + editor.textContainerOrigin.y) * scaleY))?.usingColorSpace(.deviceRGB))
                        #expect(abs(edge.redComponent - color.redComponent) < 0.02)
                    }
                }
                #expect(session.source == source)
                #expect(editor.string == MarkdownRenderer.snapshot(source: source).text)
            }
        }
        window.contentViewController = nil
    }

    @Test func headingSeparatorsDrawBelowLastLineWithoutChangingSource() throws {
        _ = NSApplication.shared
        for heading in ["# Heading *emphasis* `code`", "## Heading *emphasis* `code`", "Setext heading\n===", "Setext heading\n---",
                        "## " + String(repeating: "Long heading ", count: 10), "> ## Quoted heading"] {
            let source = heading + "\n\nBody\n\n### Smaller heading\n\n```\n# Code heading\n```"
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            let editor = controller.textView!
            let layout = try #require(editor.layoutManager as? TableLayoutManager)
            let container = try #require(editor.textContainer)
            let snapshot = MarkdownRenderer.snapshot(source: source)
            let range = try #require(snapshot.headings.first?.displayedRange)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                editor.appearance = NSAppearance(named: appearance)
                for width in [520, 280] {
                    window.setContentSize(NSSize(width: width, height: 700))
                    controller.view.layoutSubtreeIfNeeded()
                    layout.ensureLayout(for: container)
                    let rect = try #require(layout.headingSeparatorRect(at: range.location))
                    #expect(layout.headingSeparatorRect(at: NSMaxRange(range) - 1) == rect)
                    let last = layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
                    let line = layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
                    #expect(abs(rect.width - (line.width - 2 * container.lineFragmentPadding)) < 1)
                    #expect(rect.minY > line.minY + layout.location(forGlyphAt: last).y)
                    let body = (editor.string as NSString).range(of: "Body").location
                    let bodyLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: body), effectiveRange: nil)
                    #expect(rect.maxY < bodyLine.minY)
                    for word in ["Body", "Smaller heading", "# Code heading"] {
                        #expect(layout.headingSeparatorRect(at: (editor.string as NSString).range(of: word).location) == nil)
                    }
                    let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
                    editor.cacheDisplay(in: editor.bounds, to: bitmap)
                    let scaleX = CGFloat(bitmap.pixelsWide) / editor.bounds.width
                    let scaleY = CGFloat(bitmap.pixelsHigh) / editor.bounds.height
                    var background: NSColor!
                    editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                        background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)
                    }
                    for fraction in [CGFloat(0.1), 0.5, 0.9] {
                        let horizontal = Int((rect.minX + rect.width * fraction + editor.textContainerOrigin.x) * scaleX)
                        let vertical = Int((rect.midY + editor.textContainerOrigin.y) * scaleY)
                        let color = try #require(bitmap.colorAt(x: horizontal, y: vertical)?.usingColorSpace(.deviceRGB))
                        #expect(max(abs(color.redComponent - background.redComponent), abs(color.greenComponent - background.greenComponent), abs(color.blueComponent - background.blueComponent)) > 0.02)
                    }
                    #expect(session.source == source)
                    #expect(editor.string == snapshot.text)
                }
            }
            window.contentViewController = nil
        }
    }

    @Test func setextHeadingKeepsFollowingHeadingOnSeparateLine() throws {
        for newline in ["\n", "\r\n", "\r"] {
            for marker in ["---", "==="] {
                                for blankLines in [0, 1, 3] {
                                        let source = (["哈哈", marker] + Array(repeating: "", count: blankLines) + ["## Kivo 深度测评", "Body"]).joined(separator: newline)
                                        let snapshot = MarkdownRenderer.snapshot(source: source)
                                        #expect(snapshot.text == "哈哈" + String(repeating: "\n", count: blankLines + 1) + "Kivo 深度测评\nBody")
                                        #expect(snapshot.headings.map(\.title) == ["哈哈", "Kivo 深度测评"])
                                        let headingRange = try #require(snapshot.headings.first?.sourceRange)
                                        #expect((source as NSString).substring(with: headingRange) == "哈哈" + newline + marker)
                                        let breaks = snapshot.sourceMap.segments.filter { $0.kind == .lineBreak }
                                        #expect(breaks.count == blankLines + 2)
                                        #expect(breaks.allSatisfy { (source as NSString).substring(with: $0.sourceNSRange) == newline })
                                        let storage = NSTextStorage(attributedString: MarkdownRenderer.render(snapshot: snapshot).attributedString)
                                        let layout = TableLayoutManager()
                                        let container = NSTextContainer(size: NSSize(width: 520, height: 10_000))
                                        layout.addTextContainer(container)
                                        storage.addLayoutManager(layout)
                                        layout.ensureLayout(for: container)
                                        let first = try #require(snapshot.headings.first)
                                        let second = try #require(snapshot.headings.last)
                                        let firstLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: first.displayedRange.location), effectiveRange: nil)
                                        let secondLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: second.displayedRange.location), effectiveRange: nil)
                                        #expect(secondLine.minY >= firstLine.maxY)
                                        #expect(snapshot.source == source)
                                }
            }
        }
        let source = "哈哈\n---\n## Kivo **深度测评**\nBody"
        let session = DocumentSession(source: source)
        session.undoManager.groupsByEvent = false
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let editor = controller.textView!
        let target = (editor.string as NSString).range(of: "Kivo")
        editor.setSelectedRange(NSRange(location: target.location, length: 0))
        session.undoManager.beginUndoGrouping()
        editor.insertText("新", replacementRange: editor.selectedRange())
        session.undoManager.endUndoGrouping()
        session.renderNow()
        #expect(session.source == "哈哈\n---\n## 新Kivo **深度测评**\nBody")
        #expect(editor.string == "哈哈\n新Kivo 深度测评\nBody")
        session.undoManager.undo()
        session.renderNow()
        #expect(session.source == source)
        #expect(editor.string == "哈哈\nKivo 深度测评\nBody")
    }

    @Test func headingSeparatorsFollowEditsUndoAndEditorMode() throws {
        let source = "# Heading *emphasis*\n\nBody"
        let session = DocumentSession(source: source)
        session.undoManager.groupsByEvent = false
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let editor = controller.textView!
        let storage = try #require(editor.textStorage)
        func hasSeparator() -> Bool {
            storage.attribute(.markdownHeadingSeparator, at: 0, effectiveRange: nil) != nil
        }
        #expect(hasSeparator())
        let word = (editor.string as NSString).range(of: "Heading")
        editor.setSelectedRange(NSRange(location: NSMaxRange(word), length: 0))
        session.undoManager.beginUndoGrouping()
        editor.insertText("x", replacementRange: editor.selectedRange())
        session.undoManager.endUndoGrouping()
        session.renderNow()
        #expect(session.source == "# Headingx *emphasis*\n\nBody")
        #expect(hasSeparator())
        session.undoManager.undo()
        session.renderNow()
        #expect(session.source == source)
        session.undoManager.beginUndoGrouping()
        #expect(controller.perform(.heading(level: 3)))
        session.undoManager.endUndoGrouping()
        #expect(session.source == "### Heading *emphasis*\n\nBody")
        #expect(!hasSeparator())
        session.undoManager.undo()
        session.renderNow()
        #expect(session.source == source)
        #expect(hasSeparator())
        controller.mode = .source
        #expect(editor.string == source)
        #expect(!hasSeparator())
        controller.mode = .richText
        #expect(hasSeparator())
        #expect(session.source == source)
    }

    @Test func clickingHorizontalRuleSelectsAndDeletesWholeObject() async throws {
        _ = NSApplication.shared
        let source = "Before\n\n---\nAfter"
        let session = DocumentSession(source: source)
        session.undoManager.groupsByEvent = false
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        window.makeFirstResponder(editor)
        let layout = try #require(editor.layoutManager as? TableLayoutManager)
        layout.ensureLayout(for: editor.textContainer!)
        func sampledColor(in rect: NSRect) throws -> NSColor {
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            let horizontal = Int((rect.midX + editor.textContainerOrigin.x) * CGFloat(bitmap.pixelsWide) / editor.bounds.width)
            let vertical = Int((rect.midY + editor.textContainerOrigin.y) * CGFloat(bitmap.pixelsHigh) / editor.bounds.height)
            return try #require(bitmap.colorAt(x: horizontal, y: vertical)?.usingColorSpace(.deviceRGB))
        }
        let character = (editor.string as NSString).range(of: "\u{FFFC}").location
        for clickCount in [1, 2] {
            for fraction in [CGFloat(0.1), 0.5, 0.9] {
                let rect = try #require(layout.horizontalRuleRect(at: character))
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                let unselected = try sampledColor(in: rect)
                let borderRect = rect.offsetBy(dx: 0, dy: -6)
                let unselectedBorder = try sampledColor(in: borderRect)
                let interiorRect = rect.offsetBy(dx: 0, dy: -3)
                let unselectedInterior = try sampledColor(in: interiorRect)
                let point = editor.convert(NSPoint(x: rect.minX + rect.width * fraction + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y), to: nil)
                let hover = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                NSCursor.iBeam.set()
                editor.mouseMoved(with: hover)
                #expect(NSCursor.current == NSCursor.pointingHand)
                NSCursor.iBeam.set()
                editor.cursorUpdate(with: hover)
                #expect(NSCursor.current == NSCursor.pointingHand)
                let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1))
                let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: clickCount, pressure: 0))
                editor.mouseDown(with: down)
                editor.mouseUp(with: up)
                #expect(editor.selectedRange() == NSRange(location: character, length: 1))
                let selected = try sampledColor(in: rect)
                #expect(max(abs(selected.redComponent - unselected.redComponent), abs(selected.greenComponent - unselected.greenComponent), abs(selected.blueComponent - unselected.blueComponent)) < 0.02)
                let selectedBorder = try sampledColor(in: borderRect)
                #expect(max(abs(selectedBorder.redComponent - unselectedBorder.redComponent), abs(selectedBorder.greenComponent - unselectedBorder.greenComponent), abs(selectedBorder.blueComponent - unselectedBorder.blueComponent)) > 0.02)
                let selectedInterior = try sampledColor(in: interiorRect)
                #expect(max(abs(selectedInterior.redComponent - unselectedInterior.redComponent), abs(selectedInterior.greenComponent - unselectedInterior.greenComponent), abs(selectedInterior.blueComponent - unselectedInterior.blueComponent)) < 0.02)
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                let cleared = try sampledColor(in: rect)
                #expect(max(abs(cleared.redComponent - unselected.redComponent), abs(cleared.greenComponent - unselected.greenComponent), abs(cleared.blueComponent - unselected.blueComponent)) < 0.02)
                let clearedBorder = try sampledColor(in: borderRect)
                #expect(max(abs(clearedBorder.redComponent - unselectedBorder.redComponent), abs(clearedBorder.greenComponent - unselectedBorder.greenComponent), abs(clearedBorder.blueComponent - unselectedBorder.blueComponent)) < 0.02)
                editor.mouseDown(with: down)
                editor.mouseUp(with: up)
                session.undoManager.beginUndoGrouping()
                editor.deleteBackward(nil)
                session.undoManager.endUndoGrouping()
                #expect(session.source == "Before\n\n\nAfter")
                #expect(editor.string == "Before\n\n\nAfter")
                session.undoManager.undo()
                #expect(session.source == source)
                #expect(editor.selectedRange() == NSRange(location: character, length: 1))
                session.undoManager.redo()
                #expect(session.source == "Before\n\n\nAfter")
                session.undoManager.undo()
                #expect(session.source == source)
            }
        }
        window.contentViewController = nil
    }

    @Test func horizontalRuleCursorRectsHandleClippingAndReadOnly() throws {
        _ = NSApplication.shared
        let source = String(repeating: "Before\n\n***\n\nAfter\n\n", count: 80)
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        defer { window.contentViewController = nil }
        let layout = try #require(editor.layoutManager as? TableLayoutManager)
        layout.ensureLayout(for: editor.textContainer!)
        editor.sizeToFit()
        let rule = (editor.string as NSString).range(of: "\u{FFFC}").location
        let rect = try #require(layout.horizontalRuleRect(at: rule))
        for offset in [CGFloat(0), rect.minY + editor.textContainerOrigin.y + 1, rect.maxY + editor.textContainerOrigin.y + 5, CGFloat(1000)] {
            editor.scroll(NSPoint(x: 0, y: offset))
            editor.resetCursorRects()
        }
        editor.scroll(.zero)
        controller.canEdit = false
        editor.resetCursorRects()
        let point = editor.convert(NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y), to: nil)
        let hover = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        NSCursor.iBeam.set()
        editor.cursorUpdate(with: hover)
        #expect(NSCursor.current == NSCursor.pointingHand)
        controller.mode = .source
        editor.resetCursorRects()
        NSCursor.iBeam.set()
        editor.mouseMoved(with: hover)
        #expect(NSCursor.current != NSCursor.pointingHand)
        #expect(session.source == source)
    }

    @Test func backspaceBeforeHorizontalRuleDeletesBlankLineAndKeepsRule() {
        for newline in ["\n", "\r\n", "\r"] {
            for marker in ["---", "***", "___", "- - -"] {
                let source = "Before" + newline + newline + marker + newline + "After"
                let kept = marker == "---" ? "***" : marker
                let session = DocumentSession(source: source)
                session.undoManager.groupsByEvent = false
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                let editor = controller.textView!
                let rule = (editor.string as NSString).range(of: "\u{FFFC}").location
                editor.setSelectedRange(NSRange(location: rule, length: 0))
                session.undoManager.beginUndoGrouping()
                editor.deleteBackward(nil)
                session.undoManager.endUndoGrouping()
                session.renderNow()
                #expect(session.source == "Before" + newline + kept + newline + "After")
                #expect(editor.string == "Before\n\u{FFFC}\nAfter")
                #expect(editor.selectedRange() == NSRange(location: rule - 1, length: 0))
                editor.deleteBackward(nil)
                #expect(session.source == "Before" + newline + kept + newline + "After")
                #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
                session.undoManager.undo()
                #expect(session.source == source)
                session.undoManager.redo()
                #expect(session.source == "Before" + newline + kept + newline + "After")
            }
        }
    }

    @Test func backspaceOnBlankLineBeforeRuleMergesUpward() {
        for newline in ["\n", "\r\n", "\r"] {
            for fromBlankLine in [false, true] {
                let source = ["---", "", "哈哈", "", "---", "## Kivo 深度测评"].joined(separator: newline)
                let expected = ["---", "", "哈哈", "***", "## Kivo 深度测评"].joined(separator: newline)
                let session = DocumentSession(source: source)
                session.undoManager.groupsByEvent = false
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                let editor = controller.textView!
                let rule = (editor.string as NSString).range(of: "\u{FFFC}", options: .backwards).location
                let caret = rule - (fromBlankLine ? 1 : 0)
                editor.setSelectedRange(NSRange(location: caret, length: 0))
                session.undoManager.beginUndoGrouping()
                editor.deleteBackward(nil)
                session.undoManager.endUndoGrouping()
                session.renderNow()
                #expect(session.source == expected)
                #expect(editor.string == "\u{FFFC}\n\n哈哈\n\u{FFFC}\nKivo 深度测评")
                #expect(editor.selectedRange() == NSRange(location: caret - 1, length: 0))
                session.undoManager.undo()
                #expect(session.source == source)
                #expect(editor.selectedRange() == NSRange(location: caret, length: 0))
            }
        }
    }

    @Test func horizontalRuleDeletionIsDirectionalAndAtomic() {
        for newline in ["\n", "\r\n", "\r"] {
            for marker in ["---", "***", "___", "- - -"] {
                for action in 0...3 {
                    let source = "Before" + newline + newline + marker + newline + "After"
                    let expected = "Before" + newline + newline + newline + "After"
                    let session = DocumentSession(source: source)
                    session.undoManager.groupsByEvent = false
                    session.renderNow()
                    let controller = MarkdownEditorController(session: session)
                    _ = controller.view
                    let editor = controller.textView!
                    let character = (editor.string as NSString).range(of: "\u{FFFC}").location
                    let selection = action == 0 ? NSRange(location: character + 1, length: 0)
                        : action == 1 ? NSRange(location: character, length: 0)
                        : action == 2 ? NSRange(location: character, length: 1)
                        : NSRange(location: character + 2, length: 0)
                    editor.setSelectedRange(selection)
                    if action == 3 {
                        editor.deleteBackward(nil)
                        #expect(session.source == source)
                        #expect(editor.selectedRange() == NSRange(location: character, length: 1))
                    }
                    let deleting = editor.selectedRange()
                    session.undoManager.beginUndoGrouping()
                    if action == 1 { editor.deleteForward(nil) }
                    else { editor.deleteBackward(nil) }
                    session.undoManager.endUndoGrouping()
                    #expect(session.source == expected)
                    #expect(editor.string == "Before\n\n\nAfter")
                    session.renderNow()
                    #expect(editor.string == "Before\n\n\nAfter")
                    session.undoManager.undo()
                    #expect(session.source == source)
                    #expect(editor.selectedRange() == deleting)
                    session.undoManager.redo()
                    #expect(session.source == expected)
                }
            }
        }
    }

    @Test func backspaceOnBlankLineBelowRuleRemovesOnlyTheBlankLine() {
        for newline in ["\n", "\r\n", "\r"] {
            for marker in ["***", "---", "___"] {
                for after in ["After", ""] {
                    let source = "Before" + newline + newline + marker + newline + newline + after
                    let session = DocumentSession(source: source)
                    session.undoManager.groupsByEvent = false
                    session.renderNow()
                    let controller = MarkdownEditorController(session: session)
                    _ = controller.view
                    let editor = controller.textView!
                    let rule = (editor.string as NSString).range(of: "\u{FFFC}").location
                    editor.setSelectedRange(NSRange(location: rule + 2, length: 0))
                    session.undoManager.beginUndoGrouping()
                    editor.deleteBackward(nil)
                    session.undoManager.endUndoGrouping()
                    session.renderNow()
                    #expect(session.source == "Before" + newline + newline + marker + newline + after)
                    #expect(editor.string == MarkdownRenderer.snapshot(source: session.source).text)
                    #expect(editor.string.hasPrefix("Before\n\n\u{FFFC}") && editor.string.hasSuffix(after))
                    #expect(editor.string.filter { $0.isNewline }.count == 3)
                    #expect(editor.selectedRange() == NSRange(location: rule + 1, length: 0))
                    session.undoManager.undo()
                    #expect(session.source == source)
                }
            }
        }
    }

    @Test func returnBeforeRuleInsertsBlankLineAboveIt() {
        for newline in ["\n", "\r\n", "\r"] {
            for (prefix, marker) in [("", "***"), ("", "---"), ("", "___"), ("> ", "***")] {
                let source = prefix + "Before" + newline + prefix + newline + prefix + marker + newline + prefix + "After"
                let expected = prefix + "Before" + newline + prefix + newline + prefix + newline + prefix + marker + newline + prefix + "After"
                let session = DocumentSession(source: source)
                session.undoManager.groupsByEvent = false
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                let editor = controller.textView!
                let rule = (editor.string as NSString).range(of: "\u{FFFC}").location
                editor.setSelectedRange(NSRange(location: rule, length: 0))
                for count in 1...2 {
                    session.undoManager.beginUndoGrouping()
                    editor.insertNewline(nil)
                    session.undoManager.endUndoGrouping()
                    #expect(editor.selectedRange() == NSRange(location: rule + count, length: 0))
                    #expect((editor.string as NSString).character(at: rule + count) == 0xFFFC)
                }
                session.undoManager.undo()
                #expect(session.source == expected)
                #expect(editor.selectedRange() == NSRange(location: rule + 1, length: 0))
                session.undoManager.undo()
                #expect(session.source == source)
            }
        }
    }

    @Test func horizontalRuleDeletionPreservesOtherEditingModes() {
        for forward in [false, true] {
            let source = "Before\n\n---\nAfter"
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            controller.mode = .source
            let editor = controller.textView!
            let marker = (source as NSString).range(of: "---")
            editor.setSelectedRange(NSRange(location: forward ? marker.location : NSMaxRange(marker), length: 0))
            if forward { editor.deleteForward(nil) }
            else { editor.deleteBackward(nil) }
            #expect(session.source == "Before\n\n--\nAfter")
            session.undoManager.undo()
            #expect(session.source == source)
        }
        let source = "Before\n\n\n---\nAfter"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let editor = controller.textView!
        let character = (editor.string as NSString).range(of: "\u{FFFC}").location
        editor.setSelectedRange(NSRange(location: character, length: 0))
        editor.deleteBackward(nil)
        session.renderNow()
        #expect(session.source == "Before\n\n---\nAfter")
        #expect(editor.string.contains("\u{FFFC}"))
        let unchanged = session.source
        let rule = (editor.string as NSString).range(of: "\u{FFFC}").location
        controller.canEdit = false
        editor.setSelectedRange(NSRange(location: rule + 2, length: 0))
        editor.deleteBackward(nil)
        editor.setSelectedRange(NSRange(location: rule, length: 0))
        editor.deleteForward(nil)
        #expect(session.source == unchanged)
    }

    @Test func thematicBreaksRenderFullWidthAndRemainEditable() throws {
        for marker in ["---", "***", "___", "- - -"] {
            let source = "Before\n\n" + marker + "\n\nAfter"
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let editor = controller.textView!
            editor.setFrameSize(NSSize(width: 520, height: 400))
            let layout = try #require(editor.layoutManager as? TableLayoutManager)
            let container = try #require(editor.textContainer)
            layout.ensureLayout(for: container)
            let character = (editor.string as NSString).range(of: "\u{FFFC}").location
            #expect(character != NSNotFound)
            let rect = try #require(layout.horizontalRuleRect(at: character))
            #expect(abs(rect.width - (container.size.width - 2 * container.lineFragmentPadding)) < 1)
            #expect(rect.height == 2)
            #expect(session.source == source)
            editor.setSelectedRange(NSRange(location: character + 1, length: 0))
            editor.deleteBackward(nil)
            session.renderNow()
            #expect(session.source == "Before\n\n\n\nAfter")
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
        }
        for source in ["Title\n---", "```\n---\n```", "inline --- text"] {
            let rendered = MarkdownRenderer.render(source: source).attributedString
            rendered.enumerateAttribute(.markdownHorizontalRule, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                #expect(value == nil)
            }
        }
    }

    @Test func orderedListInlineFormattingKeepsVisualNesting() throws {
        let original = "1. 哈 哈哈\n2. 哈哈  ~~等等~~\n3. 点*多到*\n4. 点多到\n5. 大\n"
        let source = "1. 哈 哈哈\n    1. 哈哈  ~~等等~~\n3. 点*多到*\n4. 点多到\n5. 大\n"
        let session = DocumentSession(source: original)
        session.undoManager.groupsByEvent = false
        session.renderNow()
        let editor = MarkdownEditorController(session: session)
        _ = editor.view
        let target = (editor.textView.string as NSString).range(of: "哈哈  等等")
        editor.textView.setSelectedRange(NSRange(location: target.location, length: 0))
        session.undoManager.beginUndoGrouping()
        #expect(editor.perform(.indent))
        session.undoManager.endUndoGrouping()
        #expect(session.source == source)
        #expect(editor.textView.selectedRange().location == (editor.textView.string as NSString).range(of: "哈哈  等等").location)
        let snapshot = MarkdownRenderer.snapshot(source: source)
        let rendered = MarkdownRenderer.render(snapshot: snapshot).attributedString
        let storage = NSTextStorage(attributedString: rendered)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 520, height: 10_000))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let markers = snapshot.sourceMap.segments.filter(\.isListMarker)
        #expect(markers.count == 5)
        let positions = markers.map {
            layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: $0.displayedNSRange, actualCharacterRange: nil), in: container).minX
        }
        #expect(abs(positions[1] - positions[0] - 32) < 0.5)
        #expect(abs(positions[2] - positions[0]) < 0.5)
        let nested = markers[1].displayedNSRange
        let paragraphRange = (rendered.string as NSString).paragraphRange(for: nested)
        let contentRange = NSRange(location: paragraphRange.location, length: paragraphRange.length - 1)
        rendered.enumerateAttribute(.paragraphStyle, in: contentRange) { value, _, _ in
            #expect((value as? NSParagraphStyle)?.firstLineHeadIndent == 32)
            #expect((value as? NSParagraphStyle)?.headIndent == 32)
        }
        let struck = (rendered.string as NSString).range(of: "等等")
        #expect(rendered.attribute(.strikethroughStyle, at: struck.location, effectiveRange: nil) != nil)
        #expect(snapshot.source == source)
        session.undoManager.undo()
        session.renderNow()
        #expect(session.source == original)
    }

    @Test func nestedListsUseClearVisualIndentation() throws {
        for marker in ["-", "1.", "- [ ]"] {
            let longText = String(repeating: "wrapped content ", count: 12)
            let source = "\(marker) parent\n    \(marker) child \(longText)\n        \(marker) grandchild\n    \(marker) sibling\n\(marker) peer"
            let snapshot = MarkdownRenderer.snapshot(source: source)
            let rendered = MarkdownRenderer.render(snapshot: snapshot).attributedString
            let storage = NSTextStorage(attributedString: rendered)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 520, height: 10_000))
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            let markers = snapshot.sourceMap.segments.filter(\.isListMarker)
            #expect(markers.count == 5)
            let positions = markers.map {
                layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: $0.displayedNSRange, actualCharacterRange: nil), in: container).minX
            }
            #expect(positions[1] - positions[0] >= 31)
            #expect(positions[2] - positions[1] >= 31)
            #expect(abs(positions[3] - positions[1]) < 0.5)
            #expect(abs(positions[4] - positions[0]) < 0.5)
            let child = markers[1].displayedNSRange
            let paragraphRange = (snapshot.text as NSString).paragraphRange(for: child)
            let paragraphGlyphs = layout.glyphRange(forCharacterRange: paragraphRange, actualCharacterRange: nil)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: paragraphGlyphs) { _, used, _, _, _ in
                if lines > 0 { #expect(abs(used.minX + container.lineFragmentPadding - positions[1]) < 0.5) }
                lines += 1
            }
            #expect(lines > 1)
            #expect(snapshot.source == source)
            #expect(rendered.string == snapshot.text)
        }
    }

    @Test func quotesHaveContinuousNestedLeftBordersWithoutChangingSource() throws {
        let source = "Before\n\n> first\n> continued\n>\n> second\n>\n> > nested\n>\n> ```\n> code\n> ```\n\nAfter"
        let snapshot = MarkdownRenderer.snapshot(source: source)
        let rendered = MarkdownRenderer.render(snapshot: snapshot).attributedString
        let text = rendered.string as NSString
        func blocks(_ word: String) -> [NSTextBlock] {
            (rendered.attribute(.paragraphStyle, at: text.range(of: word).location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks ?? []
        }
        let first = try #require(blocks("first").first as? QuoteTextBlock)
        #expect(first.width(for: .border, edge: .minX) == 3)
        #expect(first.width(for: .padding, edge: .minX) == 12)
        #expect(blocks("continued").first === first)
        #expect(blocks("second").first === first)
        #expect(blocks("nested").count == 2)
        #expect(blocks("nested").first === first)
        #expect(blocks("nested").last is QuoteTextBlock)
        #expect(blocks("code").first === first)
        #expect(blocks("code").last is CodeBlockTextBlock)
        #expect(blocks("Before").isEmpty)
        #expect(blocks("After").isEmpty)
        #expect(snapshot.source == source)
        #expect(snapshot.quoteRanges.count == 2)
    }

    @Test func quoteRailsRenderAndKeepNestedContentWithinBounds() throws {
        _ = NSApplication.shared
        let source = "## Quote\n\n> First quoted line\n> continuing on the next line\n>\n> Another paragraph\n>\n> > Nested quotation\n>\n> ```\n> code\n> ```\n>\n> | A | B |\n> | --- | --- |\n> | value | other |\n\nAfter"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 680)
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        editor.appearance = NSAppearance(named: .aqua)
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let storage = try #require(editor.textStorage)
        layout.ensureLayout(for: container)
        func blockBounds(_ word: String, index: Int) throws -> NSRect {
            let character = (editor.string as NSString).range(of: word).location
            let paragraph = try #require(storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle)
            return layout.boundsRect(for: paragraph.textBlocks[index], at: layout.glyphIndexForCharacter(at: character), effectiveRange: nil)
        }
        let outer = try blockBounds("First", index: 0)
        #expect(outer.width >= container.size.width - 2 * container.lineFragmentPadding - 1)
        let nested = try blockBounds("Nested", index: 1)
        #expect(nested.minX >= outer.minX + 15)
        #expect(nested.maxX <= outer.maxX + 1)
        let table = try blockBounds("value", index: 1)
        #expect(table.maxX <= outer.maxX + 1)
        #expect((layout as? TableLayoutManager)?.tableRows(in: container).count == 2)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / editor.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / editor.bounds.height
        let horizontal = Int((outer.minX + editor.textContainerOrigin.x + 1) * scaleX)
        let vertical = Int((outer.minY + editor.textContainerOrigin.y + 8) * scaleY)
        let color = try #require(bitmap.colorAt(x: horizontal, y: vertical)?.usingColorSpace(.deviceRGB))
        #expect(min(color.redComponent, color.greenComponent, color.blueComponent) < 0.95)
        #expect(session.source == source)
        window.contentViewController = nil
    }

    @Test func sourceToRichSwitchUsesFinalLayoutBeforeRestoringViewport() async throws {
        _ = NSApplication.shared
        let source = (0..<90).map { "## Section \($0)\n\nParagraph \($0) **bold** and more text.\n\n***\n\n" }.joined()
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let editor = controller.textView!
        window.makeFirstResponder(editor)
        defer { window.orderOut(nil); window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        controller.mode = .source
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let clip = try #require(editor.enclosingScrollView?.contentView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("x", replacementRange: editor.selectedRange())
        layout.ensureLayout(for: container)
        editor.sizeToFit()
        let word = "Section 55"
        func lineY() -> CGFloat {
            layout.ensureLayout(for: container)
            let character = (editor.string as NSString).range(of: word).location
            let glyph = layout.glyphIndexForCharacter(at: character)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + editor.textContainerOrigin.y
        }
        editor.scroll(NSPoint(x: 0, y: lineY()))
        let selection = controller.selectedSourceRange()
        controller.mode = .richText
        #expect(session.renderSnapshot?.source == session.source)
        #expect(editor.string == MarkdownRenderer.snapshot(source: session.source).text)
        #expect(abs(lineY() - clip.bounds.minY) < 1)
        let immediate = clip.bounds.origin
        await session.waitForRendering()
        window.displayIfNeeded()
        #expect(abs(clip.bounds.minY - immediate.y) < 1)
        #expect(controller.selectedSourceRange() == selection)
    }

    @Test func modeSwitchKeepsVisibleContentInsteadOfFollowingCaret() throws {
        @MainActor final class Scrolls {
            let clip: NSClipView
            var origins: [NSPoint] = []
            init(clip: NSClipView) { self.clip = clip }
        }
        _ = NSApplication.shared
        let source = (0..<90).map { "## Section \($0)\n\nParagraph \($0) **bold** and more text.\n\n- List item \($0)\n\n" }.joined()
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        defer { window.orderOut(nil) }
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let clip = try #require(editor.enclosingScrollView?.contentView)
        clip.postsBoundsChangedNotifications = true
        let scrolls = Scrolls(clip: clip)
        let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
            MainActor.assumeIsolated { scrolls.origins.append(scrolls.clip.bounds.origin) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        func lineY(_ word: String) -> CGFloat {
            layout.ensureLayout(for: container)
            let range = (editor.string as NSString).range(of: word)
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + editor.textContainerOrigin.y
        }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        for word in ["Section 35", "Paragraph 55", "List item 70"] {
            let top = lineY(word)
            editor.scroll(NSPoint(x: 0, y: top))
            let sourceSelection = controller.selectedSourceRange()
            for mode in [EditorMode.source, .richText, .source, .richText] {
                let previous = clip.bounds.origin
                scrolls.origins.removeAll()
                controller.mode = mode
                window.displayIfNeeded()
                #expect(abs(lineY(word) - clip.bounds.minY) < 1)
                #expect(scrolls.origins.allSatisfy { abs($0.y - previous.y) < 1 || abs($0.y - clip.bounds.minY) < 1 }, "intermediate scrolls: \(scrolls.origins)")
                #expect(controller.selectedSourceRange() == sourceSelection)
            }
        }
        editor.scroll(.zero)
        controller.mode = .source
        #expect(clip.bounds.minY == 0)
        controller.mode = .richText
        #expect(clip.bounds.minY == 0)
        let word = "Paragraph 40"
        let richY = lineY(word)
        let richGlyph = layout.glyphIndexForCharacter(at: (editor.string as NSString).range(of: word).location)
        let height = layout.lineFragmentRect(forGlyphAt: richGlyph, effectiveRange: nil).height
        editor.scroll(NSPoint(x: 0, y: richY + height / 3))
        controller.mode = .source
        let sourceY = lineY(word)
        let sourceGlyph = layout.glyphIndexForCharacter(at: (editor.string as NSString).range(of: word).location)
        let sourceHeight = layout.lineFragmentRect(forGlyphAt: sourceGlyph, effectiveRange: nil).height
        #expect(abs((clip.bounds.minY - sourceY) / sourceHeight - 1 / 3.0) < 0.01)
        controller.mode = .richText
        #expect(abs(clip.bounds.minY - (richY + height / 3)) < 1)
        window.contentViewController = nil
    }

    @Test func sourceToRichSwitchDoesNotClampToShorterDocumentEnd() async throws {
        @MainActor final class Scrolls {
            let clip: NSClipView
            var origins: [NSPoint] = []
            init(clip: NSClipView) { self.clip = clip }
        }
        _ = NSApplication.shared
        let destination = "https://example.com/" + String(repeating: "long-path/", count: 40)
        let source = (0..<90).map { "## Section \($0)\n\n[Link \($0)](\(destination))\n\nParagraph \($0).\n\n" }.joined()
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let editor = controller.textView!
        window.makeFirstResponder(editor)
        defer { window.orderOut(nil); window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let clip = try #require(editor.enclosingScrollView?.contentView)
        clip.postsBoundsChangedNotifications = true
        let scrolls = Scrolls(clip: clip)
        let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
            MainActor.assumeIsolated { scrolls.origins.append(scrolls.clip.bounds.origin) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        func lineY(_ word: String) -> CGFloat {
            layout.ensureLayout(for: container)
            let character = (editor.string as NSString).range(of: word).location
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil).minY + editor.textContainerOrigin.y
        }
        for word in ["Section 35", "Paragraph 70"] {
            controller.mode = .source
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            let top = lineY(word)
            editor.sizeToFit()
            editor.scroll(NSPoint(x: 0, y: top))
            let previous = clip.bounds.origin
            scrolls.origins.removeAll()
            controller.mode = .richText
            let target = lineY(word)
            #expect(abs(clip.bounds.minY - target) < 1)
            #expect(scrolls.origins.allSatisfy { abs($0.y - previous.y) < 1 || abs($0.y - target) < 1 }, "intermediate scrolls: \(scrolls.origins)")
            await Task.yield()
            window.displayIfNeeded()
            #expect(abs(clip.bounds.minY - target) < 1)
            #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        }
    }

    @Test func italicIsVisibleForLatinAndChinese() throws {
        let result = MarkdownRenderer.render(source: "plain 正文 *word 中文* ***粗斜*** _斜_")
        let text = result.attributedString.string as NSString
        func attributes(_ word: String) -> [NSAttributedString.Key: Any] {
            result.attributedString.attributes(at: text.range(of: word).location, effectiveRange: nil)
        }
        let latin = try #require(attributes("word")[.font] as? NSFont)
        #expect(latin.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(attributes("word")[.obliqueness] == nil)
        for word in ["中文", "粗斜", "斜"] { #expect((attributes(word)[.obliqueness] as? Double ?? 0) > 0, "\(word)") }
        #expect(attributes("正文")[.obliqueness] == nil)
        #expect(attributes("plain")[.obliqueness] == nil)
    }

    @Test func leadingSpacesOnFirstLineKeepIndentedContinuationInPlace() throws {
        let source = "## 概要设计\n\n内容\n            概要设计\n\nAfter"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let manager = try #require(controller.textView.layoutManager)
        let container = try #require(controller.textView.textContainer)
        func continuationX() -> CGFloat {
            manager.ensureLayout(for: container)
            let range = (controller.textView.string as NSString).range(of: "概要设计", options: .backwards)
            return manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container).minX
        }
        let expected = continuationX()
        controller.textView.setSelectedRange(NSRange(location: (controller.textView.string as NSString).range(of: "内容").location, length: 0))
        session.undoManager.groupsByEvent = false
        for count in 1...3 {
            session.undoManager.beginUndoGrouping()
            controller.textView.insertText(" ", replacementRange: controller.textView.selectedRange())
            session.undoManager.endUndoGrouping()
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: "\n内容", with: "\n" + String(repeating: " ", count: count) + "内容"))
            #expect(controller.textView.string.contains("\n            概要设计"))
            #expect(continuationX() == expected, "space \(count)")
        }
        for _ in 1...3 { session.undoManager.undo() }
        #expect(session.source == source)
    }

    @Test func editedSourceStaysNativeSoRenderingStaysLinear() {
        let session = DocumentSession(source: "# 标题\n\n正文 **加粗**\n")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        session.undoManager.groupsByEvent = false
        for _ in 0..<3 {
            session.undoManager.beginUndoGrouping()
            controller.textView.insertText("字", replacementRange: controller.textView.selectedRange())
            session.undoManager.endUndoGrouping()
            #expect(session.source.utf8.withContiguousStorageIfAvailable { _ in true } == true)
        }
        session.renderNow()
        #expect(session.renderSnapshot!.text.utf8.withContiguousStorageIfAvailable { _ in true } == true)
        let edited = session.source
        for _ in 0..<3 { session.undoManager.undo() }
        #expect(session.source == "# 标题\n\n正文 **加粗**\n")
        for _ in 0..<3 { session.undoManager.redo() }
        #expect(session.source == edited)
    }

    @Test func codeBlocksAndInlineCodeAreFramed() throws {
        let source = "Text `inline` end\n\n```swift\nlet a = 1\n\nprint(a)\n```\n\n    indented\n    more\n\nAfter"
        let result = MarkdownRenderer.render(source: source)
        let text = result.attributedString.string as NSString
        func block(_ word: String) -> NSTextBlock? {
            (result.attributedString.attribute(.paragraphStyle, at: text.range(of: word).location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
        }
        #expect(block("inline") == nil)
        #expect(block("Text") == nil)
        #expect(block("After") == nil)
        let fenced = try #require(block("let a") as? CodeBlockTextBlock)
        #expect(fenced.width(for: .border, edge: .maxY) == 1)
        #expect(block("print") === fenced)
        let indented = try #require(block("indented") as? CodeBlockTextBlock)
        #expect(block("more") === indented)
        #expect(indented !== fenced)
        let inline = text.range(of: "inline")
        var span = NSRange()
        #expect(result.attributedString.attribute(.markdownInlineCode, at: inline.location, longestEffectiveRange: &span, in: NSRange(location: 0, length: text.length)) != nil)
        #expect(span == inline)
        #expect(result.attributedString.attribute(.markdownInlineCode, at: text.range(of: "let a").location, effectiveRange: nil) == nil)
        #expect(result.attributedString.attribute(.kern, at: NSMaxRange(inline) - 1, effectiveRange: nil) as? CGFloat == 2 * CodeBlockTextBlock.inlinePadding)
        #expect(result.attributedString.attribute(.kern, at: inline.location - 1, effectiveRange: nil) as? CGFloat == 2 * CodeBlockTextBlock.inlinePadding)
        for word in ["inline", "let a"] {
            #expect(result.attributedString.attribute(.backgroundColor, at: text.range(of: word).location, effectiveRange: nil) == nil)
        }
    }

    @Test func codeBlockBottomBorderSurvivesPartialRedraw() throws {
        _ = NSApplication.shared
        for source in ["## Heading\n    code\n\n   Body\n            continuation\n", "## Heading\n\n```\nfirst\nsecond\n```\n\nBody"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            controller.view.layoutSubtreeIfNeeded()
            let editor = controller.textView!
            editor.appearance = NSAppearance(named: .aqua)
            let layout = try #require(editor.layoutManager)
            let container = try #require(editor.textContainer)
            let storage = try #require(editor.textStorage)
            let word = source.contains("first") ? "first" : "code"
            func bottomDarkness(backgroundOnly: Bool = false) throws -> CGFloat {
                layout.ensureLayout(for: container)
                let character = (editor.string as NSString).range(of: word).location
                let paragraph = try #require(storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle)
                let block = try #require(paragraph.textBlocks.first as? CodeBlockTextBlock)
                let glyph = layout.glyphIndexForCharacter(at: character)
                let bounds = layout.boundsRect(for: block, at: glyph, effectiveRange: nil).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                let frame = block.backgroundRect(for: bounds)
                let strip = backgroundOnly
                    ? NSRect(x: frame.midX - 30, y: floor(frame.maxY) - 1, width: 60, height: 1)
                    : NSRect(x: bounds.midX - 30, y: floor(bounds.maxY) - 10, width: 60, height: 14)
                let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: strip))
                if backgroundOnly {
                    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    context.cgContext.concatenate(context.cgContext.ctm.inverted())
                    let scaleX = CGFloat(bitmap.pixelsWide) / strip.width
                    let scaleY = CGFloat(bitmap.pixelsHigh) / strip.height
                    context.cgContext.translateBy(x: -strip.minX * scaleX, y: CGFloat(bitmap.pixelsHigh) + strip.minY * scaleY)
                    context.cgContext.scaleBy(x: scaleX, y: -scaleY)
                    editor.drawBackground(in: strip)
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    editor.cacheDisplay(in: strip, to: bitmap)
                }
                var darkest: CGFloat = 1
                for vertical in 0..<bitmap.pixelsHigh {
                    let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: vertical)?.usingColorSpace(.deviceRGB))
                    darkest = min(darkest, color.redComponent, color.greenComponent, color.blueComponent)
                }
                return darkest
            }
            #expect(try bottomDarkness() < 0.94)
            #expect(try bottomDarkness(backgroundOnly: true) < 0.94)
            session.undoManager.groupsByEvent = false
            session.undoManager.beginUndoGrouping()
            let insertion = NSMaxRange((editor.string as NSString).range(of: word))
            editor.insertText(" extra", replacementRange: NSRange(location: insertion, length: 0))
            session.undoManager.endUndoGrouping()
            #expect(try bottomDarkness() < 0.94)
            session.renderNow()
            #expect(try bottomDarkness() < 0.94)
            session.undoManager.undo()
            session.renderNow()
            #expect(try bottomDarkness() < 0.94)
            controller.mode = .source
            controller.mode = .richText
            #expect(try bottomDarkness() < 0.94)
            #expect(try bottomDarkness(backgroundOnly: true) < 0.94)
            editor.scroll(NSPoint(x: 0, y: 30))
            editor.scroll(.zero)
            #expect(try bottomDarkness(backgroundOnly: true) < 0.94)
            window.contentViewController = nil
        }
    }

    @Test func everyLeadingSpaceMovesTextIncludingIndentedCodeThreshold() throws {
        let cases: [(source: String, sourcePrefix: String)] = [
            ("hello", ""), ("Before\n\nhello", "Before\n\n"), ("before\nhello", "before\n"),
            ("## 概要设计\nhello", "## 概要设计\n"), ("# 哈哈\n\n```\ncode\n```\n\nhello", "# 哈哈\n\n```\ncode\n```\n\n"),
            ("1. 哈哈\n2. hello", "1. 哈哈\n2. "), ("- a\n\n  hello", "- a\n\n"), ("> a\n> hello", "> a\n> "),
            ("|a|b|\n|---|---|\n|c|d|\n\nhello", "|a|b|\n|---|---|\n|c|d|\n\n"), ("![](x.png)\nhello", "![](x.png)\n"),
            ("1. a\n\n\n\n4. aaa\n    \n\n\n  hello", "1. a\n\n\n\n4. aaa\n    \n\n\n")
        ]
        for (source, sourcePrefix) in cases {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let manager = try #require(controller.textView.layoutManager)
            let container = try #require(controller.textView.textContainer)
            func x() -> CGFloat {
                manager.ensureLayout(for: container)
                let range = (controller.textView.string as NSString).range(of: "hello", options: .backwards)
                return manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container).minX
            }
            let displayed = controller.textView.string as NSString
            let lineStart = displayed.lineRange(for: displayed.range(of: "hello", options: .backwards)).location
            controller.textView.setSelectedRange(NSRange(location: lineStart, length: 0))
            let body = String(source.dropFirst(sourcePrefix.count))
            session.undoManager.groupsByEvent = false
            for count in 1...8 {
                let before = x()
                session.undoManager.beginUndoGrouping()
                controller.textView.insertText(" ", replacementRange: controller.textView.selectedRange())
                session.undoManager.endUndoGrouping()
                #expect(session.source == sourcePrefix + String(repeating: " ", count: count) + body, "Source: \(source)")
                let immediate = x()
                #expect(immediate > before, "Source: \(source), space \(count)")
                session.renderNow()
                #expect(x() == immediate, "Source: \(source), space \(count)")
            }
            for _ in 1...8 { session.undoManager.undo() }
            session.renderNow()
            #expect(session.source == source)
        }
        #expect(MarkdownRenderer.snapshot(source: "    code").runs.contains { $0.style.contains(.code) })
    }

    @Test func spacesMoveTextImmediatelyWithoutLaterLayoutJump() throws {
        for source in ["hello world", "Before\n\nhello world", "before\nhello world", "# hello world", "**hello world**", "中文文字 hello world", "- hello world", "> hello world", "```\nhello world\n```", "| hello world | value |\n| --- | --- |\n| body | text |"] {
            for leading in [true, false] {
                let session = DocumentSession(source: source)
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                let target = leading ? "hello" : "world"
                let manager = try #require(controller.textView.layoutManager)
                let container = try #require(controller.textView.textContainer)
                func rect() -> NSRect {
                    manager.ensureLayout(for: container)
                    let range = (controller.textView.string as NSString).range(of: target)
                    return manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                }
                let offset = (controller.textView.string as NSString).range(of: target).location
                controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
                session.undoManager.groupsByEvent = false
                for _ in 0..<3 {
                    let before = rect()
                    let sourceOffset = session.selectedSourceRange.location
                    let expectedSource = (session.source as NSString).replacingCharacters(in: NSRange(location: sourceOffset, length: 0), with: " ")
                    session.undoManager.beginUndoGrouping()
                    controller.textView.insertText(" ", replacementRange: controller.textView.selectedRange())
                    session.undoManager.endUndoGrouping()
                    #expect(session.source == expectedSource)
                    let immediate = rect()
                    #expect(immediate.minX > before.minX, "Source: \(source), leading: \(leading)")
                    let caret = controller.textView.selectedRange()
                    session.renderNow()
                    #expect(rect() == immediate, "Source: \(source), leading: \(leading)")
                    #expect(controller.textView.selectedRange() == caret)
                }
                for _ in 0..<3 { session.undoManager.undo() }
                session.renderNow()
                #expect(session.source == source)
            }
        }
    }

    @Test func leadingSpacesPreserveRawSourceAndStandardCodeWithUndo() {
        for mode in [EditorMode.richText, .source] {
            let session = DocumentSession(source: "hello")
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            controller.mode = mode
            controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
            session.undoManager.groupsByEvent = false
            for count in 1...6 {
                session.undoManager.beginUndoGrouping()
                controller.textView.insertText(" ", replacementRange: controller.textView.selectedRange())
                session.undoManager.endUndoGrouping()
                #expect(session.source == String(repeating: " ", count: count) + "hello")
                let immediate = controller.textView.string
                let caret = controller.textView.selectedRange()
                session.renderNow()
                #expect(controller.textView.string == immediate)
                #expect(controller.textView.selectedRange() == caret)
                if mode == .richText {
                    #expect(caret == session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: NSRange(location: count, length: 0)))
                    #expect(session.formattingState(.codeBlock) == (count >= 4 ? .on : .off))
                }
            }
            session.undoManager.beginUndoGrouping()
            controller.textView.insertText("X", replacementRange: controller.textView.selectedRange())
            session.undoManager.endUndoGrouping()
            #expect(session.source == "      Xhello")
            for _ in 0..<7 { session.undoManager.undo() }
            session.renderNow()
            #expect(session.source == "hello")
        }
    }

    @Test func leadingSpaceAndReturnHaveStableImmediateLayout() throws {
        for source in ["hello", "Before\n\nhello", "before\nhello", "# hello", "```\nhello\n```"] {
            for replacement in [" ", "\n"] {
                for mode in [EditorMode.richText, .source] {
                    let session = DocumentSession(source: source)
                    session.renderNow()
                    let controller = MarkdownEditorController(session: session)
                    _ = controller.view
                    controller.mode = mode
                    let offset = (controller.textView.string as NSString).range(of: "hello").location
                    controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
                    session.undoManager.groupsByEvent = false
                    session.undoManager.beginUndoGrouping()
                    if replacement == "\n" { controller.textView.insertNewline(nil) }
                    else { controller.textView.insertText(replacement, replacementRange: controller.textView.selectedRange()) }
                    session.undoManager.endUndoGrouping()
                    let expectedSource = mode == .richText && source == "# hello" && replacement == "\n"
                        ? "\n" + source : source.replacingOccurrences(of: "hello", with: replacement + "hello")
                    #expect(session.source == expectedSource)
                    let immediate = try #require(controller.textView.textStorage?.copy() as? NSAttributedString)
                    let caret = controller.textView.selectedRange()
                    let manager = try #require(controller.textView.layoutManager)
                    let container = try #require(controller.textView.textContainer)
                    manager.ensureLayout(for: container)
                    let body = (controller.textView.string as NSString).range(of: "hello")
                    let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: body, actualCharacterRange: nil), in: container)
                    if mode == .richText {
                        #expect(immediate.string == MarkdownRenderer.snapshot(source: session.source).text)
                    }
                    session.renderNow()
                    #expect(controller.textView.string == immediate.string)
                    #expect(controller.textView.selectedRange() == caret)
                    let finalBody = (controller.textView.string as NSString).range(of: "hello")
                    let beforeStyle = immediate.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle
                    let afterStyle = controller.textView.textStorage?.attribute(.paragraphStyle, at: finalBody.location, effectiveRange: nil) as? NSParagraphStyle
                    #expect(beforeStyle == afterStyle)
                    manager.ensureLayout(for: container)
                    let finalRect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: finalBody, actualCharacterRange: nil), in: container)
                    #expect(rect == finalRect)
                    session.undoManager.undo()
                    session.renderNow()
                    #expect(session.source == source)
                }
            }
        }
    }

    @Test func leadingTabHasNoProvisionalIndentationJump() {
        for source in ["hello", "Before\n\nhello", "before\nhello", "```\nhello\n```"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let offset = (controller.textView.string as NSString).range(of: "hello").location
            controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
            session.undoManager.groupsByEvent = false
            session.undoManager.beginUndoGrouping()
            controller.textView.insertTab(nil)
            session.undoManager.endUndoGrouping()
            let immediate = controller.textView.string
            let caret = controller.textView.selectedRange()
            #expect(immediate == MarkdownRenderer.snapshot(source: session.source).text)
            session.renderNow()
            #expect(controller.textView.string == immediate)
            #expect(controller.textView.selectedRange() == caret)
            controller.textView.setSelectedRange(caret)
            session.undoManager.beginUndoGrouping()
            controller.textView.insertText("X", replacementRange: caret)
            session.undoManager.endUndoGrouping()
            session.renderNow()
            #expect(session.source.contains("\tXhello"))
            session.undoManager.undo()
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
        }
    }

    @Test func standardPunctuationIsNotAutomaticallyRewritten() {
        let source = "\"straight\" 'quote' -- --- ..."
        #expect(MarkdownRenderer.snapshot(source: source).text == source)
    }

    @Test func indentedListContinuationPeriodCanBeDeleted() {
        for source in ["1. 哈哈哈\n2. 哈哈等等\n3. 点多到\n4. aaa\n    5  等等. \n", "4. aaa\n    5  等等. \n"] {
            for backward in [true, false] {
                let session = DocumentSession(source: source)
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                let body = (controller.textView.string as NSString).range(of: "5  等等.")
                #expect(body.location != NSNotFound)
                guard body.location != NSNotFound else { continue }
                let period = NSRange(location: NSMaxRange(body) - 1, length: 1)
                let snapshot = session.renderSnapshot!
                let mappings = snapshot.sourceMap.segments.filter { NSIntersectionRange($0.displayedNSRange, period).length > 0 }
                #expect(snapshot.sourceMap.sourceRange(forDisplayedRange: period) == (source as NSString).range(of: ".", options: .backwards), "Period mappings: \(mappings)")
                controller.textView.setSelectedRange(NSRange(location: period.location + (backward ? 1 : 0), length: 0))
                session.undoManager.groupsByEvent = false
                session.undoManager.beginUndoGrouping()
                if backward { controller.textView.deleteBackward(nil) }
                else { controller.textView.deleteForward(nil) }
                session.undoManager.endUndoGrouping()
                #expect(session.source == source.replacingOccurrences(of: "等等.", with: "等等"))
                session.renderNow()
                #expect(!controller.textView.string.contains("等等."))
                session.undoManager.undo()
                session.renderNow()
                #expect(session.source == source)
            }
        }
    }

    @Test func leadingTabUsesStandardCodeAndKeepsSourceCaretForTyping() {
        for source in ["hello", "Before\n\nhello"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let offset = (controller.textView.string as NSString).range(of: "hello").location
            controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
            controller.textView.insertTab(nil)
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: "hello", with: "\thello"))
            #expect(controller.textView.selectedRange() == session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: NSRange(location: offset + 1, length: 0)))
            controller.textView.insertTab(nil)
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: "hello", with: "\t\thello"))
            #expect(controller.textView.selectedRange() == session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: NSRange(location: offset + 2, length: 0)))
            controller.textView.deleteBackward(nil)
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: "hello", with: "\thello"))
            #expect(controller.textView.selectedRange() == session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: NSRange(location: offset + 1, length: 0)))
            controller.textView.insertText("X", replacementRange: controller.textView.selectedRange())
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: "hello", with: "\tXhello"))
            #expect(controller.textView.string.contains("Xhello"))
        }
    }

    @Test func tabInOrdinaryTextAndCodeDoesNotInsertNewlines() {
        for source in ["hello", "Before\n\nhello", "```swift\nhello\n```\n", "- item\n  ```\n  hello\n  ```\n", "```\n- hello\n```\n"] {
            for mode in [EditorMode.richText, .source] {
                let session = DocumentSession(source: source)
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                controller.mode = mode
                let original = controller.textView.string
                let offset = NSMaxRange((original as NSString).range(of: "hello"))
                controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
                controller.textView.insertTab(nil)
                session.renderNow()
                #expect(session.source == source.replacingOccurrences(of: "hello", with: "hello\t"))
                #expect(controller.textView.string == (original as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: "\t"))
            }
        }
    }

    @Test func tabPreservesRawSourceAndStandardMarkdownParsingWithUndo() {
        for offset in [0, 2, 5] {
            let session = DocumentSession(source: "hello")
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
            session.undoManager.groupsByEvent = false
            session.undoManager.beginUndoGrouping()
            controller.textView.insertTab(nil)
            session.undoManager.endUndoGrouping()
            session.renderNow()
            let expected = ("hello" as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: "\t")
            #expect(session.source == expected)
            #expect(!session.source.contains("&#9;"))
            #expect(controller.textView.string == MarkdownRenderer.snapshot(source: expected).text)
            #expect(controller.textView.selectedRange() == session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: NSRange(location: offset + 1, length: 0)))
            #expect(session.formattingState(.codeBlock) == (offset == 0 ? .on : .off))
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == "hello")
            #expect(controller.textView.string == "hello")
        }
    }

    @Test func indentedContinuationDeletesBeforeAndAfterReparsing() {
        for count in 1...3 {
            for reparse in [false, true] {
                let indentation = String(repeating: " ", count: count)
                let source = "你好\n" + indentation + "dd\n```\ncode\n```\n"
                let session = DocumentSession(source: source)
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                #expect(controller.textView.string.hasPrefix("你好\n" + indentation + "dd\n"))
                let range = (controller.textView.string as NSString).range(of: "dd")
                controller.textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
                session.undoManager.groupsByEvent = false
                for remaining in ["d", ""] {
                    session.undoManager.beginUndoGrouping()
                    controller.textView.deleteBackward(nil)
                    session.undoManager.endUndoGrouping()
                    if reparse { session.renderNow() }
                    #expect(session.source == source.replacingOccurrences(of: "dd", with: remaining))
                }
                session.undoManager.undo()
                session.renderNow()
                #expect(session.source == source.replacingOccurrences(of: "dd", with: "d"))
                session.undoManager.undo()
                session.renderNow()
                #expect(session.source == source)
            }
        }
    }

    @Test func indentedTextBeforeCodeBlockCanBeDeletedCharacterByCharacter() {
        let source = "# 哈哈哈\n\n你好\n  dd\n```\n#include<stdio.h>\n\nint main() {\n    printf{\"hello\\n\"}\n}\n```\n"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let range = (controller.textView.string as NSString).range(of: "dd")
        let snapshot = session.renderSnapshot!
        for segment in snapshot.sourceMap.segments where NSIntersectionRange(segment.displayedNSRange, range).length > 0 {
            #expect(segment.isIdentity, "dd mapping: \(segment), source: \((source as NSString).substring(with: segment.sourceNSRange))")
        }
        controller.textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        controller.textView.deleteBackward(nil)
        session.renderNow()
        #expect(session.source == source.replacingOccurrences(of: "  dd", with: "  d"))
        let remaining = (controller.textView.string as NSString).range(of: "d")
        #expect(controller.textView.selectedRange().location == NSMaxRange(remaining))
        #expect(session.renderSnapshot!.sourceMap.sourceRange(forDisplayedRange: remaining) == (session.source as NSString).range(of: "d"))
        controller.textView.deleteBackward(nil)
        session.renderNow()
        #expect(session.source == source.replacingOccurrences(of: "  dd", with: "  "))
    }

    @Test func insertingEmptyCodeBlockThenTypingKeepsTextInsideFences() {
        for (source, offset) in [("", 0), ("Before\n\nAfter", 0), ("Before\n\nAfter", 8), ("Before\n\nAfter", 13)] {
            let prefix = (source as NSString).substring(to: offset)
            let suffix = (source as NSString).substring(from: offset)
            let typed = "let value = \"*😀\""
            for mode in [EditorMode.richText, .source] {
                let session = DocumentSession(source: source)
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                controller.mode = mode
                controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
                session.undoManager.groupsByEvent = false
                session.undoManager.beginUndoGrouping()
                #expect(controller.perform(.codeBlock))
                session.undoManager.endUndoGrouping()
                #expect(session.source == prefix + "\n```\n\n```\n" + suffix)
                session.undoManager.beginUndoGrouping()
                controller.textView.insertText(typed, replacementRange: controller.textView.selectedRange())
                session.undoManager.endUndoGrouping()
                session.renderNow()
                #expect(session.source == prefix + "\n```\n" + typed + "\n```\n" + suffix)
                session.undoManager.undo()
                session.renderNow()
                #expect(session.source == prefix + "\n```\n\n```\n" + suffix)
                session.undoManager.undo()
                session.renderNow()
                #expect(session.source == source)
            }
        }
    }

    @Test func codeBlockBlankLinesKeepEditableMappings() {
        let source = "```swift\n\nfirst\n\nlast\n\n```"
        let snapshot = MarkdownRenderer.snapshot(source: source)
        #expect(snapshot.text == "\nfirst\n\nlast\n\n")
        #expect(snapshot.sourceMap.segments.allSatisfy { $0.kind == .code })
        for offset in [0, 7, 13] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let insertion = snapshot.sourceMap.sourceOffset(forDisplayedOffset: offset, preferTrailing: true)
            #expect(session.editRendered(range: NSRange(location: offset, length: 0), replacement: "*text*"))
            #expect(session.source == (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "*text*"))
        }
    }

    @Test func newlineAfterFormattedTextStaysOutsideClosingMarkers() {
        for formatted in ["~~图片试试~~", "**图片试试**", "*图片试试*", "**~~图片试试~~**", "[图片试试](https://example.com)", "`图片试试`"] {
            let source = "## 详细设计2\n\n点多到---" + formatted + "\n![](images/example.png)\n"
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let original = NSString(string: controller.textView.string)
            let offset = NSMaxRange(original.range(of: "图片试试"))
            controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
            controller.textView.insertNewline(nil)
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: formatted + "\n", with: formatted + "\n\n"))
            #expect(controller.textView.string == original.replacingCharacters(in: NSRange(location: offset, length: 0), with: "\n"))
            #expect(controller.textView.selectedRange() == NSRange(location: offset + 1, length: 0))
            controller.textView.insertText("下一行", replacementRange: controller.textView.selectedRange())
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: formatted + "\n", with: formatted + "\n下一行\n"))
            session.undoManager.undo()
            session.renderNow()
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
        }
    }

    @Test func newlineWithinFormattingAndOrdinaryTypingKeepTheirContext() {
        for formatted in ["~~图片试试~~", "**图片试试**", "*图片试试*"] {
            let source = "点多到---" + formatted + "\n![](images/example.png)\n"
            let session = DocumentSession(source: source)
            session.renderNow()
            let text = session.renderSnapshot!.text as NSString
            let inside = NSMaxRange(text.range(of: "图片"))
            #expect(session.editRendered(range: NSRange(location: inside, length: 0), replacement: "\n"))
            #expect(session.source == source.replacingOccurrences(of: "图片试试", with: "图片\n试试"))
            session.undoManager.undo()
            session.renderNow()
            let end = NSMaxRange((session.renderSnapshot!.text as NSString).range(of: "图片试试"))
            #expect(session.editRendered(range: NSRange(location: end, length: 0), replacement: "文字"))
            #expect(session.source == source.replacingOccurrences(of: "图片试试", with: "图片试试文字"))
        }
    }

    @Test func smartPunctuationHasLocalEditableMappings() throws {
        for punctuation in ["---", "--", "----", "-----", "------", "...", "\"quoted\"", "it's"] {
            let source = "prefix | \(punctuation) suffix"
            let snapshot = MarkdownRenderer.snapshot(source: source)
            let pipe = (snapshot.text as NSString).range(of: "|")
            let session = DocumentSession(source: source)
            session.renderNow()
            #expect(session.editRendered(range: pipe, replacement: ""))
            #expect(session.source == source.replacingOccurrences(of: "|", with: ""))
            session.undoManager.undo()
            #expect(session.source == source)
            let punctuationRange = NSRange(location: "prefix | ".utf16.count, length: snapshot.text.utf16.count - "prefix | ".utf16.count - " suffix".utf16.count)
            let patches = try #require(snapshot.sourceMap.patches(forDisplayedRange: punctuationRange, replacement: "", source: source))
            #expect(session.apply(patches))
            #expect(session.source == "prefix |  suffix")
        }
    }

    @Test func literalPipesBeforeFormattedTextAndImageCanBeDeleted() throws {
        let source = "## 详细设计2\n\n|    |    ||    点多到---~~图片试试~~\n![](images/example.png)\n"
        for characterOffset in 0..<16 {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let original = controller.textView.string as NSString
            let pipeStart = original.range(of: "|").location
            let deletion = NSRange(location: pipeStart + characterOffset, length: 1)
            let sourceDeletion = try #require(session.renderSnapshot!.sourceMap.sourceRange(forDisplayedRange: deletion))
            let expectedSource = (source as NSString).replacingCharacters(in: sourceDeletion, with: "")
            controller.textView.setSelectedRange(NSRange(location: NSMaxRange(deletion), length: 0))
            controller.textView.deleteBackward(nil)
            session.renderNow()
            #expect(session.source == expectedSource)
            #expect(controller.textView.string == MarkdownRenderer.snapshot(source: expectedSource).text, "Deletion at offset \(characterOffset)")
        }
    }

    @Test func trailingSpacesAndLiteralPipesRemainEditable() {
        for source in ["text", "text\nnext", "# Heading\n\nBody", "|    |    ||    点多到"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let lineEnd = (controller.textView.string as NSString).range(of: "\n").location
            let offset = lineEnd == NSNotFound ? controller.textView.string.utf16.count : lineEnd
            controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
            for count in 1...3 {
                controller.textView.insertText(" ", replacementRange: controller.textView.selectedRange())
                session.renderNow()
                #expect(controller.textView.selectedRange().location == offset + count)
                let prefix = String(controller.textView.string.prefix(offset + count))
                #expect(prefix.hasSuffix(String(repeating: " ", count: count)))
            }
        }
        let session = DocumentSession()
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        let literal = "|    |    ||    点多到"
        for character in literal {
            controller.textView.insertText(String(character), replacementRange: controller.textView.selectedRange())
            session.renderNow()
        }
        #expect(controller.textView.string == literal)
        while !controller.textView.string.isEmpty {
            let previous = controller.textView.string
            controller.textView.deleteBackward(nil)
            session.renderNow()
            #expect(controller.textView.string == String(previous.dropLast()))
            if controller.textView.string == previous { break }
        }
        #expect(session.source.isEmpty)
    }

    @Test(arguments: 1...6) func headingVisualHierarchy(level: Int) throws {
        let styles: [(size: CGFloat, before: CGFloat, after: CGFloat)] = [
            (34, 20, 10), (28, 16, 8), (24, 12, 6),
            (20, 10, 6), (18, 8, 4), (16, 6, 4)
        ]
        let source = "\(String(repeating: "#", count: level)) Heading *emphasis* `code`\n\nBody"
        let result = MarkdownRenderer.render(source: source)
        let expected = styles[level - 1]
        #expect(result.attributedString.string == "Heading emphasis code\n\nBody")
        for word in ["Heading", "emphasis", "code"] {
            let displayedRange = (result.attributedString.string as NSString).range(of: word)
            let font = try #require(result.attributedString.attribute(.font, at: displayedRange.location, effectiveRange: nil) as? NSFont)
            let paragraph = try #require(result.attributedString.attribute(.paragraphStyle, at: displayedRange.location, effectiveRange: nil) as? NSParagraphStyle)
            #expect(font.pointSize == expected.size)
            #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            #expect(paragraph.paragraphSpacingBefore == expected.before)
            #expect(paragraph.paragraphSpacing == expected.after)
            #expect((result.attributedString.attribute(.markdownHeadingSeparator, at: displayedRange.location, effectiveRange: nil) != nil) == (level <= 2))
            #expect(result.sourceMap.sourceRange(forDisplayedRange: displayedRange) == (source as NSString).range(of: word))
        }
        let bodyRange = (result.attributedString.string as NSString).range(of: "Body")
        let bodyFont = try #require(result.attributedString.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont)
        let bodyParagraph = try #require(result.attributedString.attribute(.paragraphStyle, at: bodyRange.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(bodyFont.pointSize == 16)
        #expect(!NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
        #expect(bodyParagraph.paragraphSpacingBefore == 0)
        #expect(bodyParagraph.paragraphSpacing == 6)
    }

    @Test func existingPipesSupportRapidDeletionAndUndo() {
        for source in ["|    |    ||    点多到", "\\|    \\|    \\|\\|    点多到"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let initialText = controller.textView.string
            controller.textView.setSelectedRange(NSRange(location: initialText.utf16.count, length: 0))
            for _ in initialText {
                let previous = controller.textView.string
                controller.textView.deleteBackward(nil)
                #expect(controller.textView.string == String(previous.dropLast()))
                if controller.textView.string == previous { break }
            }
            session.renderNow()
            #expect(session.source.isEmpty)
            #expect(controller.textView.string.isEmpty)
            for _ in initialText { session.undoManager.undo() }
            session.renderNow()
            #expect(session.source == source)
            #expect(controller.textView.string == initialText)
            controller.textView.setSelectedRange(NSRange(location: 1, length: 0))
            controller.textView.deleteBackward(nil)
            session.renderNow()
            let expectedSource = String(source.dropFirst(source.hasPrefix("\\|") ? 2 : 1))
            #expect(session.source == expectedSource)
            #expect(controller.textView.string == MarkdownRenderer.snapshot(source: expectedSource).text)
        }
    }

    @Test func whitespaceBreaksKeepIndependentSourceMappings() {
        for source in ["text  \nnext", "text  \r\nnext", "text \n\nnext", "# Heading \n\nBody"] {
            let snapshot = MarkdownRenderer.snapshot(source: source)
            #expect(snapshot.text == source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "# ", with: ""))
            for segment in snapshot.sourceMap.segments where segment.kind == .lineBreak {
                let value = (source as NSString).substring(with: segment.sourceNSRange)
                #expect(value == "\n" || value == "\r\n")
            }
        }
        #expect(MarkdownRenderer.snapshot(source: "text\\\nnext").text == "text\nnext")
        #expect(MarkdownRenderer.snapshot(source: "# Heading ###\n\nBody").text == "Heading\n\nBody")
    }

    @Test func leadingSpaceTypingUsesStandardCodeWithoutEntities() {
        for literal in ["    |    点多到", "    first\n    second"] {
            let session = DocumentSession()
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            var expected = ""
            for character in literal {
                expected += String(character)
                controller.textView.insertText(String(character), replacementRange: controller.textView.selectedRange())
                #expect(session.source == expected)
                session.renderNow()
                #expect(controller.textView.string == MarkdownRenderer.snapshot(source: expected).text)
                #expect(controller.textView.selectedRange() == session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: NSRange(location: expected.utf16.count, length: 0)))
            }
            session.renderNow()
            #expect(session.source == literal)
            #expect(controller.textView.string == literal)
            #expect(session.renderSnapshot?.runs.contains { $0.style.contains(.code) } == true)
        }
        let snapshot = MarkdownRenderer.snapshot(source: "    actual code\n")
        #expect(snapshot.runs.contains { $0.style.contains(.code) })
    }

    @Test func utf8ColumnsConvertToUTF16() {
        let coordinates = SourceCoordinates(source: "# 中文😀e\u{301}\n下一行")
        #expect(coordinates.utf16Offset(line: 1, utf8Column: 13) == 6)
        #expect(coordinates.utf16Offset(line: 2, utf8Column: 4) == 10)
        #expect(coordinates.utf16Offset(line: 1, utf8Column: 4) == nil)
    }

    @Test func emojiMappingAndHiddenSyntax() {
        let source = "# 中文😀\n\n**粗😀** and *斜* ~~删~~ `a*b`"
        let result = MarkdownRenderer.render(source: source)
        #expect(result.attributedString.string == "中文😀\n\n粗😀 and 斜 删 a*b")
        let shown = (result.attributedString.string as NSString).range(of: "粗😀")
        #expect(result.sourceMap.sourceRange(forDisplayedRange: shown) == (source as NSString).range(of: "粗😀"))
        #expect(result.sourceMap.displayedRange(forSourceRange: (source as NSString).range(of: "粗😀")) == shown)
        let font = result.attributedString.attribute(.font, at: shown.location, effectiveRange: nil) as? NSFont
        #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    }

    @Test func richEditPreservesMarkupAndUnknownSource() {
        let source = "**ab** *cd*\n\n<div data-test='保留'>raw</div>\n"
        let session = DocumentSession(source: source)
        session.renderNow()
        #expect(session.editRendered(range: NSRange(location: 1, length: 3), replacement: "*😀"))
        #expect(session.source == "**a\\*😀***d*\n\n<div data-test='保留'>raw</div>\n")
        #expect(MarkdownRenderer.snapshot(source: session.source).text.hasPrefix("a*😀d"))
        session.undoManager.undo()
        #expect(session.source == source)
        session.undoManager.redo()
        #expect(session.source.contains("a\\*😀"))
    }

    @Test func escapedEntityMapping() {
        let source = "\\* 😀 &amp; e\u{301}"
        let snapshot = MarkdownRenderer.snapshot(source: source)
        #expect(snapshot.text == "* 😀 & e\u{301}")
        let shown = (snapshot.text as NSString).range(of: "&")
        #expect(snapshot.sourceMap.sourceRange(forDisplayedRange: shown) == (source as NSString).range(of: "&amp;"))
        let patches = snapshot.sourceMap.patches(forDisplayedRange: shown, replacement: "<", source: source)
        #expect(patches == [SourcePatch(range: (source as NSString).range(of: "&amp;"), replacement: "\\<")])
    }

    @Test func formattingToggleAndLinkPreserveSource() {
        let session = DocumentSession(source: "前 😀 后\n\n<!-- untouched -->")
        let selection = (session.source as NSString).range(of: "😀")
        #expect(session.perform(.bold, in: selection))
        #expect(session.source == "前 **😀** 后\n\n<!-- untouched -->")
        #expect(session.perform(.bold))
        #expect(session.source == "前 😀 后\n\n<!-- untouched -->")
        #expect(session.perform(.insertLink(destination: "https://example.com/a(b)?q=中文")))
        #expect(session.source == "前 [😀](<https://example.com/a(b)?q=中文>) 后\n\n<!-- untouched -->")
    }

    @Test func inlineCodeAndAllBlockCommands() {
        let session = DocumentSession(source: "a`b")
        #expect(session.perform(.inlineCode, in: NSRange(location: 0, length: 3)))
        #expect(session.source == "``a`b``")
        #expect(session.perform(.inlineCode))
        #expect(session.source == "a`b")
        for command in [FormattingCommand.heading(level: 2), .unorderedList, .orderedList, .taskList, .quote, .indent, .outdent] {
            let document = DocumentSession(source: "one\ntwo\n\nkeep")
            #expect(document.perform(command, in: NSRange(location: 0, length: 7)))
            #expect(document.source.hasSuffix("\n\nkeep"))
        }
        #expect(!session.perform(.heading(level: 7)))
    }

    @Test func tableCodeTasksAndImageRender() {
        let source = "- [x] done\n- [ ] next\n\n> **quote**\n\n```swift\nlet 😀 = 1\n```\n\n| 名 | 值 |\n| --- | --- |\n| 中 | 😀 |\n\n![alt](image.png)"
        let result = MarkdownRenderer.render(source: source)
        #expect(result.attributedString.string.contains("☑ done\n☐ next"))
        #expect(result.attributedString.string.contains("quote"))
        #expect(result.attributedString.string.contains("let 😀 = 1\n"))
        #expect(result.attributedString.string.contains("名\n值"))
        #expect(result.attributedString.string.contains("中\n😀"))
        #expect(result.segments.contains { $0.kind == .attachment })
        let image = result.segments.first { $0.kind == .attachment }!
        #expect(result.attributedString.attribute(.attachment, at: image.displayedNSRange.location, effectiveRange: nil) is NSTextAttachment)
        let cell = (result.attributedString.string as NSString).range(of: "中")
        let session = DocumentSession(source: source)
        session.renderNow()
        #expect(session.editRendered(range: cell, replacement: "文|字"))
        #expect(session.source.contains("| 文\\|字 | 😀 |"))
    }

    @Test func controllerModesNativeEditsAndSharedUndo() {
        let session = DocumentSession(source: "**😀ab** tail")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        #expect(controller.textView.string == "😀ab tail")
        controller.textView.setSelectedRange(NSRange(location: 2, length: 2))
        #expect(controller.selectedSourceRange() == NSRange(location: 4, length: 2))
        controller.mode = .source
        #expect(controller.textView.selectedRange() == NSRange(location: 4, length: 2))
        controller.mode = .richText
        #expect(controller.textView.selectedRange() == NSRange(location: 2, length: 2))
        controller.textView.insertText("*", replacementRange: controller.textView.selectedRange())
        #expect(session.source == "**😀\\*** tail")
        controller.textView.insertText("文", replacementRange: controller.textView.selectedRange())
        #expect(session.source == "**😀\\*文** tail")
        #expect(controller.textView.string == "😀*文 tail")
        controller.mode = .source
        #expect(controller.textView.string == session.source)
        session.undoManager.undo()
        #expect(session.source == "**😀ab** tail")
        #expect(controller.textView.string == session.source)
    }

    @Test func sourceEditAndReadonlyEntrypoints() {
        let session = DocumentSession(source: "abc")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        controller.mode = .source
        _ = controller.view
        controller.textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
        #expect(session.source == "# abc")
        controller.canEdit = false
        #expect(!controller.insertMarkdown("![x](a.png)"))
        #expect(!controller.perform(.bold))
        #expect(!session.replaceSource(in: NSRange(location: 0, length: 0), with: "bad"))
        controller.textView.insertText("bad", replacementRange: NSRange(location: 0, length: 0))
        #expect(session.source == "# abc")
        session.undoManager.undo()
        #expect(session.source == "# abc")
    }

    @Test(arguments: [false, true]) func quoteLineStartCompositionKeepsContainersAndPosition(attributed: Bool) throws {
        _ = NSApplication.shared
        let source = "Before\n\n> first\n>\n> second\n> continued\n>\n> > nested\n>\n> last\n\nAfter"
        for word in ["first", "second", "continued", "nested", "last"] {
            let session = DocumentSession(source: source)
            session.undoManager.groupsByEvent = false
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            let editor = controller.textView!
            let layout = try #require(editor.layoutManager)
            let container = try #require(editor.textContainer)
            let storage = try #require(editor.textStorage)
            let location = (editor.string as NSString).range(of: word).location
            editor.setSelectedRange(NSRange(location: location, length: 0))
            session.renderNow()
            let paragraph = try #require(storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
            let blocks = paragraph.textBlocks
            #expect(!blocks.isEmpty)
            layout.ensureLayout(for: container)
            let before = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
            session.undoManager.beginUndoGrouping()
            for marked in ["d", "di", "ding"] {
                let preedit: Any = attributed ? NSAttributedString(string: marked, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]) : marked
                editor.setMarkedText(preedit, selectedRange: NSRange(location: marked.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                #expect(session.source == source)
                #expect(editor.markedRange() == NSRange(location: location, length: marked.utf16.count))
                let current = try #require(storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
                #expect(current.textBlocks.count == blocks.count)
                #expect(zip(current.textBlocks, blocks).allSatisfy { $0 === $1 })
                layout.ensureLayout(for: container)
                let during = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
                #expect(abs(during.minX - before.minX) < 0.5)
                #expect(abs(during.minY - before.minY) < 0.5)
            }
            editor.insertText("顶", replacementRange: NSRange(location: NSNotFound, length: 0))
            session.undoManager.endUndoGrouping()
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: word, with: "顶" + word))
            #expect(editor.string.contains("顶" + word))
            editor.setSelectedRange(NSRange(location: location, length: 0))
            session.renderNow()
            session.undoManager.beginUndoGrouping()
            editor.insertText("x", replacementRange: editor.selectedRange())
            session.undoManager.endUndoGrouping()
            #expect(session.source == source.replacingOccurrences(of: word, with: "x顶" + word))
            let typed = try #require(storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
            #expect(typed.textBlocks.count == blocks.count)
            layout.ensureLayout(for: container)
            let after = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
            #expect(abs(after.minX - before.minX) < 0.5)
            #expect(abs(after.minY - before.minY) < 0.5)
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source.replacingOccurrences(of: word, with: "顶" + word))
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
            window.contentViewController = nil
        }
    }

    @Test func emptyMarkedTextDoesNotLeaveFormattingDisabled() throws {
        let source = "Before\n\n| A | B |\n| --- | --- |\n| one | two |"
        for mode in [EditorMode.richText, .source] {
            for preedit in ["", "拼"] {
                let session = DocumentSession(source: source)
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                controller.mode = mode
                let editor = controller.textView!
                let offset = (editor.string as NSString).range(of: "one").location
                editor.setSelectedRange(NSRange(location: offset, length: 0))
                if !preedit.isEmpty {
                    editor.setMarkedText(preedit, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    #expect(editor.isComposing && editor.hasMarkedText())
                    #expect(controller.formattingState(.tableDelete) == .unavailable)
                }
                editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                #expect(!editor.hasMarkedText())
                #expect(!editor.isComposing)
                #expect(controller.formattingState(.tableDelete) == .off)
                #expect(controller.formattingState(.bold) == .off)
                #expect(session.source == source)
            }
        }
    }

    @Test func compositionDoesNotRenderMarkedText() {
        let session = DocumentSession(source: "**ab**")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        #expect(session.source == "**ab**")
        session.renderNow()
        #expect(controller.textView.string == "a拼b")
        controller.textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(session.source == "**a中文b**")
    }

    @Test func backgroundGenerationDropsStaleResults() async {
        let session = DocumentSession(source: "# old")
        session.debounceNanoseconds = 0
        #expect(session.replaceSource(in: NSRange(location: 0, length: session.source.utf16.count), with: "**新😀**"))
        #expect(session.replaceSource(in: NSRange(location: 2, length: 1), with: "终"))
        await session.waitForRendering()
        #expect(session.renderSnapshot?.source == session.source)
        #expect(session.renderSnapshot?.text == "终😀")
        #expect(session.revision == 2)
    }

    @Test func clearFormattingRemovesEnclosingMarkersNotOtherSource() {
        let session = DocumentSession(source: "# **😀** and [label](dest)\n\n<!--keep-->")
        #expect(session.perform(.clearFormatting, in: (session.source as NSString).range(of: "😀")))
        #expect(session.source == "😀 and [label](dest)\n\n<!--keep-->")
        #expect(session.perform(.clearFormatting, in: (session.source as NSString).range(of: "label")))
        #expect(session.source == "😀 and label\n\n<!--keep-->")
    }

    @Test func nestedLineBreaksAndCodeLanguageMap() {
        let source = "> **中\n> 😀**\n\n- parent\n  - child\n\n```swift\nswift\n\n😀\n```\n"
        let snapshot = MarkdownRenderer.snapshot(source: source)
        #expect(snapshot.text.contains("中\n😀"))
        let emoji = (snapshot.text as NSString).range(of: "😀")
        #expect(snapshot.sourceMap.sourceRange(forDisplayedRange: emoji) == (source as NSString).range(of: "😀"))
        let swift = (snapshot.text as NSString).range(of: "swift")
        let codeSwift = (source as NSString).range(of: "swift", options: .backwards)
        #expect(snapshot.sourceMap.sourceRange(forDisplayedRange: swift) == codeSwift)
        let breaks = snapshot.sourceMap.segments.filter { $0.kind == .lineBreak && $0.sourceNSRange.length > 0 }
        #expect(breaks.allSatisfy { (source as NSString).substring(with: $0.sourceNSRange).contains("\n") })
    }

    @Test func literalReplacementCannotCreateEntityOrListMarkup() {
        let session = DocumentSession(source: "plain")
        session.renderNow()
        #expect(session.editRendered(range: NSRange(location: 0, length: 5), replacement: "&amp;\n- item"))
        #expect(MarkdownRenderer.snapshot(source: session.source).text == "&amp;\n- item")
    }

    @Test func emptyAndWhitespaceDocuments() {
        for source in ["", "\n\n", "  ", "\n\n# title"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            #expect(session.renderSnapshot?.source == source)
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            #expect(controller.insertMarkdown("![alt](image.png)"))
            #expect(session.renderSnapshot?.source == session.source)
            #expect(controller.textView.string == session.renderSnapshot?.text)
        }
    }

    @Test func quoteNewlineInsertionAndDeletionKeepNesting() {
        let session = DocumentSession(source: "> ab")
        session.renderNow()
        #expect(session.editRendered(range: NSRange(location: 1, length: 0), replacement: "\n"))
        #expect(session.source == "> a\n> b")
        session.renderNow()
        #expect(session.renderSnapshot?.text == "a\nb")
        #expect(session.editRendered(range: NSRange(location: 1, length: 1), replacement: ""))
        #expect(session.source == "> ab")
    }

    @Test func readonlySessionUpdatesControllerAndCancelsComposition() {
        let session = DocumentSession(source: "abc")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        session.canEdit = false
        #expect(!controller.textView.isEditable)
        #expect(!controller.textView.isComposing)
        #expect(!controller.textView.hasMarkedText())
        #expect(controller.textView.string == "abc")
        #expect(session.source == "abc")
    }

    @Test func CRLFMappingEditsWholeNewline() {
        let source = "中\r\n😀"
        let session = DocumentSession(source: source)
        session.renderNow()
        #expect(session.renderSnapshot?.text == "中\n😀")
        #expect(session.editRendered(range: NSRange(location: 1, length: 1), replacement: ""))
        #expect(session.source == "中😀")
    }

    @Test func emptyTableCellsAndStructuralProtection() {
        let session = DocumentSession(source: "|   |   |\n| --- | --- |\n|   |   |\n")
        session.renderNow()
        let snapshot = session.renderSnapshot!
        #expect(snapshot.tableCells.count == 4)
        #expect(session.editRendered(range: NSRange(location: 0, length: 1), replacement: "中文"))
        #expect(session.source.hasPrefix("|中文   |"))
        session.renderNow()
        let separator = session.renderSnapshot!.sourceMap.segments.first { $0.kind == .tableSeparator }!
        #expect(!session.editRendered(range: separator.displayedNSRange, replacement: ""))
    }

    @Test func pastedImageAndThumbnailKeepVisibleContentStable() async throws {
        @MainActor final class ScrollChanges {
            var origins: [CGFloat] = []
        }
        for delayedImage in [false, true] {
            let section = "## Heading\n\nParagraph **bold** and *italic* text.\n\n"
            let source = "![old](old.png)\n\n" + String(repeating: section, count: 40) + "Paste here\n\n" + String(repeating: section, count: 40)
            let session = DocumentSession(source: source)
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            let image = NSImage(size: NSSize(width: 720, height: 1000))
            if !delayedImage { controller.imageProvider = { _ in image } }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentViewController = nil }
            controller.view.layoutSubtreeIfNeeded()
            let editor = controller.textView!
            window.makeFirstResponder(editor)
            let layout = try #require(editor.layoutManager)
            let container = try #require(editor.textContainer)
            let scroll = try #require(editor.enclosingScrollView)
            let clip = scroll.contentView
            layout.ensureLayout(for: container)
            editor.sizeToFit()
            let insertion = (editor.string as NSString).range(of: "Paste here").location
            editor.setSelectedRange(NSRange(location: insertion, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: insertion)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            clip.scroll(to: NSPoint(x: 0, y: line.minY + editor.textContainerOrigin.y - 220))
            scroll.reflectScrolledClipView(clip)
            let origin = clip.bounds.minY
            let visibleGlyph = layout.glyphIndex(for: NSPoint(x: container.lineFragmentPadding, y: origin - editor.textContainerOrigin.y + 8), in: container)
            let anchor = layout.characterIndexForGlyph(at: visibleGlyph)
            func anchorPosition() -> CGFloat {
                layout.ensureLayout(for: container)
                editor.sizeToFit()
                let glyph = layout.glyphIndexForCharacter(at: anchor)
                return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + editor.textContainerOrigin.y - clip.bounds.minY
            }
            let position = anchorPosition()
            let changes = ScrollChanges()
            clip.postsBoundsChangedNotifications = true
            let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
                MainActor.assumeIsolated { changes.origins.append(clip.bounds.minY) }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            controller.onImportImages = { _, _ in
                let range = controller.selectedSourceRange()
                #expect(controller.insertMarkdown("![pasted](pasted.png)", in: range))
            }
            let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            defer { board.releaseGlobally() }
            board.setData(Data([1, 2, 3]), forType: .png)
            #expect(editor.readSelection(from: board, type: .png))
            #expect(session.renderSnapshot?.source == session.source)
            #expect(abs(anchorPosition() - position) < 1)
            #expect(changes.origins.allSatisfy { abs($0 - origin) < 1 })
            await session.waitForRendering()
            #expect(abs(anchorPosition() - position) < 1)
            changes.origins.removeAll()
            if delayedImage { controller.imageProvider = { _ in image } }
            let loadedOrigin = clip.bounds.minY
            #expect(abs(anchorPosition() - position) < 1)
            #expect(changes.origins.allSatisfy { abs($0 - origin) < 1 || abs($0 - loadedOrigin) < 1 })
            await Task.yield()
            #expect(abs(anchorPosition() - position) < 1)
            session.undoManager.undo()
            #expect(session.source == source)
            session.undoManager.redo()
            #expect(session.source.contains("![pasted](pasted.png)Paste here"))
        }
    }

    @Test func imagesUseImportHookAndReadonlyBlocksIt() {
        let session = DocumentSession(source: "")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        var imported: [URL] = []
        var importedData: Data?
        controller.onImportImages = { urls, data in imported = urls; importedData = data }
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let imageURL = URL(fileURLWithPath: "/tmp/测试.png")
        board.writeObjects([imageURL as NSURL])
        #expect(controller.textView.readSelection(from: board, type: .fileURL))
        #expect(imported == [imageURL])
        #expect(session.source.isEmpty)
        imported = []
        controller.canEdit = false
        #expect(!controller.textView.readSelection(from: board, type: .fileURL))
        #expect(imported.isEmpty)
        controller.canEdit = true
        board.clearContents()
        let data = Data([1, 2, 3])
        board.setData(data, forType: .png)
        #expect(controller.textView.readSelection(from: board, type: .png))
        #expect(importedData == data)
        board.releaseGlobally()
    }

    @Test func attachmentEditsAndDirtyNotifications() {
        let source = "![alt](image.png) tail"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        var changes: [String] = []
        controller.sourceUpdated = { changes.append($0) }
        controller.textView.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        #expect(session.source == "a" + source)
        #expect(changes == [session.source])
        session.renderNow()
        controller.textView.insertText("", replacementRange: NSRange(location: 1, length: 1))
        #expect(session.source == "a tail")
        #expect(controller.textView.undoManager == nil)
        session.undoManager.undo()
        #expect(session.source == source)
        #expect(changes.last == source)
    }

    @Test func modeChangeWaitsForCompositionCommit() {
        let session = DocumentSession(source: "**ab**")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        controller.mode = .source
        #expect(controller.mode == .richText)
        controller.textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(controller.mode == .source)
        #expect(controller.textView.string == "**a中文b**")
        #expect(controller.selectedSourceRange() == NSRange(location: 5, length: 0))
    }

    @Test func inlineFormattingAndBlockTogglesRoundTrip() {
        for command in [FormattingCommand.bold, .italic, .strikethrough, .inlineCode] {
            let session = DocumentSession(source: "😀 text")
            #expect(session.perform(command, in: NSRange(location: 0, length: 2)))
            #expect(session.perform(command))
            #expect(session.source == "😀 text")
        }
        for command in [FormattingCommand.heading(level: 3), .unorderedList, .orderedList, .taskList, .quote] {
            let session = DocumentSession(source: "first\nsecond")
            #expect(session.perform(command, in: NSRange(location: 0, length: session.source.utf16.count)))
            #expect(session.perform(command))
            #expect(session.source == "first\nsecond")
        }
        let session = DocumentSession(source: "")
        #expect(session.perform(.insertTable()))
        #expect(!MarkdownRenderer.snapshot(source: session.source).tableCells.isEmpty)
        #expect(session.perform(.insertImage(path: "a b.png"), in: NSRange(location: 0, length: 0)))
        #expect(session.source.hasPrefix("![](<a b.png>)"))
    }

    @Test func codeBlockTypingPreservesCodeAndProtectsFences() {
        let session = DocumentSession(source: "```swift\nlet text = \"a\"\n```\n")
        session.renderNow()
        #expect(session.editRendered(range: NSRange(location: 0, length: 0), replacement: "`*_"))
        #expect(session.source.hasPrefix("```swift\n`*_let"))
        session.renderNow()
        #expect(!session.editRendered(range: NSRange(location: 0, length: 0), replacement: "```\n"))
    }

    @Test func undoRestoresSelectionAcrossModes() {
        let session = DocumentSession(source: "**😀ab** tail")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.setSelectedRange(NSRange(location: 2, length: 2))
        controller.textView.insertText("中", replacementRange: controller.textView.selectedRange())
        controller.mode = .source
        session.undoManager.undo()
        #expect(controller.textView.selectedRange() == NSRange(location: 4, length: 2))
        session.renderNow()
        controller.mode = .richText
        #expect(controller.textView.selectedRange() == NSRange(location: 2, length: 2))
        #expect(controller.textView.isRichText)
        controller.mode = .source
        #expect(!controller.textView.isRichText)
    }

    @Test func deletingWholeFormattedContentDoesNotRevealEmptyMarkup() {
        for source in ["**abc**", "*abc*", "~~abc~~", "`abc`", "[abc](destination)", "# abc", "**_abc_**"] {
            let session = DocumentSession(source: source)
            session.renderNow()
            #expect(session.editRendered(range: NSRange(location: 0, length: 3), replacement: ""))
            #expect(session.source.isEmpty)
            #expect(MarkdownRenderer.snapshot(source: session.source).text.isEmpty)
        }
    }

    @Test func consecutiveNativeDeletesCleanContainersBeforeBackgroundParse() {
        let session = DocumentSession(source: "**abc** tail")
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        _ = controller.view
        controller.textView.insertText("", replacementRange: NSRange(location: 0, length: 1))
        #expect(session.source == "**bc** tail")
        controller.textView.insertText("", replacementRange: NSRange(location: 0, length: 2))
        #expect(session.source == " tail")
        #expect(controller.textView.string == " tail")
        session.undoManager.undo()
        #expect(session.source == "**abc** tail")
    }
}