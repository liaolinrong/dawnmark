#if DEBUG
import AppKit
import DawnMarkSupport
import DocumentWorkspace
import EditorKit

@MainActor extension AppDelegate {
    func runSmokeTest() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DawnMark-Smoke-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let location = try DocumentStore().create(name: "DawnMark", in: root)
            let longCell = String(repeating: "Native editable Markdown tables wrap long content. ", count: 5)
            let source = "# DawnMark\n\nNative **Markdown** editing.\n\n## Editing\n\n### Inline formatting\n\n#### Nested sections with a longer heading\n\n##### Small sections\n\n###### Details\n\n## Tasks\n\n- [ ] Task\n\n## Table\n\n| ID | Description | Status |\n| --- | --- | --- |\n| 1 | \(longCell) | OK |\n| 2 | Short | Ready |\n\n## Code\n\n```swift\nlet editor = true\n```\n"
            try DocumentStore().save(source, to: location)
            let document = displayDocument(location, source: source)
            await document.session.waitForRendering()
            precondition(document.editor.textView.string.contains("DawnMark"))
            precondition(!document.editor.textView.string.contains("**Markdown**"))
            precondition(!document.editor.canEdit)
            document.editor.mode = .source
            precondition(document.editor.textView.string == source)
            document.editor.mode = .richText
            precondition(document.session.source == source)
            precondition(!document.editor.outlineSidebar.isHidden)
            precondition(document.editor.outlineSidebar.outlineView.numberOfRows == 9)
            let heading = document.session.renderSnapshot!.headings[2]
            precondition(document.editor.navigate(to: heading))
            precondition(document.editor.textView.selectedRange().location == heading.displayedRange.location)
            precondition(NSApp.mainMenu?.items.count == 8)
            let formatMenu = NSApp.mainMenu!.items[3].submenu!
            precondition(formatMenu.items.allSatisfy { $0.submenu == nil })
            precondition(formatMenu.items.filter(\.isSeparatorItem).count == 5)
            let formatItems = formatMenu.items.filter { !$0.isSeparatorItem }
            precondition(formatItems.count == 23)
            precondition(formatItems.contains { $0.title == L10n.text(.deleteTable) })
            precondition(formatItems.allSatisfy { $0.action == #selector(formatCommand(_:)) && $0.representedObject is FormatBox })
            for level in 1...6 {
                precondition(formatItems[level].keyEquivalent == "\(level)")
                precondition(formatItems[level].keyEquivalentModifierMask == [.command, .option])
            }
            precondition(formatItems[7].keyEquivalent == "b" && formatItems[8].keyEquivalent == "i")
            let documentWindow = document.windowControllers.first!.window!
            let ruleItem = documentWindow.toolbar!.items.first { $0.itemIdentifier.rawValue == "DawnMark.InsertHorizontalRule" }!
            precondition(ruleItem.label == L10n.text(.rule) && ruleItem.toolTip == L10n.text(.rule))
            precondition(ruleItem.image != nil && !document.validateToolbarItem(ruleItem))
            document.editor.canEdit = true
            precondition(document.validateToolbarItem(ruleItem))
            document.editor.textView.setSelectedRange(NSRange(location: document.editor.textView.string.utf16.count, length: 0))
            precondition(NSApp.sendAction(ruleItem.action!, to: ruleItem.target, from: ruleItem))
            document.session.renderNow()
            precondition(document.session.renderSnapshot!.runs.contains { $0.style.contains(.horizontalRule) })
            document.session.undoManager.undo()
            document.session.renderNow()
            precondition(document.session.source == source)
            document.updateChangeCount(.changeCleared)
            document.editor.canEdit = false
            let split = document.editor.view as! NSSplitView
            let savedSource = document.session.source
            split.setPosition(260, ofDividerAt: 0)
            precondition(document.editor.outlineSidebar.frame.width == 260)
            precondition(document.editor.textView.enclosingScrollView!.frame.width == split.bounds.width - 260 - split.dividerThickness)
            precondition(document.session.source == savedSource)
            split.setPosition(200, ofDividerAt: 0)
            documentWindow.orderOut(nil)
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            precondition(documentWindow.isVisible)
            precondition(auxiliaryWindows["welcome"] == nil)
            documentWindow.miniaturize(nil)
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            precondition(!documentWindow.isMiniaturized && documentWindow.isVisible)
            for width in [900, 480] {
                documentWindow.setContentSize(NSSize(width: width, height: 700))
                documentWindow.contentView?.layoutSubtreeIfNeeded()
                document.editor.textView.updateTableLayout()
                precondition(document.editor.navigate(to: document.session.renderSnapshot!.headings[7]))
                if let layout = document.editor.textView.layoutManager,
                   let container = document.editor.textView.textContainer,
                   let scroll = document.editor.textView.enclosingScrollView,
                   let cell = document.session.renderSnapshot!.tableCells.first {
                    layout.ensureLayout(for: container)
                    let glyphs = layout.glyphRange(forCharacterRange: cell.range, actualCharacterRange: nil)
                    let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, bounds.minY - 24)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                documentWindow.displayIfNeeded()
                precondition(document.editor.outlineSidebar.frame.width == 200)
                let outlineLabel = document.editor.outlineSidebar.subviews.compactMap { $0 as? NSTextField }.first!
                precondition(!outlineLabel.stringValue.isEmpty && outlineLabel.frame.width > 0 && outlineLabel.frame.height > 0)
                precondition(document.editor.textView.enclosingScrollView!.frame.width >= 279)
                if let content = documentWindow.contentView,
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        let name = width == 900 ? "DawnMark-smoke.png" : "DawnMark-outline-narrow.png"
                        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
                    }
                }
            }
            document.windowControllers.first?.window?.performClose(nil)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            let welcomeWindow = auxiliaryWindows["welcome"]!.window!
            precondition(welcomeWindow.isVisible)
            welcomeWindow.performClose(nil)
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            precondition(auxiliaryWindows["welcome"]!.window === welcomeWindow)
            precondition(welcomeWindow.isVisible)
            welcomeWindow.orderOut(nil)
            restoreWindow()
            precondition(welcomeWindow.isVisible)
            await checkPurchaseLayout()
            print("DawnMark smoke passed: window, menus, source/rich modes, outline hierarchy/navigation/widths, read-only, close, reopen hidden/minimized/closed windows")
            exit(0)
        } catch {
            print("DawnMark smoke failed: \(error)")
            exit(1)
        }
    }
}
#endif