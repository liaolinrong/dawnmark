import AppKit
import SwiftUI
import CommerceCore
import DawnMarkSupport

@MainActor extension AppDelegate {
    func host<Content: View>(_ content: Content, title: String, identifier: String, size: NSSize) {
        if let controller = auxiliaryWindows[identifier] { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let controller = NSWindowController(window: NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false))
        controller.window?.isReleasedWhenClosed = false
        if identifier == "purchase" {
            controller.window?.styleMask.insert(.resizable)
            controller.window?.contentMinSize = NSSize(width: 380, height: 320)
        }
        controller.window?.title = title
        controller.window?.contentView = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: AppLanguage.current.rawValue)))
        controller.window?.center()
        auxiliaryWindows[identifier] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func showWelcome() {
        host(WorkspaceView(delegate: self), title: "DawnMark", identifier: "welcome", size: NSSize(width: 560, height: 350))
    }
    @objc func showPurchaseAction(_ sender: Any?) { showPurchase() }
    func showPurchase() { host(PurchaseView(commerce: commerce), title: L10n.text(.purchase), identifier: "purchase", size: NSSize(width: 460, height: 380)) }
    @objc func restoreAction(_ sender: Any?) { showPurchase(); Task { await commerce.restorePurchases() } }
    @objc func showSettings(_ sender: Any?) { host(SettingsView(delegate: self), title: L10n.text(.settings), identifier: "settings", size: NSSize(width: 440, height: 280)) }
    @objc func showAbout(_ sender: Any?) { host(AboutView(), title: L10n.text(.about), identifier: "about", size: NSSize(width: 330, height: 240)) }
    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = L10n.text(.appHelp); alert.informativeText = L10n.text(.helpContent); alert.runModal()
    }
    func applyPreferences() {
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        for document in NSDocumentController.shared.documents { (document as? MarkdownDocument)?.applyPreferences() }
    }
    func languageChanged() {
        AppLanguage.syncSystemInterfaceLanguage(preference: UserDefaults.standard.string(forKey: "language") ?? "system")
        buildMenus()
        for document in NSDocumentController.shared.documents {
            (document as? MarkdownDocument)?.updateReadOnlyIndicator()
            (document as? MarkdownDocument)?.updateOutlineLocalization()
        }
        let visible = Set(auxiliaryWindows.compactMap { $0.value.window?.isVisible == true ? $0.key : nil })
        for identifier in ["purchase", "about", "welcome"] { auxiliaryWindows[identifier]?.close(); auxiliaryWindows[identifier] = nil }
        if visible.contains("welcome") { showWelcome() }
        if visible.contains("about") { showAbout(nil) }
        if visible.contains("purchase") { showPurchase() }
        auxiliaryWindows["settings"]?.window?.title = L10n.text(.settings)
        let alert = NSAlert()
        alert.messageText = L10n.text(.languageRestartTitle)
        alert.informativeText = L10n.text(.languageRestartMessage)
        alert.addButton(withTitle: L10n.text(.acknowledge))
        if let window = auxiliaryWindows["settings"]?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

private struct WorkspaceView: View {
    let delegate: AppDelegate
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("DawnMark").font(.title2.bold())
                Spacer()
                Button { delegate.open(nil) } label: { Label(L10n.text(.open), systemImage: "folder") }
                Button { delegate.newDocument(nil) } label: { Label(L10n.text(.newDocument), systemImage: "square.and.pencil") }.disabled(!delegate.commerce.canEdit)
            }
            List(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                Button { delegate.openDocument(url) } label: {
                    HStack { Image(systemName: "doc.text"); Text(url.lastPathComponent); Spacer() }
                }.buttonStyle(.plain)
            }
            HStack {
                AccessLabel(commerce: delegate.commerce)
                Spacer()
                Button(L10n.text(.purchase)) { delegate.showPurchase() }
            }
        }.padding(20)
    }
}

private struct AccessLabel: View {
    let commerce: CommerceController
    var body: some View {
        switch commerce.accessState {
        case .checking: Text(L10n.text(.checking))
        case .notStarted: Text(L10n.text(.notStarted))
        case .expired: Text(L10n.text(.expired))
        case .unlocked: Text(L10n.text(.unlocked))
        case .trial(let expiration): Text(L10n.format(.trialStatus, expiration.formatted(.dateTime.locale(Locale(identifier: AppLanguage.current.rawValue)))))
        }
    }
}

