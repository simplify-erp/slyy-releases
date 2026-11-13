import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let snapper = Snapper()
    private let updater = Updater()
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        updater.cleanUp()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Slyy Snap")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        // ⌃⇧1 area, ⌃⇧2 window, ⌃⇧3 screen (⌘⇧3/4/5 stay with macOS).
        let mods = controlKey | shiftKey
        let snapper = self.snapper
        HotKeys.shared.register(id: 1, keyCode: kVK_ANSI_1, modifiers: mods) { snapper.capture(.area) }
        HotKeys.shared.register(id: 2, keyCode: kVK_ANSI_2, modifiers: mods) { snapper.capture(.window) }
        HotKeys.shared.register(id: 3, keyCode: kVK_ANSI_3, modifiers: mods) { snapper.capture(.screen) }

        // Updates: 10 s after launch, then every 6 h (if enabled).
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if Settings.autoUpdate { self?.updater.check(userInitiated: false) }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                if Settings.autoUpdate { self?.updater.check(userInitiated: false) }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cs: NSEvent.ModifierFlags = [.control, .shift]
        let snapper = self.snapper
        let updater = self.updater

        menu.addItem(ActionItem("Capture Area", key: "1", mods: cs) { snapper.capture(.area) })
        menu.addItem(ActionItem("Capture Window", key: "2", mods: cs) { snapper.capture(.window) })
        menu.addItem(ActionItem("Capture Screen", key: "3", mods: cs) { snapper.capture(.screen) })
        menu.addItem(.separator())

        let hasLast = snapper.lastSnap != nil
        menu.addItem(ActionItem("Copy Last Snap", enabled: hasLast) { snapper.copyLast() })
        menu.addItem(ActionItem("Show Last Snap in Finder", enabled: hasLast) { snapper.revealLast() })
        menu.addItem(ActionItem("Open Snaps Folder") { snapper.openFolder() })
        menu.addItem(ActionItem("Change Snaps Folder…") { snapper.chooseFolder() })
        menu.addItem(.separator())

        let options = NSMenu()
        options.autoenablesItems = false
        options.addItem(ActionItem("Copy to Clipboard", state: Settings.copyToClipboard) {
            Settings.copyToClipboard.toggle()
        })
        options.addItem(ActionItem("Play Sound", state: Settings.playSound) {
            Settings.playSound.toggle()
        })
        options.addItem(ActionItem("Launch at Login", state: SMAppService.mainApp.status == .enabled) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                Alerts.info("Launch at Login", error.localizedDescription)
            }
        })
        options.addItem(ActionItem("Check for Updates Automatically", state: Settings.autoUpdate) {
            Settings.autoUpdate.toggle()
        })
        let optionsItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        menu.addItem(optionsItem)
        menu.addItem(ActionItem("Check for Updates…") { updater.check(userInitiated: true) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Slyy Snap \(Version.current)", enabled: false) {})
        menu.addItem(ActionItem("Quit Slyy Snap", key: "q", mods: .command) { NSApp.terminate(nil) })
    }
}

/// NSMenuItem with a closure instead of target/selector plumbing.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = [],
         state on: Bool? = nil, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = mods
        isEnabled = enabled
        if let on { state = on ? .on : .off }
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func fire() {
        handler()
    }
}
