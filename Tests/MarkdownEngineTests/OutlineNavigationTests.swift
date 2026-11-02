import AppKit
import Testing
import MarkdownEngine
import EditorKit

@Suite(.serialized) @MainActor struct OutlineNavigationTests {
    @Test func outlineIndentationFollowsHeadingLevelWhenLevelsAreSkipped() throws {
        let source = "# 哈哈哈\n\n### 好事\n### 没问题\n\n## 概要设计\n\n### 小节\n\n# 末尾\n"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let tree = controller.outlineSidebar.outlineView
        tree.layoutSubtreeIfNeeded()
        func labelX(_ row: Int) throws -> CGFloat {
            let cell = try #require(tree.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
            cell.layoutSubtreeIfNeeded()
            let label = try #require(cell.textField)
            return tree.convert(label.frame.origin, from: cell).x
        }
        let x = try (0..<tree.numberOfRows).map(labelX)
        #expect(x.count == 6)
        let step = tree.indentationPerLevel
        #expect(abs(x[1] - x[0] - 2 * step) < 0.5)
        #expect(x[2] == x[1])
        #expect(abs(x[3] - x[0] - step) < 0.5)
        #expect(x[4] == x[1])
        #expect(x[5] == x[0])
    }

    @Test func sidebarHierarchyNavigationAndAutomaticVisibility() throws {
        let source = "# First\n\n### Child\n\n## Sibling\n\n# Last\n"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let sidebar = controller.outlineSidebar
        #expect(!sidebar.isHidden)
        #expect(sidebar.frame.width == 200)
        let split = try #require(controller.view as? NSSplitView)
        #expect(controller.textView.enclosingScrollView?.frame.width == 400 - split.dividerThickness)
        let tree = sidebar.outlineView
        #expect(tree.numberOfRows == 4)
        #expect((0..<4).map { tree.level(forRow: $0) } == [0, 1, 1, 0])
        let first = try #require(tree.item(atRow: 0))
        tree.collapseItem(first)
        #expect(tree.numberOfRows == 2)
        sidebar.update(headings: MarkdownRenderer.snapshot(source: source + "\n## Added").headings)
        #expect(tree.numberOfRows == 3)
        sidebar.update(headings: session.renderSnapshot!.headings)
        #expect(tree.numberOfRows == 2)
        let restoredFirst = try #require(tree.item(atRow: 0))
        tree.expandItem(restoredFirst)
        session.canEdit = false
        let headings = try #require(session.renderSnapshot).headings
        for mode in [EditorMode.source, .richText] {
            controller.mode = mode
            tree.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
            #expect(controller.textView.selectedRange().location == (mode == .source ? headings[3].sourceRange.location : headings[3].displayedRange.location))
            #expect(session.source == source)
            controller.textView.setSelectedRange(NSRange(location: controller.textView.selectedRange().location + 1, length: 0))
            #expect(NSApp.sendAction(try #require(tree.action), to: tree.target, from: tree))
            #expect(controller.textView.selectedRange().location == (mode == .source ? headings[3].sourceRange.location : headings[3].displayedRange.location))
            tree.deselectAll(nil)
        }
        session.canEdit = true
        #expect(session.replaceSource(in: NSRange(location: 0, length: source.utf16.count), with: "Plain text"))
        #expect(!controller.navigate(to: headings[0]))
        session.renderNow()
        controller.view.layoutSubtreeIfNeeded()
        #expect(sidebar.isHidden)
        #expect(controller.textView.enclosingScrollView?.frame.width == 600)
        #expect(session.replaceSource(in: NSRange(location: 0, length: session.source.utf16.count), with: "## New title"))
        session.renderNow()
        controller.view.layoutSubtreeIfNeeded()
        #expect(!sidebar.isHidden)
        #expect(sidebar.headings.map(\.title) == ["New title"])
    }

    @Test func outlineDividerResizesAndRetainsWidthAcrossVisibilityChanges() throws {
        let source = "# Heading\n\nBody"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        let split = try #require(controller.view as? NSSplitView)
        split.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        split.layoutSubtreeIfNeeded()
        split.setPosition(320, ofDividerAt: 0)
        #expect(controller.outlineSidebar.frame.width == 320)
        #expect(controller.textView.enclosingScrollView?.frame.width == 480 - split.dividerThickness)
        #expect(session.source == source)
        #expect(session.replaceSource(in: NSRange(location: 0, length: source.utf16.count), with: "Body"))
        session.renderNow()
        #expect(controller.outlineSidebar.isHidden)
        #expect(split.dividerThickness == 0)
        #expect(controller.textView.enclosingScrollView?.frame.width == 800)
        #expect(session.replaceSource(in: NSRange(location: 0, length: session.source.utf16.count), with: source))
        session.renderNow()
        #expect(controller.outlineSidebar.frame.width == 320)
        split.frame.size.width = 480
        split.layoutSubtreeIfNeeded()
        #expect(controller.textView.enclosingScrollView!.frame.width >= 180)
        split.frame.size.width = 800
        split.layoutSubtreeIfNeeded()
        #expect(controller.outlineSidebar.frame.width == 320)
        let minimum = try #require(split.delegate?.splitView?(split, constrainSplitPosition: 0, ofSubviewAt: 0))
        let maximum = try #require(split.delegate?.splitView?(split, constrainSplitPosition: 800, ofSubviewAt: 0))
        #expect(minimum == 120)
        #expect(maximum == 480)
    }

    @Test func headingsComeFromParsedMarkdown() {
        let source = "# First **bold**\n\n### Child `code`\n\nSecond\n------\n\n```md\n# Not a heading\n```\n\n> ## Quoted 😀\n"
        let snapshot = MarkdownRenderer.snapshot(source: source)
        #expect(snapshot.headings.map(\.title) == ["First bold", "Child code", "Second", "Quoted 😀"])
        #expect(snapshot.headings.map(\.level) == [1, 3, 2, 2])
        for heading in snapshot.headings {
            #expect((snapshot.text as NSString).substring(with: heading.displayedRange) == heading.title)
            #expect(heading.sourceRange.location >= 0)
            #expect(NSMaxRange(heading.sourceRange) <= source.utf16.count)
        }
        #expect(MarkdownRenderer.snapshot(source: "Plain text\n\n```\n# code\n```").headings.isEmpty)
    }
}