private struct PurchaseView: View {
    let commerce: CommerceController
    @State private var price: String?
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("DawnMark").font(.title2.bold())
                    AccessLabel(commerce: commerce).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text(.trialDisclosure)).fixedSize(horizontal: false, vertical: true)
                    if commerce.lastPurchaseResult == .pending { Text(L10n.text(.pending)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if commerce.error != nil { Text(L10n.text(.purchaseFailed)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    if commerce.lastRestoreSucceeded == true {
                        Text(L10n.text(commerce.canEdit ? .restoreSuccess : .restoreEmpty)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if commerce.accessState == .notStarted {
                        Button(L10n.text(.trialStart)) { Task { await commerce.startTrial() } }
                            .disabled(price == nil)
                    }
                    if commerce.accessState != .unlocked {
                        Button(price.map { L10n.format(.buy, $0) } ?? L10n.text(.priceUnavailable)) { Task { await commerce.purchaseLifetime() } }
                            .disabled(price == nil)
                    }
                }.disabled(commerce.isBusy)
                HStack {
                    Button(L10n.text(.restore)) { Task { await commerce.restorePurchases() } }.disabled(commerce.isBusy)
                    if price == nil {
                        Button(L10n.text(.retry)) { Task { await loadPrice() } }.disabled(commerce.isBusy)
                    }
                    Spacer(minLength: 8)
                    if commerce.isBusy { ProgressView().controlSize(.small) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await loadPrice() }
    }

    private func loadPrice() async {
        price = try? await commerce.price(for: commerce.configuration.lifetimeProductID)
    }
}

#if DEBUG
@MainActor extension AppDelegate {
    func checkPurchaseLayout() async {
        let defaults = UserDefaults.standard
        let originalLanguage = defaults.object(forKey: "language")
        defer {
            if let originalLanguage { defaults.set(originalLanguage, forKey: "language") }
            else { defaults.removeObject(forKey: "language") }
        }
        let fixture = CommerceController(configuration: commerce.configuration, provider: PurchaseLayoutProvider())
        await fixture.refresh()
        await fixture.restorePurchases()
        for language in AppLanguage.allCases {
            defaults.set(language.rawValue, forKey: "language")
            for size in [NSSize(width: 460, height: 380), NSSize(width: 380, height: 320)] {
                auxiliaryWindows["purchase"]?.close()
                auxiliaryWindows["purchase"] = nil
                host(PurchaseView(commerce: fixture), title: "DawnMark", identifier: "purchase", size: size)
                for _ in 0..<3 {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                }
                let window = auxiliaryWindows["purchase"]!.window!
                precondition(window.styleMask.contains(.resizable))
                let content = window.contentView!
                content.layoutSubtreeIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        let name = "DawnMark-purchase-\(language.rawValue)-\(Int(size.width)).png"
                        try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
                    }
                }
                window.close()
            }
        }
        auxiliaryWindows["purchase"] = nil
        print("DawnMark purchase layout checked: \(AppLanguage.allCases.count) languages, 460x380 and 380x320")
    }
}

private struct PurchaseLayoutProvider: PurchaseProvider {
    func purchases() async throws -> [VerifiedPurchase] { [] }
    func updates() async -> AsyncStream<VerifiedPurchase> { AsyncStream { $0.finish() } }
    func purchase(productID: String) async throws -> PurchaseResult { .cancelled }
    func restore() async throws { throw CommerceError.productUnavailable }
    func price(productID: String) async throws -> String? { "US$10.00" }
}
#endif

private struct SettingsView: View {
    let delegate: AppDelegate
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("language") private var language = "system"
    @AppStorage("spellcheck") private var spellcheck = false
    @AppStorage("defaultMode") private var mode = "richText"
    var body: some View {
        Form {
            Picker(L10n.text(.appearance), selection: $appearance) {
                Text(L10n.text(.system)).tag("system"); Text(L10n.text(.light)).tag("light"); Text(L10n.text(.dark)).tag("dark")
            }
            Picker(L10n.text(.language), selection: $language) {
                Text(L10n.text(.system)).tag("system")
                ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                    Text(language.nativeName).tag(language.rawValue)
                }
            }
            Picker(L10n.text(.defaultMode), selection: $mode) {
                Text(L10n.text(.richMode)).tag("richText"); Text(L10n.text(.sourceMode)).tag("source")
            }
            Toggle(L10n.text(.spellcheck), isOn: $spellcheck)
        }.padding(24)
            .onChange(of: appearance) { delegate.applyPreferences() }
            .onChange(of: spellcheck) { delegate.applyPreferences() }
            .onChange(of: language) { delegate.languageChanged() }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 72, height: 72)
            Text("DawnMark").font(.title2.bold())
            Text(L10n.format(.version, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0", Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))
            Text(L10n.text(.copyright)).foregroundStyle(.secondary)
        }.padding(24)
    }
}