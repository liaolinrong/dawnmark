import AppKit
import DawnMarkSupport
import EditorKit

@MainActor extension AppDelegate: NSMenuItemValidation, NSMenuDelegate {
    func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu; main.addItem(item); return submenu
        }
        func add(_ menu: NSMenu, _ key: TextKey, _ action: Selector, _ shortcut: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: shortcut)
            item.target = target ?? self
            menu.addItem(item)
        }
        func group(_ parent: NSMenu, _ key: TextKey) -> NSMenu {
            let item = NSMenuItem(title: L10n.text(key), action: nil, keyEquivalent: "")
            let menu = NSMenu(title: L10n.text(key)); item.submenu = menu; parent.addItem(item); return menu
        }
        func command(_ menu: NSMenu, _ key: TextKey, _ command: FormattingCommand, _ shortcut: String = "") {
            let item = NSMenuItem(title: L10n.text(key), action: #selector(formatCommand(_:)), keyEquivalent: shortcut)
            item.target = self; item.representedObject = FormatBox(command); menu.addItem(item)
        }
        let app = menu("DawnMark")
        add(app, .about, #selector(showAbout(_:)))
        add(app, .settings, #selector(showSettings(_:)), ",")
        app.addItem(.separator()); add(app, .purchase, #selector(showPurchaseAction(_:))); add(app, .restore, #selector(restoreAction(_:)))
        app.addItem(.separator()); add(app, .quit, #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu(L10n.text(.file))
        add(file, .newDocument, #selector(newDocument(_:)), "n"); add(file, .open, #selector(open(_:)), "o")
        let recent = group(file, .openRecent); recent.delegate = self
        file.addItem(.separator()); add(file, .close, #selector(NSWindow.performClose(_:)), "w", target: nil)
        file.items.last?.target = nil
        add(file, .save, #selector(save(_:)), "s"); add(file, .saveAs, #selector(saveAs(_:)), "S")
        file.items.last?.keyEquivalentModifierMask = [.command, .shift]
        add(file, .showInFinder, #selector(showInFinder(_:)))
        let edit = menu(L10n.text(.edit))
        add(edit, .undo, #selector(undo(_:)), "z"); add(edit, .redo, #selector(redo(_:)), "Z")
        edit.items.last?.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (key, selector, shortcut) in [(TextKey.cut, #selector(NSText.cut(_:)), "x"), (.copy, #selector(NSText.copy(_:)), "c"), (.paste, #selector(NSText.paste(_:)), "v"), (.selectAll, #selector(NSText.selectAll(_:)), "a")] {
            add(edit, key, selector, shortcut); edit.items.last?.target = nil
        }
        edit.addItem(.separator()); add(edit, .find, #selector(showFind(_:)), "f"); edit.items.last?.tag = NSTextFinder.Action.showFindInterface.rawValue
        add(edit, .replace, #selector(showFind(_:)), "f"); edit.items.last?.tag = NSTextFinder.Action.showReplaceInterface.rawValue; edit.items.last?.keyEquivalentModifierMask = [.command, .option]
        let format = menu(L10n.text(.format))
        command(format, .body, .body)
        for level in 1...6 {
            let item = NSMenuItem(title: L10n.format(.heading, level), action: #selector(formatCommand(_:)), keyEquivalent: "\(level)")
            item.keyEquivalentModifierMask = [.command, .option]; item.target = self; item.representedObject = FormatBox(.heading(level: level)); format.addItem(item)
        }
        format.addItem(.separator())
        command(format, .bold, .bold, "b"); command(format, .italic, .italic, "i"); command(format, .strike, .strikethrough); command(format, .inlineCode, .inlineCode)
        format.addItem(.separator())
        command(format, .unordered, .unorderedList); command(format, .ordered, .orderedList); command(format, .tasks, .taskList)
        format.addItem(.separator())
        command(format, .quote, .quote); command(format, .indent, .indent); command(format, .outdent, .outdent)
        format.addItem(.separator())
        command(format, .addRow, .tableInsertRow); command(format, .deleteRow, .tableDeleteRow); command(format, .addColumn, .tableInsertColumn); command(format, .deleteColumn, .tableDeleteColumn)
        command(format, .deleteTable, .tableDelete)
        format.addItem(.separator()); command(format, .clearFormat, .clearFormatting)
        let insert = menu(L10n.text(.insert))
        add(insert, .link, #selector(insertLink(_:)), "k"); add(insert, .image, #selector(insertImage(_:))); add(insert, .table, #selector(insertTable(_:)))
        insert.addItem(.separator()); command(insert, .codeBlock, .codeBlock); command(insert, .rule, .horizontalRule)
        let view = menu(L10n.text(.view))
        add(view, .richMode, #selector(changeMode(_:))); view.items.last?.tag = 0
        add(view, .sourceMode, #selector(changeMode(_:))); view.items.last?.tag = 1
        let windows = menu(L10n.text(.window)); NSApp.windowsMenu = windows
        add(windows, .minimize, #selector(NSWindow.performMiniaturize(_:)), "m"); windows.items.last?.target = nil
        add(windows, .zoom, #selector(NSWindow.performZoom(_:))); windows.items.last?.target = nil
        add(windows, .bringAll, #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        let help = menu(L10n.text(.help)); NSApp.helpMenu = help
        add(help, .appHelp, #selector(showHelp(_:)))
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = url; menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L10n.text(.clearRecent), action: #selector(clearRecent(_:)), keyEquivalent: ""); clear.target = self; menu.addItem(clear)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return false }
        let document = activeDocument
        if action == #selector(changeMode(_:)) {
            menuItem.state = document?.editor.mode == (menuItem.tag == 1 ? .source : .richText) ? .on : .off
            return document != nil
        }
        if action == #selector(newDocument(_:)) { return commerce.canEdit }
        if action == #selector(save(_:)) { return document?.isDocumentEdited == true }
        if action == #selector(undo(_:)) { return commerce.canEdit && document?.session.undoManager.canUndo == true }
        if action == #selector(redo(_:)) { return commerce.canEdit && document?.session.undoManager.canRedo == true }
        if action == #selector(formatCommand(_:)), let box = menuItem.representedObject as? FormatBox, let document {
            switch document.editor.formattingState(box.command) {
            case .on: menuItem.state = .on
            case .mixed: menuItem.state = .mixed
            case .off: menuItem.state = .off
            case .unavailable: menuItem.state = .off; return false
            }
            return commerce.canEdit
        }
        if action == #selector(formatCommand(_:)) || action == #selector(insertLink(_:)) || action == #selector(insertImage(_:)) || action == #selector(insertTable(_:)) || action == #selector(saveAs(_:)) { return document != nil && commerce.canEdit }
        if action == #selector(showInFinder(_:)) || action == #selector(showFind(_:)) { return document != nil }
        return true
    }
}