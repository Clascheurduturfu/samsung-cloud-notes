import AppKit
import SwiftUI

/// "Stay in Menu Bar When Closed": closing the window also removes the Dock icon. Samsung Cloud Notes then keeps
/// syncing from the menu bar, and Apple Notes can be used on its own.
/// The setting is read by SwiftUI through `@AppStorage(MenuBarMode.key, store: MenuBarMode.store)`, the pattern
/// MenuBarExtra's `isInserted` is documented with.
@MainActor final class MenuBarMode {
    static let shared = MenuBarMode()
    nonisolated static let key = "keepInMenuBar"
    nonisolated static let testSuite = "local.samsung-cloud-notes.menu-bar-test"
    /// The app's preferences, or a throwaway domain for `--menu-bar-test` so a test never changes the real setting.
    static let store: UserDefaults = CommandLine.arguments.contains("--menu-bar-test") ? UserDefaults(suiteName: testSuite) ?? .standard : .standard
    private var observation: NSKeyValueObservation?

    var keepInMenuBar: Bool {
        get { Self.store.bool(forKey: Self.key) }
        set { Self.store.set(newValue, forKey: Self.key) }
    }

    private init() {
        observation = Self.store.observe(\.keepInMenuBar) { _, _ in Task { @MainActor in MenuBarMode.shared.apply() } }
    }

    /// Never an app with neither a Dock icon nor a menu bar item.
    private func apply() {
        if !keepInMenuBar { showInDock() } else if !windowOpen { hideFromDock() }
    }

    var windowOpen: Bool {
        NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
    }

    func windowWillClose() {
        guard keepInMenuBar else { return }
        // The closing window still counts as visible until its notification returns.
        DispatchQueue.main.async { if self.keepInMenuBar, !self.windowOpen { self.hideFromDock() } }
    }

    func hideFromDock() {
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    func showInDock() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// Brings the window back (or opens a new one) with the Dock icon.
    func showWindow(open: () -> Void) {
        showInDock()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else { open() }
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension UserDefaults {
    /// Observable form of `MenuBarMode.key`.
    @objc dynamic var keepInMenuBar: Bool { bool(forKey: "keepInMenuBar") }
}

/// Owns what must outlive the window: the notes model, automatic Apple Notes sync and the Samsung Cloud checks,
/// so closing the window never stops syncing.
@MainActor final class NotesAppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = NotesModel()
    lazy var live = AppleNotesLive()
    private var started = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        if CommandLine.arguments.contains("--menu-bar-test") { Task { await menuBarTest() }; return }
        started = true
        live.attach(model)
        Task { await model.connect() }
        // Other devices' edits arrive without Refresh: every minute while in front or keeping Apple Notes in sync,
        // otherwise every three.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.model.refreshIfStale(NSApp.isActive || self.live.syncing ? 60 : 180)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if started { Task { await model.refreshIfStale(10) } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard started else { return }
        model.preserveDraft(); live.appWillTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again (Finder, Launchpad, Spotlight) brings the Dock icon and the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarMode.shared.showInDock()
        return true
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.canBecomeMain else { return }
        if started { model.preserveDraft() }
        MenuBarMode.shared.windowWillClose()
    }

    /// `--menu-bar-test`: closing the window leaves the Dock and keeps the menu bar item, and reopening the app brings
    /// both back. Runs without an account, sync or saved preference.
    private func menuBarTest() async {
        let mode = MenuBarMode.shared
        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<50 where !condition() { try? await Task.sleep(nanoseconds: 100_000_000) }
            return condition()
        }
        // The item's own visibility: on recent macOS the menu bar draws status items itself, and the window object
        // of a removed item can linger and still report itself visible.
        func items() -> [String] {
            NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }.map { window in
                let selector = NSSelectorFromString("statusItem")
                guard window.responds(to: selector) else { return "window visible=\(window.isVisible), no statusItem" }
                guard let item = window.perform(selector)?.takeUnretainedValue() as? NSStatusItem else { return "window visible=\(window.isVisible), item nil" }
                return "window visible=\(window.isVisible), item visible=\(item.isVisible)"
            }
        }
        let statusItem = {
            NSApp.windows.contains { window in
                guard String(describing: type(of: window)).contains("StatusBar") else { return false }
                let selector = NSSelectorFromString("statusItem")
                guard window.responds(to: selector) else { return window.isVisible }
                return (window.perform(selector)?.takeUnretainedValue() as? NSStatusItem)?.isVisible ?? false
            }
        }
        func fail(_ message: String) -> Never {
            MenuBarMode.store.removePersistentDomain(forName: MenuBarMode.testSuite)
            fputs("Menu bar test failed: \(message)\nStatus items: \(items().joined(separator: " | "))\n", stderr); exit(1)
        }
        MenuBarMode.store.removePersistentDomain(forName: MenuBarMode.testSuite)
        guard await wait({ mode.windowOpen }) else { fail("the window did not open") }
        mode.keepInMenuBar = true
        guard await wait(statusItem) else { fail("no menu bar item") }
        guard NSApp.activationPolicy() == .regular else { fail("Dock icon hidden while the window is open") }
        NSApp.windows.filter { $0.canBecomeMain && $0.isVisible }.forEach { $0.performClose(nil) }
        guard await wait({ !mode.windowOpen && NSApp.activationPolicy() == .accessory }) else { fail("closing the window kept the Dock icon") }
        guard statusItem() else { fail("the menu bar item went away with the window") }
        // The Apple event Finder and the Dock send when the app is opened again.
        let reopen = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        do { _ = try reopen.sendEvent(options: [.noReply], timeout: 5) } catch { fail("reopen event: \(error.localizedDescription)") }
        guard await wait({ mode.windowOpen && NSApp.activationPolicy() == .regular }) else { fail("reopening did not bring back the window and Dock icon") }
        mode.keepInMenuBar = false
        guard await wait({ !statusItem() }) else {
            let windows = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) frame=\($0.frame)" }.joined(separator: "; ")
            fail("turning the option off kept the menu bar item (setting \(mode.keepInMenuBar); windows: \(windows))")
        }
        print("Menu bar test passed: closing leaves the Dock, the menu bar item stays, reopening restores both.")
        MenuBarMode.store.removePersistentDomain(forName: MenuBarMode.testSuite)
        exit(0)
    }
}

/// The menu bar item's menu.
struct NotesMenuBarContent: View {
    let mode = MenuBarMode.shared
    @ObservedObject var model: NotesModel
    @ObservedObject var live: AppleNotesLive
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Samsung Cloud Notes") { mode.showWindow { openWindow(id: "main") } }
        Divider()
        Text(model.account.isEmpty ? "Not signed in" : live.syncing ? "Apple Notes kept in sync" : "Apple Notes sync is off")
        if !model.status.isEmpty { Text(String(model.status.prefix(90))) }
        Toggle("Keep Apple Notes in Sync", isOn: $live.enabled)
        Button("Check for Changes Now") { Task { await model.refreshIfStale(0) } }
            .disabled(model.account.isEmpty || model.busy || model.dirty)
        Divider()
        Button("Quit Samsung Cloud Notes") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
