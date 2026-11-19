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
        observation = Self.store.observe(\.keepInMenuBar) { defaults, _ in
            if defaults.keepInMenuBar { MenuBarMode.forgetHiddenItem() } // before SwiftUI inserts the item
            Task { @MainActor in MenuBarMode.shared.apply() }
        }
    }

    /// AppKit remembers a removed menu bar item as hidden ("NSStatusItem Visible…" in the app's preferences), and
    /// SwiftUI then inserts it hidden the next time the option is turned on, even in a later launch. Forgotten
    /// at launch and whenever the option is turned on, so the item always shows (1.2.0-rc.2).
    nonisolated static func forgetHiddenItem() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        for (key, value) in UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            where key.hasPrefix("NSStatusItem Visible") && (value as? Bool) == false {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
        _ = MenuBarMode.shared // follows the setting from launch on, whichever menu changes it
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
            for _ in 0..<100 where !condition() { try? await Task.sleep(nanoseconds: 100_000_000) }
            return condition()
        }
        // The item's own visibility: on recent macOS the menu bar draws status items itself, and the window object
        // of a removed item can linger and still report itself visible.
        func items() -> [String] {
            NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }.map { window in
                let selector = NSSelectorFromString("statusItem")
                guard window.responds(to: selector) else { return "window visible=\(window.isVisible), no statusItem" }
                guard let item = window.perform(selector)?.takeUnretainedValue() as? NSStatusItem else { return "window visible=\(window.isVisible), item nil" }
                return "window visible=\(window.isVisible), item visible=\(item.isVisible) button=\(item.button != nil)"
            }
        }
        /// Menu bar items shown: visible and with a button (removed items can linger without one).
        let shown = {
            NSApp.windows.filter { window in
                guard String(describing: type(of: window)).contains("StatusBar") else { return false }
                let selector = NSSelectorFromString("statusItem")
                guard window.responds(to: selector), let item = window.perform(selector)?.takeUnretainedValue() as? NSStatusItem else { return false }
                return item.isVisible && item.button != nil
            }.count
        }
        let statusItem = { shown() > 0 }
        // AppKit keeps menu bar item visibility in the app's own preferences: put back as found when the test ends.
        let domain = Bundle.main.bundleIdentifier ?? "local.samsung-cloud-notes"
        let remembered = (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).filter { $0.key.hasPrefix("NSStatusItem Visible") }
        func restore() {
            MenuBarMode.store.removePersistentDomain(forName: MenuBarMode.testSuite)
            for key in (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).keys where key.hasPrefix("NSStatusItem Visible") {
                UserDefaults.standard.removeObject(forKey: key)
            }
            for (key, value) in remembered { UserDefaults.standard.set(value, forKey: key) }
        }
        func fail(_ message: String) -> Never {
            let visibility = (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).filter { $0.key.hasPrefix("NSStatusItem") }
            fputs("Menu bar test failed: \(message)\nStatus items: \(items().joined(separator: " | ")) · remembered: \(visibility)\n", stderr); restore(); exit(1)
        }
        MenuBarMode.store.removePersistentDomain(forName: MenuBarMode.testSuite)
        guard await wait({ mode.windowOpen }) else { fail("the window did not open") }
        // An item removed earlier is remembered as hidden; turning the option on must still show it.
        UserDefaults.standard.set(false, forKey: "NSStatusItem VisibleCC Item-0")
        mode.keepInMenuBar = true
        guard await wait(statusItem) else { fail("no menu bar item") }
        guard shown() == 1 else { fail("\(shown()) menu bar items instead of one") }
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

        // Check marks follow each setting at once, whichever menu changed it (1.2.0-rc.2). Menus are read as they
        // are when opened, and items are chosen as a click does.
        /// Opens a menu as a click does (it fills itself as it opens), reads it, and closes it again.
        func open<T>(_ menu: NSMenu?, _ read: (NSMenu) -> T) -> T? {
            guard let menu else { return nil }
            menu.delegate?.menuNeedsUpdate?(menu); menu.delegate?.menuWillOpen?(menu)
            defer { menu.delegate?.menuDidClose?(menu) }
            return read(menu)
        }
        func item(_ menu: NSMenu?, _ title: String) -> (state: NSControl.StateValue, enabled: Bool)? {
            open(menu) { $0.items.first { $0.title == title }.map { ($0.state, $0.isEnabled) } } ?? nil
        }
        func state(_ menu: NSMenu?, _ title: String) -> NSControl.StateValue? { item(menu, title)?.state }
        /// Chooses an item: the menu closes, then the item's action is sent.
        func choose(_ menu: NSMenu?, _ title: String) -> Bool {
            guard let menu, let index = open(menu, { $0.items.firstIndex { $0.title == title && $0.isEnabled } }) ?? nil else { return false }
            if index < menu.items.count, menu.items[index].title == title { menu.performActionForItem(at: index); return true }
            return open(menu) { $0.performActionForItem(at: index) } != nil
        }
        func describe(_ menu: NSMenu?) -> String {
            open(menu) { $0.items.map { "\($0.title.isEmpty ? "—" : $0.title)=\($0.state.rawValue)\($0.isEnabled ? "" : "(disabled)")" }.joined(separator: ", ") } ?? "none"
        }
        // The Sync with Apple Notes button is a two-part control; its second part holds the drop-down menu.
        let toolbarButton = { () -> NSSegmentedControl? in
            func control(_ view: NSView) -> NSSegmentedControl? { (view as? NSSegmentedControl) ?? view.subviews.lazy.compactMap(control).first }
            return NSApp.windows.compactMap(\.toolbar).flatMap(\.items).first(where: { $0.label == "Sync with Apple Notes" })?.view.flatMap(control)
        }
        let toolbarMenu = { () -> NSMenu? in
            guard let segmented = toolbarButton() else { return nil }
            return (0..<segmented.segmentCount).lazy.compactMap { segmented.menu(forSegment: $0) }.first
        }
        let statusMenu = { () -> NSMenu? in
            for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
                let selector = NSSelectorFromString("statusItem")
                // Menus fill themselves as they open; removed items linger without a button.
                if window.responds(to: selector), let item = window.perform(selector)?.takeUnretainedValue() as? NSStatusItem, item.isVisible,
                   item.button != nil, let menu = item.menu { return menu }
            }
            return nil
        }
        func menus() -> String {
            let items = NSApp.windows.compactMap(\.toolbar).flatMap(\.items).map { "\(type(of: $0)):\($0.label)" }.joined(separator: ", ")
            return "toolbar items [\(items)] · toolbar menu [\(describe(toolbarMenu()))] · menu bar menu [\(describe(statusMenu()))] · sync=\(live.enabled) menuBar=\(mode.keepInMenuBar)"
        }
        // The Apple Notes menu is enabled once notes are listed.
        model.notes = [NoteRecord(id: "menu-bar-test", resourceID: "", commit: "", modified: 0, locked: false, encrypted: false)]
        live.enabled = true
        let sync = "Keep in sync automatically", barSync = "Keep Apple Notes in Sync", stay = "Stay in menu bar when closed"
        // Opened once the button is enabled, as a person can (a menu opened earlier would keep its greyed-out items).
        guard await wait({ toolbarButton()?.isEnabled == true }) else { fail("the Sync with Apple Notes button stayed disabled: \(menus())") }
        guard await wait({ item(toolbarMenu(), sync)?.enabled == true && state(toolbarMenu(), sync) == .on && state(statusMenu(), barSync) == .on }) else {
            fail("menus did not show the settings: \(menus())")
        }
        guard choose(toolbarMenu(), sync) else { fail("could not choose \(sync): \(menus())") }
        guard await wait({ !live.enabled && state(toolbarMenu(), sync) == .off && state(statusMenu(), barSync) == .off }) else {
            fail("turning sync off in the toolbar menu left a check mark: \(menus())")
        }
        guard choose(statusMenu(), barSync) else { fail("could not choose \(barSync): \(menus())") }
        guard await wait({ live.enabled && state(toolbarMenu(), sync) == .on && state(statusMenu(), barSync) == .on }) else {
            fail("turning sync on in the menu bar menu left the check marks off: \(menus())")
        }
        guard state(toolbarMenu(), stay) == .on, choose(toolbarMenu(), stay) else { fail("\(stay) is not checked: \(menus())") }
        guard await wait({ !mode.keepInMenuBar && !statusItem() && state(toolbarMenu(), stay) == .off }) else {
            fail("turning the menu bar item off from the toolbar menu left it or its check mark: \(menus())")
        }
        print("Menu bar test passed: closing leaves the Dock, the menu bar item stays, reopening restores both, check marks follow both menus.")
        restore()
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
        Button(live.checking ? "Checking Samsung Cloud…" : "Check for Changes Now") { Task { await live.checkNow() } }
            .disabled(model.account.isEmpty || model.busy || live.checking)
        Divider()
        Button("Quit Samsung Cloud Notes") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// The menu bar icon; it turns into arrows while Samsung Cloud is being checked or a note saved.
struct NotesMenuBarLabel: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var live: AppleNotesLive
    var body: some View {
        Image(systemName: live.checking || model.busy ? "arrow.triangle.2.circlepath" : "note.text")
            .accessibilityLabel(live.checking ? "Samsung Cloud Notes, checking for changes" : "Samsung Cloud Notes")
    }
}
