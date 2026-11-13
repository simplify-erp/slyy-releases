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
        updater.cleanUp()
        if migrateFromSlyySnap() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { offerInstallerCleanup() }
        if CGPreflightScreenCaptureAccess() { Settings.hadScreenAccess = true }
        NSApp.mainMenu = Self.mainMenu()
        let snapperForRename = snapper
        Editor.onRename = { old, new in snapperForRename.fileRenamed(from: old, to: new) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.toolTip = "Slyy Shot"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        // ⌘⇧5 area, ⌘⇧4 window, ⌘⇧3 screen (macOS' own screenshot shortcuts must be off), ⌃⇧E edit last.
        let mods = cmdKey | shiftKey
        let snapper = self.snapper
        HotKeys.shared.register(id: 1, keyCode: kVK_ANSI_5, modifiers: mods) { snapper.capture(.area) }
        HotKeys.shared.register(id: 2, keyCode: kVK_ANSI_4, modifiers: mods) { snapper.capture(.window) }
        HotKeys.shared.register(id: 3, keyCode: kVK_ANSI_3, modifiers: mods) { snapper.capture(.screen) }
        HotKeys.shared.register(id: 4, keyCode: kVK_ANSI_E, modifiers: controlKey | shiftKey) { snapper.editLast() }
        offerToFreeSystemShortcuts()

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

    /// Slyy dot inside viewfinder corners; template image, so macOS tints it
    /// for light/dark menu bars.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.set()
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let arm: CGFloat = 4.5
            let corners = NSBezierPath()
            corners.lineWidth = 1.6
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            for (x, y, dx, dy) in [(inset.minX, inset.minY, arm, arm), (inset.maxX, inset.minY, -arm, arm),
                                   (inset.minX, inset.maxY, arm, -arm), (inset.maxX, inset.maxY, -arm, -arm)] {
                corners.move(to: NSPoint(x: x, y: y + dy))
                corners.line(to: NSPoint(x: x, y: y))
                corners.line(to: NSPoint(x: x + dx, y: y))
            }
            corners.stroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Slyy Shot"
        return image
    }

    /// Hidden for a menu bar app, but gives editor windows and text fields
    /// their keyboard shortcuts (⌘S, ⌘Z, ⌘C, ⌘V, ⌘W …).
    private static func mainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let main = NSMenu()
        let appMenu = NSMenu(title: "Slyy Shot")
        appMenu.addItem(item("Quit Slyy Shot", #selector(NSApplication.terminate(_:)), "q"))
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Save", #selector(Editor.saveDocument(_:)), "s"))
        fileMenu.addItem(item("Save As…", #selector(Editor.saveDocumentAs(_:)), "s", [.command, .shift]))
        fileMenu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item("Undo", #selector(Editor.undoMark(_:)), "z"))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        for sub in [appMenu, fileMenu, editMenu] {
            let holder = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            holder.submenu = sub
            main.addItem(holder)
        }
        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cs: NSEvent.ModifierFlags = [.control, .shift]
        let snapper = self.snapper
        let updater = self.updater

        menu.addItem(ActionItem("Capture Area", key: "5", mods: [.command, .shift]) { snapper.capture(.area) })
        menu.addItem(ActionItem("Capture Window", key: "4", mods: [.command, .shift]) { snapper.capture(.window) })
        menu.addItem(ActionItem("Capture Screen", key: "3", mods: [.command, .shift]) { snapper.capture(.screen) })
        menu.addItem(.separator())

        let hasLast = snapper.lastSnap != nil
        menu.addItem(ActionItem("Edit Last Snap", key: "e", mods: cs, enabled: hasLast) { snapper.editLast() })
        menu.addItem(ActionItem("Open Image in Editor…") { Editor.chooseAndOpen() })
        menu.addItem(ActionItem("Copy Last Snap", enabled: hasLast) { snapper.copyLast() })
        menu.addItem(ActionItem("Show Last Snap in Finder", enabled: hasLast) { snapper.revealLast() })
        menu.addItem(ActionItem("Open Snaps Folder") { snapper.openFolder() })
        menu.addItem(ActionItem("Change Snaps Folder…") { snapper.chooseFolder() })
        menu.addItem(.separator())

        let options = NSMenu()
        options.autoenablesItems = false
        options.addItem(ActionItem("Open Editor After Capture", state: Settings.openEditor) {
            Settings.openEditor.toggle()
        })
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
        menu.addItem(ActionItem("Slyy Shot \(Version.current)", enabled: false) {})
        menu.addItem(ActionItem("Quit Slyy Shot", key: "q", mods: .command) { NSApp.terminate(nil) })
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
