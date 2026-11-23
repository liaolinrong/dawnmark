import AppKit
import Testing
import MarkdownEngine
import EditorKit

@Suite(.serialized) @MainActor struct TableRenderingTests {
    @Test(arguments: [false, true]) func paintedHorizontalTableBordersKeepClickedColumn(fullDocument: Bool) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source: String
        if fullDocument {
            source = try String(contentsOf: root.appendingPathComponent("TestDoc/测试文档/测试文档.md"), encoding: .utf8)
        } else {
            source = "| | | |\n| --- | --- | --- |\n| | | |\n| | | |"
        }
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        editor.appearance = NSAppearance(named: .aqua)
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let storage = try #require(editor.textStorage)
        layout.ensureLayout(for: container)
        let cells = try #require(session.renderSnapshot?.tableCells)
        for cell in cells {
            guard let lower = cells.first(where: { $0.table == cell.table && $0.row == cell.row + 1 && $0.column == cell.column }) else { continue }
            let paragraph = try #require(storage.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle)
            let block = try #require(paragraph.textBlocks.compactMap { $0 as? NSTextTableBlock }.last)
            let frame = layout.boundsRect(for: block, at: layout.glyphIndexForCharacter(at: cell.range.location), effectiveRange: nil)
                .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            let strip = NSRect(x: floor(frame.midX) - 2, y: floor(frame.maxY) - 12, width: 4, height: 24)
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: strip))
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
            var brightness: [CGFloat] = []
            for vertical in 0..<bitmap.pixelsHigh {
                let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: vertical)?.usingColorSpace(.deviceRGB))
                brightness.append(min(color.redComponent, color.greenComponent, color.blueComponent))
            }
            let darkest = try #require(brightness.min())
            #expect(darkest < 0.98)
            let pixels = brightness.indices.filter { brightness[$0] <= darkest + 0.005 }
            #expect(!pixels.isEmpty)
            let first = try #require(pixels.first)
            let last = try #require(pixels.last)
            let border = strip.minY + CGFloat(first + last + 1) / 2 * strip.height / CGFloat(bitmap.pixelsHigh)
            editor.scrollRangeToVisible(cell.range)
            for (delta, targetRow) in [(-2.0, cell.row), (-0.25, cell.row), (0.25, lower.row), (2.0, lower.row)] {
                let point = NSPoint(x: frame.midX, y: border + delta)
                let offset = editor.characterIndexForInsertion(at: point)
                let target = try #require(cells.first { $0.table == cell.table && $0.row == targetRow && $0.column == cell.column })
                #expect(offset >= target.range.location && offset < NSMaxRange(target.range), "row=\(targetRow) column=\(cell.column) pixelBorder=\(border) frameBottom=\(frame.maxY) offset=\(offset)")
                let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                editor.mouseDown(with: event)
                #expect(editor.selectedRange() == NSRange(location: offset, length: 0))
                let caret = editor.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)), from: nil)
                let targetParagraph = try #require(storage.attribute(.paragraphStyle, at: target.range.location, effectiveRange: nil) as? NSParagraphStyle)
                let targetBlock = try #require(targetParagraph.textBlocks.compactMap { $0 as? NSTextTableBlock }.last)
                let targetFrame = layout.boundsRect(for: targetBlock, at: layout.glyphIndexForCharacter(at: target.range.location), effectiveRange: nil)
                    .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                #expect(targetFrame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: caret.midX, y: caret.midY)), "table=\(cell.table) row=\(targetRow) column=\(cell.column) caret=\(caret) target=\(targetFrame) offset=\(offset)")
            }
        }
    }

    @Test func horizontalTableBorderClicksKeepColumnAndChooseNearestRow() throws {
        for width in [480, 900] {
            for (prefix, newline, content) in [("", "\n", ""), ("", "\n", "one"), ("> ", "\r\n", String(repeating: "Long wrapped text 中文 ", count: 20))] {
                let rows = content.isEmpty ? Array(repeating: "| | | |", count: 3) : ["| A | B | C |", "| \(content) | two | three |", "| four | five | six |"]
                let source = ([rows[0], "| --- | --- | --- |"] + rows.dropFirst()).map { prefix + $0 }.joined(separator: newline)
                let session = DocumentSession(source: source)
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentViewController = controller
                defer { window.contentViewController = nil }
                controller.view.layoutSubtreeIfNeeded()
                let editor = controller.textView!
                let layout = try #require(editor.layoutManager)
                let container = try #require(editor.textContainer)
                let storage = try #require(editor.textStorage)
                layout.ensureLayout(for: container)
                let cells = try #require(session.renderSnapshot?.tableCells)
                func bounds(for cell: TableCellSnapshot) throws -> NSRect {
                    let paragraph = try #require(storage.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle)
                    let block = try #require(paragraph.textBlocks.compactMap { $0 as? NSTextTableBlock }.last)
                    return layout.boundsRect(for: block, at: layout.glyphIndexForCharacter(at: cell.range.location), effectiveRange: nil)
                }
                for upper in cells where upper.row < 2 {
                    let lower = try #require(cells.first { $0.row == upper.row + 1 && $0.column == upper.column })
                    let upperBounds = try bounds(for: upper)
                    let lowerBounds = try bounds(for: lower)
                    let border = (upperBounds.maxY + lowerBounds.minY) / 2
                    for (vertical, expected) in [(border - 0.25, upper), (border, upper), (border + 0.25, lower)] {
                        let point = NSPoint(x: upperBounds.midX + editor.textContainerOrigin.x, y: vertical + editor.textContainerOrigin.y)
                        let offset = editor.characterIndexForInsertion(at: point)
                        #expect(offset >= expected.range.location && offset < NSMaxRange(expected.range), "row=\(expected.row) column=\(expected.column) offset=\(offset) expected=\(expected.range)")
                        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                        editor.mouseDown(with: event)
                        #expect(editor.selectedRange() == NSRange(location: offset, length: 0))
                        #expect(controller.formattingState(.tableDelete) == .off)
                    }
                }
                for cell in cells where cell.row == 0 || cell.row == 2 {
                    let frame = try bounds(for: cell)
                    let vertical = cell.row == 0 ? frame.minY : frame.maxY
                    let point = NSPoint(x: frame.midX + editor.textContainerOrigin.x, y: vertical + editor.textContainerOrigin.y)
                    let offset = editor.characterIndexForInsertion(at: point)
                    #expect(offset >= cell.range.location && offset < NSMaxRange(cell.range))
                }
                #expect(session.source == source)
            }
        }
    }

    @Test func horizontalTableBorderClickTypesIntoTargetCellAndSupportsUndo() throws {
        let source = "| A | B | C |\n| --- | --- | --- |\n| one | two | three |\n| four | five | six |"
        for below in [false, true] {
            let session = DocumentSession(source: source)
            session.undoManager.groupsByEvent = false
            session.renderNow()
            let controller = MarkdownEditorController(session: session)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            defer { window.contentViewController = nil }
            controller.view.layoutSubtreeIfNeeded()
            let editor = controller.textView!
            let layout = try #require(editor.layoutManager)
            let storage = try #require(editor.textStorage)
            layout.ensureLayout(for: try #require(editor.textContainer))
            let cells = try #require(session.renderSnapshot?.tableCells)
            func frame(row: Int) throws -> NSRect {
                let cell = try #require(cells.first { $0.row == row && $0.column == 1 })
                let paragraph = try #require(storage.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle)
                let block = try #require(paragraph.textBlocks.compactMap { $0 as? NSTextTableBlock }.last)
                return layout.boundsRect(for: block, at: layout.glyphIndexForCharacter(at: cell.range.location), effectiveRange: nil)
            }
            let upper = try frame(row: 1)
            let lower = try frame(row: 2)
            let border = (upper.maxY + lower.minY) / 2
            let point = NSPoint(x: upper.midX + editor.textContainerOrigin.x, y: border + (below ? 2 : -2) + editor.textContainerOrigin.y)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            editor.mouseDown(with: event)
            let originalSelection = editor.selectedRange()
            let target = try #require(cells.first { $0.row == (below ? 2 : 1) && $0.column == 1 })
            session.undoManager.beginUndoGrouping()
            editor.insertText("X", replacementRange: editor.selectedRange())
            session.undoManager.endUndoGrouping()
            session.renderNow()
            let updated = try #require(session.renderSnapshot?.tableCells.first { $0.row == target.row && $0.column == target.column })
            #expect((session.renderSnapshot!.text as NSString).substring(with: updated.range).contains("X"))
            #expect(session.renderSnapshot!.tableCells.filter { cell in
                (session.renderSnapshot!.text as NSString).substring(with: cell.range).contains("X")
            }.count == 1)
            session.undoManager.undo()
            #expect(session.source == source)
            #expect(editor.selectedRange() == originalSelection)
            session.undoManager.redo()
            #expect(session.source.contains("X"))
        }
    }

    @Test func nativeTableClicksInFullDocumentKeepTableCommandsAvailable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TestDoc/测试文档/测试文档.md"), encoding: .utf8)
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let storage = try #require(editor.textStorage)
        layout.ensureLayout(for: container)
        let cells = try #require(session.renderSnapshot?.tableCells)
        #expect(!cells.isEmpty)
        for cell in cells {
            let paragraph = try #require(storage.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle)
            let block = try #require(paragraph.textBlocks.compactMap { $0 as? NSTextTableBlock }.last)
            let glyph = layout.glyphIndexForCharacter(at: cell.range.location)
            let bounds = layout.boundsRect(for: block, at: glyph, effectiveRange: nil)
            for horizontal in [bounds.minX + 1, bounds.midX, bounds.maxX - 1] {
                let point = NSPoint(x: horizontal + editor.textContainerOrigin.x, y: bounds.midY + editor.textContainerOrigin.y)
                let offset = editor.characterIndexForInsertion(at: point)
                editor.setSelectedRange(NSRange(location: offset, length: 0))
                #expect(controller.formattingState(.tableDelete) == .off, "table=\(cell.table) row=\(cell.row) column=\(cell.column) displayed=\(offset) source=\(controller.selectedSourceRange())")
            }
        }
        #expect(session.source == source)
    }

    @Test func insertedColumnKeepsCaretInNewCell() throws {
        let fixtures = [
            [[" A ", " B ", " C "], [" one ", " two ", " three "], [" 中文😀 ", " five ", " six "]],
            Array(repeating: Array(repeating: "   ", count: 3), count: 3)
        ]
        for rows in fixtures {
            for (prefix, newline) in [("", "\n"), ("> ", "\r\n")] {
                func lines(for cells: [[String]]) -> [String] {
                    var lines = cells.map { prefix + "|" + $0.joined(separator: "|") + "|" }
                    lines.insert(prefix + "|" + Array(repeating: " --- ", count: cells[0].count).joined(separator: "|") + "|", at: 1)
                    return lines
                }
                let sourceLines = lines(for: rows)
                let source = sourceLines.joined(separator: newline)
                for mode in [EditorMode.richText, .source] {
                    for rowIndex in rows.indices {
                        for column in rows[rowIndex].indices {
                            for before in [false, true] {
                                let session = DocumentSession(source: source)
                                session.undoManager.groupsByEvent = false
                                session.renderNow()
                                let controller = MarkdownEditorController(session: session)
                                _ = controller.view
                                controller.mode = mode
                                let physicalRow = rowIndex == 0 ? 0 : rowIndex + 1
                                let rowStart = sourceLines.prefix(physicalRow).reduce(0) { $0 + $1.utf16.count + newline.utf16.count }
                                let targetOffset = rowStart + prefix.utf16.count + 1 + rows[rowIndex].prefix(column).reduce(0) { $0 + $1.utf16.count + 1 }
                                let target = NSRange(location: targetOffset, length: 0)
                                let command: FormattingCommand = before ? .tableInsertColumnBefore : .tableInsertColumn
                                session.undoManager.beginUndoGrouping()
                                if column == 1 {
                                    controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
                                    #expect(controller.perform(command, inSourceRange: target))
                                } else {
                                    let offset = mode == .source ? targetOffset : session.renderSnapshot!.sourceMap.displayedOffset(forSourceOffset: targetOffset)
                                    controller.textView.setSelectedRange(NSRange(location: offset, length: 0))
                                    #expect(controller.perform(command))
                                }
                                session.undoManager.endUndoGrouping()
                                let insertedColumn = column + (before ? 0 : 1)
                                var expectedRows = rows.map { cells -> [String] in
                                    var result = cells
                                    result.insert("   ", at: insertedColumn)
                                    return result
                                }
                                let expectedLines = lines(for: expectedRows)
                                let insertedSource = expectedLines.joined(separator: newline)
                                #expect(session.source == insertedSource)
                                let snapshot = try #require(session.renderSnapshot)
                                let cell = try #require(snapshot.tableCells.first { $0.row == rowIndex && $0.column == insertedColumn })
                                let expectedRowStart = expectedLines.prefix(physicalRow).reduce(0) { $0 + $1.utf16.count + newline.utf16.count }
                                let sourceCaret = expectedRowStart + prefix.utf16.count + 1 + expectedRows[rowIndex].prefix(insertedColumn).reduce(0) { $0 + $1.utf16.count + 1 }
                                let displayedCaret = mode == .source ? sourceCaret : cell.range.location
                                let selection = NSRange(location: displayedCaret, length: 0)
                                #expect(controller.textView.selectedRange() == selection)
                                session.undoManager.beginUndoGrouping()
                                controller.textView.insertText("New", replacementRange: controller.textView.selectedRange())
                                session.undoManager.endUndoGrouping()
                                expectedRows[rowIndex][insertedColumn] = "New   "
                                let typedSource = lines(for: expectedRows).joined(separator: newline)
                                #expect(session.source == typedSource)
                                session.undoManager.undo()
                                #expect(session.source == insertedSource)
                                #expect(controller.textView.selectedRange() == selection)
                                session.undoManager.undo()
                                #expect(session.source == source)
                                session.undoManager.redo()
                                #expect(session.source == insertedSource)
                                #expect(controller.textView.selectedRange() == selection)
                                session.undoManager.redo()
                                #expect(session.source == typedSource)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func tableContextCommandsTargetClickedTableInBothModes() throws {
        let source = "Outside\n\n| A | B |\n| --- | --- |\n| one | two |\n\nMiddle\n\n| C | D |\n| --- | --- |\n| three | four |\n\nAfter"
        let target = (source as NSString).range(of: "four")
        let commands: [FormattingCommand] = [.tableInsertRowAbove, .tableInsertRow, .tableDeleteRow, .tableInsertColumnBefore, .tableInsertColumn, .tableDeleteColumn, .tableDelete]
        for mode in [EditorMode.richText, .source] {
            for command in commands {
                let expected = DocumentSession(source: source)
                #expect(expected.perform(command, in: target))
                let session = DocumentSession(source: source)
                session.undoManager.groupsByEvent = false
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                controller.mode = mode
                controller.textView.setSelectedRange(NSRange(location: 0, length: 3))
                #expect(controller.formattingState(command) == .unavailable)
                session.undoManager.beginUndoGrouping()
                #expect(controller.perform(command, inSourceRange: target))
                session.undoManager.endUndoGrouping()
                #expect(session.source == expected.source)
                #expect(session.renderSnapshot?.source == session.source)
                #expect(session.source.hasPrefix("Outside\n\n| A | B |\n| --- | --- |\n| one | two |\n\nMiddle\n\n"))
                #expect(session.source.hasSuffix("\nAfter"))
                session.undoManager.undo()
                #expect(session.source == source)
                session.undoManager.redo()
                #expect(session.source == expected.source)
                controller.canEdit = false
                #expect(!controller.perform(command, inSourceRange: target))
                #expect(session.source == expected.source)
            }
        }
    }

    @Test func tableContextMenuHitsEmptyCellsWithoutMovingSelection() throws {
        for width in [480, 900] {
            for prefix in ["", "> "] {
                let source = "Before\n\n" + ["| | |", "| --- | --- |", "| | |"].map { prefix + $0 }.joined(separator: "\n") + "\n\nAfter"
                let session = DocumentSession(source: source)
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentViewController = controller
                defer { window.contentViewController = nil }
                controller.view.layoutSubtreeIfNeeded()
                let editor = controller.textView!
                let layout = try #require(editor.layoutManager)
                let container = try #require(editor.textContainer)
                let storage = try #require(editor.textStorage)
                layout.ensureLayout(for: container)
                let originalSelection = NSRange(location: 0, length: 3)
                editor.setSelectedRange(originalSelection)
                var hits: [NSRange] = []
                controller.tableMenu = { range in
                    hits.append(range)
                    return NSMenu(title: "Table context")
                }
                for editable in [true, false] {
                    controller.canEdit = editable
                    for cell in try #require(session.renderSnapshot?.tableCells) {
                        let paragraph = try #require(storage.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle)
                        let block = try #require(paragraph.textBlocks.compactMap { $0 as? NSTextTableBlock }.last)
                        let glyph = layout.glyphIndexForCharacter(at: cell.range.location)
                        let bounds = layout.boundsRect(for: block, at: glyph, effectiveRange: nil)
                        for horizontal in [bounds.minX + 1, bounds.midX, bounds.maxX - 1] {
                            let point = NSPoint(x: horizontal + editor.textContainerOrigin.x, y: bounds.midY + editor.textContainerOrigin.y)
                            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                            let previousHits = hits.count
                            #expect(editor.menu(for: event)?.title == "Table context")
                            #expect(hits.count == previousHits + 1)
                            let hit = try #require(hits.last)
                            #expect(session.tableRange(in: hit) != nil)
                            #expect(session.formattingState(.tableDeleteRow, in: hit) == (editable && cell.row > 0 ? .off : .unavailable))
                            #expect(editor.selectedRange() == originalSelection)
                            #expect(session.source == source)
                        }
                    }
                }
            }
        }
    }

    @Test func insertedTableRowCountIncludesHeader() throws {
        for mode in [EditorMode.richText, .source] {
            for rows in [1, 2, 3, 100] {
                let session = DocumentSession()
                session.undoManager.groupsByEvent = false
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                _ = controller.view
                controller.mode = mode
                session.undoManager.beginUndoGrouping()
                #expect(controller.perform(.insertTable(columns: 3, rows: rows)))
                session.undoManager.endUndoGrouping()
                let inserted = session.source
                let cells = try #require(session.renderSnapshot?.tableCells)
                #expect(cells.count == rows * 3)
                #expect(Set(cells.map(\.row)) == Set(0..<rows))
                #expect(cells.filter { $0.row == 0 }.count == 3)
                if mode == .richText {
                    controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
                    controller.view.layoutSubtreeIfNeeded()
                    let layout = try #require(controller.textView.layoutManager as? TableLayoutManager)
                    let container = try #require(controller.textView.textContainer)
                    #expect(layout.tableRows(in: container).count == rows)
                }
                session.undoManager.undo()
                #expect(session.source.isEmpty)
                session.undoManager.redo()
                #expect(session.source == inserted)
                #expect(session.renderSnapshot?.tableCells.count == rows * 3)
            }
        }
    }

    @Test func horizontalBordersSurviveBackgroundOnlyRedraw() throws {
        for width in [600, 1400] {
            for prefix in ["", "> "] {
                let lines = ["| | | |", "| --- | --- | --- |"] + Array(repeating: "| | | |", count: 4)
                let source = lines.map { prefix + $0 }.joined(separator: "\n")
                let session = DocumentSession(source: source)
                session.renderNow()
                let controller = MarkdownEditorController(session: session)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentViewController = controller
                defer { window.contentViewController = nil }
                controller.view.layoutSubtreeIfNeeded()
                let editor = controller.textView!
                editor.appearance = NSAppearance(named: .aqua)
                let layout = try #require(editor.layoutManager)
                let container = try #require(editor.textContainer)
                let storage = try #require(editor.textStorage)
                layout.ensureLayout(for: container)
                let referenceStorage = NSTextStorage(attributedString: storage)
                let referenceLayout = NSLayoutManager()
                let referenceContainer = NSTextContainer(containerSize: container.size)
                referenceContainer.lineFragmentPadding = container.lineFragmentPadding
                referenceContainer.widthTracksTextView = false
                referenceStorage.addLayoutManager(referenceLayout)
                referenceLayout.addTextContainer(referenceContainer)
                let reference = NSTextView(frame: editor.bounds, textContainer: referenceContainer)
                reference.textContainerInset = editor.textContainerInset
                reference.appearance = editor.appearance
                referenceLayout.ensureLayout(for: referenceContainer)
                let cells = try #require(session.renderSnapshot?.tableCells)
                #expect(cells.count == 15)
                for cell in cells where cell.row > 0 {
                    let paragraph = try #require(storage.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle)
                    let block = try #require(paragraph.textBlocks.compactMap { $0 as? NSTextTableBlock }.last)
                    let glyph = layout.glyphIndexForCharacter(at: cell.range.location)
                    let bounds = layout.boundsRect(for: block, at: glyph, effectiveRange: nil)
                        .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    let strip = NSRect(x: bounds.midX - 10, y: floor(bounds.maxY) - 12, width: 20, height: 24)
                    func borderPixels(backgroundOnly: Bool, view: NSTextView) throws -> Set<Int> {
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: strip))
                        if backgroundOnly {
                            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
                            NSGraphicsContext.saveGraphicsState()
                            NSGraphicsContext.current = context
                            context.cgContext.concatenate(context.cgContext.ctm.inverted())
                            let scaleX = CGFloat(bitmap.pixelsWide) / strip.width
                            let scaleY = CGFloat(bitmap.pixelsHigh) / strip.height
                            context.cgContext.translateBy(x: -strip.minX * scaleX, y: CGFloat(bitmap.pixelsHigh) + strip.minY * scaleY)
                            context.cgContext.scaleBy(x: scaleX, y: -scaleY)
                            view.drawBackground(in: strip)
                            NSGraphicsContext.restoreGraphicsState()
                        } else {
                            view.cacheDisplay(in: strip, to: bitmap)
                        }
                        var pixels: Set<Int> = []
                        for vertical in 0..<bitmap.pixelsHigh {
                            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: vertical)?.usingColorSpace(.deviceRGB))
                            if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.98 { pixels.insert(vertical) }
                        }
                        return pixels
                    }
                    let nativePixels = try borderPixels(backgroundOnly: false, view: reference)
                    #expect(!nativePixels.isEmpty)
                    #expect(try borderPixels(backgroundOnly: false, view: editor) == nativePixels)
                    #expect(try borderPixels(backgroundOnly: true, view: editor) == nativePixels)
                }
                #expect(session.source == source)
            }
        }
    }

    @Test func insertedEmptyTableCanBeDeletedFromAnyCell() throws {
        for cellIndex in 0..<4 {
            let session = DocumentSession()
            session.undoManager.groupsByEvent = false
            session.undoManager.beginUndoGrouping()
            #expect(session.perform(.insertTable(columns: 2, rows: 2)))
            session.undoManager.endUndoGrouping()
            session.renderNow()
            let source = session.source
            let controller = MarkdownEditorController(session: session)
            _ = controller.view
            let cell = try #require(session.renderSnapshot?.tableCells[cellIndex])
            controller.textView.setSelectedRange(NSRange(location: cell.range.location, length: 0))
            #expect(controller.formattingState(.tableDelete) == .off)
            session.undoManager.beginUndoGrouping()
            #expect(controller.perform(.tableDelete))
            session.undoManager.endUndoGrouping()
            #expect(session.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(session.renderSnapshot?.tableCells.isEmpty == true)
            session.undoManager.undo()
            session.renderNow()
            #expect(session.source == source)
            #expect(session.renderSnapshot?.tableCells.count == 4)
            session.undoManager.redo()
            session.renderNow()
            #expect(session.renderSnapshot?.tableCells.isEmpty == true)
        }
    }

    @Test func deleteTableRemovesWholeTableAndSupportsUndo() throws {
        for mode in [EditorMode.richText, .source] {
            for prefix in ["", "> "] {
                for newline in ["\n", "\r\n"] {
                    let table = ["| Name | Value |", "| --- | --- |", "| one | two |"].map { prefix + $0 }.joined(separator: newline)
                    let source = "Before" + newline + newline + table + newline + newline + "After"
                    let session = DocumentSession(source: source)
                    session.undoManager.groupsByEvent = false
                    session.renderNow()
                    let controller = MarkdownEditorController(session: session)
                    _ = controller.view
                    controller.mode = mode
                    #expect(controller.formattingState(.tableDelete) == .unavailable)
                    #expect(!controller.perform(.tableDelete))
                    let sourceCaret = NSRange(location: (source as NSString).range(of: "Name").location, length: 0)
                    let caret = mode == .source ? sourceCaret : session.renderSnapshot!.sourceMap.displayedRange(forSourceRange: sourceCaret)
                    controller.textView.setSelectedRange(caret)
                    #expect(controller.formattingState(.tableDelete) == .off)
                    session.undoManager.beginUndoGrouping()
                    #expect(controller.perform(.tableDelete))
                    session.undoManager.endUndoGrouping()
                    #expect(session.source == "Before" + newline + newline + newline + "After")
                    #expect(session.renderSnapshot?.tableCells.isEmpty == true)
                    #expect(controller.textView.selectedRange().location <= controller.textView.string.utf16.count)
                    session.undoManager.undo()
                    session.renderNow()
                    #expect(session.source == source)
                    #expect(session.renderSnapshot?.tableCells.count == 4)
                    controller.canEdit = false
                    #expect(!controller.perform(.tableDelete))
                    #expect(session.source == source)
                }
            }
        }
    }

    @Test func columnsFitContentAndCellsWrapWithinTheirOwnColumn() throws {
        let longText = String(repeating: "很长的单元格内容", count: 12)
        let english = String(repeating: "abcdefghij", count: 15)
        let source = "| ID | Description | Other |\n| --- | --- | --- |\n| 1 | \(longText) | \(english) |\n\nAfter table"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        let layout = try #require(controller.textView.layoutManager as? TableLayoutManager)
        let container = try #require(controller.textView.textContainer)
        let rows = layout.tableRows(in: container)
        #expect(rows.count == 2)
        #expect(rows[0].columnWidths[0] < rows[0].columnWidths[1])
        #expect(rows[0].columnWidths[0] < rows[0].columnWidths[2])
        #expect(rows[0].columnWidths.reduce(0, +) <= container.size.width)
        #expect(rows[1].bounds.height > rows[0].bounds.height)
        let snapshot = try #require(session.renderSnapshot)
        for cell in snapshot.tableCells where cell.row == 1 && cell.column > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: cell.range, actualCharacterRange: nil)
            var fragments: [NSRect] = []
            layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in fragments.append(used) }
            #expect(fragments.count > 1)
            #expect(fragments.allSatisfy { $0.width <= rows[1].columnWidths[cell.column] + 1 })
        }
        controller.textView.setFrameSize(NSSize(width: 260, height: 600))
        let narrow = layout.tableRows(in: container)
        #expect(narrow[1].bounds.height > rows[1].bounds.height)
        #expect(narrow[0].columnWidths[0] == rows[0].columnWidths[0])
        #expect(session.source == source)
        let displayed = (controller.textView.string as NSString).range(of: longText)
        controller.textView.insertText("Changed", replacementRange: NSRange(location: displayed.location, length: 1))
        session.renderNow()
        #expect(session.source.contains("| Changed"))
        session.undoManager.undo()
        #expect(session.source == source)
    }

    @Test func widthAllocationPreservesShortColumnsBeforeCompressingLongOnes() {
        #expect(TableLayoutManager.columnWidths(preferred: [30, 400, 40], available: 300) == [30, 230, 40])
        #expect(TableLayoutManager.columnWidths(preferred: [30, 40], available: 300) == [145, 155])
        #expect(TableLayoutManager.columnWidths(preferred: [400, 500], available: 300) == [150, 150])
    }

    @Test func insertedEmptyTableHasVisibleGridAndEditableCells() {
        let session = DocumentSession()
        #expect(session.perform(.insertTable(columns: 2, rows: 2)))
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let layout = controller.textView.layoutManager as! TableLayoutManager
        let rows = layout.tableRows(in: controller.textView.textContainer!)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.columns == 2 && $0.bounds.width > 0 && $0.bounds.height >= 28 })
        let container = controller.textView.textContainer!
        #expect(rows.allSatisfy { abs($0.bounds.width - (container.size.width - 2 * container.lineFragmentPadding)) < 1 })
        #expect(rows.first?.isHeader == true)
        #expect(rows.dropFirst().allSatisfy { !$0.isHeader })
        let source = session.source
        controller.textView.setFrameSize(NSSize(width: 180, height: 400))
        let narrowRows = layout.tableRows(in: controller.textView.textContainer!)
        #expect(narrowRows.first!.bounds.width <= controller.textView.textContainer!.size.width)
        #expect(narrowRows.allSatisfy { abs($0.bounds.width - (container.size.width - 2 * container.lineFragmentPadding)) < 1 })
        #expect(session.source == source)
        let cell = session.renderSnapshot!.sourceMap.segments.first { $0.kind == .text && $0.displayedNSRange.length > 0 }!
        #expect(session.editRendered(range: NSRange(location: cell.displayedNSRange.location, length: 0), replacement: "Name"))
        #expect(session.source.contains("Name"))
    }
}