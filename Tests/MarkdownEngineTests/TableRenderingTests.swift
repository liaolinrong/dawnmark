import AppKit
import Testing
import MarkdownEngine
import EditorKit

@Suite(.serialized) @MainActor struct TableRenderingTests {
    @Test func insertedEmptyTableCanBeDeletedFromAnyCell() throws {
        for cellIndex in 0..<6 {
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
            #expect(session.renderSnapshot?.tableCells.count == 6)
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
        #expect(rows.count == 3)
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