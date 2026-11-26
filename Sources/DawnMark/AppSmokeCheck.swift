#if DEBUG
import AppKit
import DawnMarkSupport
import DocumentWorkspace
import EditorKit

@MainActor extension AppDelegate {
    func runSmokeTest() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DawnMark-Smoke-" + UUID().uuidString)
        do {
            for language in AppLanguage.allCases {
                for selected in ["", "中文 😀 selected"] {
                    let form = LinkInsertionForm(displayText: selected, textLabel: L10n.text(.linkText, language: language), addressLabel: L10n.text(.linkAddress, language: language))
                    let alert = NSAlert()
                    alert.messageText = L10n.text(.link, language: language)
                    alert.accessoryView = form
                    alert.addButton(withTitle: L10n.text(.confirm, language: language))
                    alert.addButton(withTitle: L10n.text(.cancel, language: language))
                    alert.layout()
                    alert.window.contentView?.layoutSubtreeIfNeeded()
                    precondition(form.displayTextField.stringValue == selected)
                    precondition(form.addressField.stringValue == "https://")
                    precondition(form.displayTextField.nextKeyView === form.addressField)
                    precondition(form.arrangedSubviews.count == 4)
                    for child in form.arrangedSubviews {
                        let alignmentRect = child.alignmentRect(forFrame: child.frame)
                        precondition(form.bounds.insetBy(dx: -1, dy: -1).contains(alignmentRect))
                        precondition(child.frame.height >= child.fittingSize.height - 1)
                    }
                    for pair in zip(form.arrangedSubviews, form.arrangedSubviews.dropFirst()) {
                        precondition(!pair.0.frame.intersects(pair.1.frame))
                    }
                }
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try checkLinkActions(in: root)
            try checkTableActions(in: root)
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
            precondition(NSApp.mainMenu?.items.count == 9)
            let formatMenu = NSApp.mainMenu!.items[3].submenu!
            precondition(formatMenu.items.allSatisfy { $0.submenu == nil })
            precondition(formatMenu.items.filter(\.isSeparatorItem).count == 4)
            let formatItems = formatMenu.items.filter { !$0.isSeparatorItem }
            precondition(formatItems.count == 18)
            precondition(!formatItems.contains { $0.title == L10n.text(.deleteTable) })
            precondition(formatItems.allSatisfy { $0.action == #selector(formatCommand(_:)) && $0.representedObject is FormatBox })
            let tableMenu = NSApp.mainMenu!.items[5].submenu!
            precondition(tableMenu.title == L10n.text(.tableActions))
            precondition(tableMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == tableCommandGroups.flatMap { $0.map { L10n.text($0.0) } })
            precondition(tableMenu.items.contains { $0.title == L10n.text(.deleteTable) })
            precondition(NSApp.mainMenu!.items[4].submenu!.items.contains { $0.action == #selector(insertTable(_:)) })
            precondition(NSApp.mainMenu!.items[4].submenu!.items.contains { $0.action == #selector(insertCodeBlock(_:)) && $0.title == L10n.text(.insertCodeBlock) })
            precondition(NSApp.mainMenu!.items[4].submenu!.items.contains { $0.action == #selector(editCodeBlockLanguage(_:)) && $0.title == L10n.text(.codeBlockLanguage) })
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

    private func checkTableActions(in root: URL) throws {
        let source = "Before\n\n| Name | Value |\n| --- | --- |\n| [link](https://example.com) | target |\n\nAfter"
        let location = try DocumentStore().create(name: "Tables", in: root)
        let document = displayDocument(location, source: source)
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        document.session.renderNow()
        let editor = document.editor
        let textView = editor.textView!
        let expectedKeys: [TextKey] = [.insertRowAbove, .insertRowBelow, .deleteRow, .insertColumnLeft, .insertColumnRight, .deleteColumn, .deleteTable]
        let topMenu = NSApp.mainMenu!.items[5].submenu!
        let topItems = topMenu.items.filter { !$0.isSeparatorItem }
        precondition(topItems.map(\.title) == expectedKeys.map { L10n.text($0) })
        precondition(topMenu.items.filter(\.isSeparatorItem).count == 2)
        precondition(topItems.allSatisfy { $0.target === self && $0.action == #selector(formatCommand(_:)) && $0.representedObject is FormatBox })
        for mode in [EditorMode.richText, .source] {
            editor.mode = mode
            for editable in [false, true] {
                editor.canEdit = editable
                textView.setSelectedRange(NSRange(location: 0, length: 3))
                precondition(topItems.allSatisfy { !validateMenuItem($0) })
                let offset = (textView.string as NSString).range(of: "target").location
                let originalSelection = textView.selectedRange()
                let menu = textView.onTableMenu!(offset)!
                let items = menu.items.filter { !$0.isSeparatorItem }
                precondition(items.map(\.title) == topItems.map(\.title))
                precondition(items.allSatisfy { $0.isEnabled == (commerce.canEdit && editable) })
                precondition(items.allSatisfy { $0.target === self && $0.action == #selector(tableCommandFromMenu(_:)) && $0.representedObject is TableMenuContext })
                let context = items.last!.representedObject as! TableMenuContext
                precondition(context.document === document && context.source == source)
                precondition(context.sourceRange.location == (source as NSString).range(of: "target").location)
                precondition(textView.selectedRange() == originalSelection)
                textView.setSelectedRange(NSRange(location: offset, length: 0))
                precondition(topItems.allSatisfy { validateMenuItem($0) == (commerce.canEdit && editable) })
                let headerOffset = (textView.string as NSString).range(of: "Name").location
                let header = textView.onTableMenu!(headerOffset)!.items.filter { !$0.isSeparatorItem }
                precondition(!header[0].isEnabled && !header[2].isEnabled)
                precondition(textView.onTableMenu!(0) == nil)
                precondition(document.session.source == source)
            }
            let layout = textView.layoutManager!
            let container = textView.textContainer!
            layout.ensureLayout(for: container)
            let linkOffset = (textView.string as NSString).range(of: "link").location
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: linkOffset, length: 1), actualCharacterRange: nil)
            let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let point = NSPoint(x: bounds.midX + textView.textContainerOrigin.x, y: bounds.midY + textView.textContainerOrigin.y)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: textView.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: textView.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let linkedMenu = textView.menu(for: event)!
            precondition(Array(linkedMenu.items.prefix(4)).map(\.title) == [TextKey.editLink, .openLink, .copyLinkAddress, .removeLink].map { L10n.text($0) })
            precondition(linkedMenu.items.last!.submenu!.items.filter { !$0.isSeparatorItem }.map(\.title) == expectedKeys.map { L10n.text($0) })
            editor.canEdit = false
            let readonlyMenu = textView.onTableMenu!((textView.string as NSString).range(of: "target").location)!
            tableCommandFromMenu(readonlyMenu.items.last!)
            precondition(document.session.source == source)
        }
        print("DawnMark tables checked: dedicated menu, contextual commands, source/rich modes, header protection, links, read-only")
    }

    private func checkLinkActions(in root: URL) throws {
        let source = "before [**中文 😀** and *text*](https://example.com/a?q=1 \"title\") after"
        let location = try DocumentStore().create(name: "Links", in: root)
        let document = displayDocument(location, source: source)
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        document.session.renderNow()
        let editor = document.editor
        let textView = editor.textView!
        for mode in [EditorMode.richText, .source] {
            editor.mode = mode
            let range = (textView.string as NSString).range(of: "中文 😀")
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            let link = editor.currentLink!
            let form = LinkInsertionForm(editor: editor, link: link)
            precondition(form.displayTextField.stringValue == "中文 😀 and text")
            precondition(form.addressField.stringValue == "https://example.com/a?q=1")
            let menu = editor.textView.onLinkMenu?(range.location)
            precondition(menu?.items.map(\.title) == [TextKey.editLink, .openLink, .copyLinkAddress, .removeLink].map { L10n.text($0) })
            precondition(menu?.items.map(\.isEnabled) == [false, true, true, false])
            precondition(menu?.items.allSatisfy { $0.representedObject is LinkMenuContext && $0.target === self } == true)
            let insertionItem = NSMenuItem(title: "", action: #selector(insertLink(_:)), keyEquivalent: "k")
            precondition(!validateLinkMenuItem(insertionItem, document: document))
            precondition(insertionItem.title == L10n.text(.editLink))
            textView.setSelectedRange(NSRange(location: 0, length: 6))
            precondition(!validateLinkMenuItem(insertionItem, document: document))
            precondition(insertionItem.title == L10n.text(.link))
            let insertForm = LinkInsertionForm(editor: editor, link: editor.currentLink)
            precondition(insertForm.displayTextField.stringValue == "before")
            precondition(insertForm.addressField.stringValue == "https://")
            precondition(document.session.source == source)
        }
        print("DawnMark links checked: hit menus, complete prefill, source/rich modes, dynamic menu, read-only")
    }
}
#endif