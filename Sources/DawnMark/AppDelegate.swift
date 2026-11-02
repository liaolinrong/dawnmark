import AppKit
import CommerceCore
import CommerceStoreKit
import DawnMarkSupport
import Observation

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let commerce: CommerceController
    var auxiliaryWindows: [String: NSWindowController] = [:]

    override init() {
        let configuration = CommerceConfiguration(
            trialProductID: Bundle.main.object(forInfoDictionaryKey: "TrialProductID") as? String ?? "com.liaolinrong.DawnMark.trial15days",
            lifetimeProductID: Bundle.main.object(forInfoDictionaryKey: "LifetimeProductID") as? String ?? "com.liaolinrong.DawnMark.lifetime"
        )
        commerce = CommerceController(configuration: configuration, provider: StoreKitProvider(configuration: configuration))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        applyPreferences()
        #if DEBUG
        if CommandLine.arguments.contains("--smoke-test") {
            Task { await runSmokeTest() }
            return
        }
        #endif
        commerce.start()
        observeAccess()
        NSApp.activate(ignoringOtherApps: true)
        if NSDocumentController.shared.documents.isEmpty { showWelcome() }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames { openDocument(URL(fileURLWithPath: path)) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restoreWindow()
        return false
    }

    func restoreWindow() {
        let documentWindows = NSDocumentController.shared.documents.flatMap { $0.windowControllers.compactMap(\.window) }
        let candidates = NSApp.orderedWindows.filter { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
        let window = candidates.first ?? documentWindows.first ?? auxiliaryWindows["welcome"]?.window
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            showWelcome()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--smoke-test") { return }
        #endif
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            restoreWindow()
        }
        Task { await commerce.refresh() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for document in NSDocumentController.shared.documents {
            guard let document = document as? MarkdownDocument else { continue }
            if !document.confirmClose() { return .terminateCancel }
        }
        commerce.stop()
        return .terminateNow
    }

    func observeAccess() {
        withObservationTracking {
            _ = commerce.accessState
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                for document in NSDocumentController.shared.documents {
                    (document as? MarkdownDocument)?.updateAccess()
                }
                self.observeAccess()
            }
        }
    }
}