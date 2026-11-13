import AppKit

enum CaptureMode {
    case area, window, screen
}

/// Screenshots via /usr/sbin/screencapture, saved as PNG to Settings.folder, optionally copied to the clipboard.
@MainActor
final class Snapper {
    private(set) var lastSnap: URL?
    private var busy = false
    private var askedForAccess = false

    func capture(_ mode: CaptureMode) {
        guard !busy else { return }
        guard ensureScreenRecordingAccess() else { return }
        let folder = Settings.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Alerts.info("Cannot create snap folder", "\(folder.path)\n\n\(error.localizedDescription)")
            return
        }
        let (url, number) = Self.nextSnap(in: folder)
        var args = ["-x", "-t", "png"] // -x: no system sound (we play our own)
        switch mode {
        case .area: args.append("-i") // drag a rectangle; Space toggles window mode, Esc cancels
        case .window: args += ["-i", "-w"] // click a window
        case .screen: args.append("-m") // main display
        }
        args.append(url.path)

        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? Updater.run("/usr/sbin/screencapture", args) // non-zero exit = cancelled
            DispatchQueue.main.async {
                self.busy = false
                // No file: the user pressed Esc.
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                Settings.lastSnapNumber = max(Settings.lastSnapNumber, number)
                self.lastSnap = url
                if Settings.copyToClipboard { Clipboard.copy(url) }
                if Settings.playSound { NSSound(named: "Tink")?.play() }
                if Settings.openEditor { Editor.open(url) } else { SnapPreview.show(url) }
            }
        }
    }

    func copyLast() {
        if let lastSnap { Clipboard.copy(lastSnap) }
    }

    /// Without Screen Recording, screencapture only gets the wallpaper, so we do not capture. A grant lost by an update
    /// (unsigned build: old entry stays on but no longer applies) is reset, so the system prompt adds a fresh entry.
    private func ensureScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            Settings.hadScreenAccess = true
            return true
        }
        if !askedForAccess {
            askedForAccess = true
            if Settings.hadScreenAccess {
                try? Updater.run("/usr/bin/tccutil", ["reset", "ScreenCapture", "ai.slyy.snap"])
                Settings.hadScreenAccess = false
            }
            CGRequestScreenCaptureAccess() // system prompt (adds a fresh entry)
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Slyy Shot needs Screen Recording permission"
        alert.informativeText = "Switch on Slyy Shot under System Settings > Privacy & Security > Screen Recording, "
            + "then choose \"Quit & Reopen\".\n\nAfter an update, an older Slyy Shot entry may still be listed and "
            + "switched on: remove it with the − button, then add or switch on the current one."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    /// Remove a stale Screen Recording entry, ask again and relaunch.
    func resetScreenRecordingPermission() {
        let alert = NSAlert()
        alert.messageText = "Reset Screen Recording permission?"
        alert.informativeText = "Use this if macOS keeps asking although Slyy Shot is switched on in System Settings. "
            + "Slyy Shot removes its entry, asks again and relaunches: then switch it on once more."
        alert.addButton(withTitle: "Reset and Relaunch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Updater.run("/usr/bin/tccutil", ["reset", "ScreenCapture", "ai.slyy.snap"])
        } catch {
            Alerts.info("Reset failed", "\(error.localizedDescription)\n\nRemove Slyy Shot with the − button under "
                + "System Settings > Privacy & Security > Screen Recording, then reopen it.")
            return
        }
        CGRequestScreenCaptureAccess()
        relaunch(Bundle.main.bundlePath)
    }

    func fileRenamed(from old: URL, to new: URL) {
        if lastSnap == old { lastSnap = new }
    }

    func editLast() {
        if let lastSnap { Editor.open(lastSnap) }
    }

    func revealLast() {
        if let lastSnap { NSWorkspace.shared.activateFileViewerSelecting([lastSnap]) }
    }

    func openFolder() {
        let folder = Settings.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Save snaps to"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.folder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.folder = url
        }
    }

    /// Next free slyy-NNNNN.png above both the highest number used and the highest in the folder (never reused).
    private static func nextSnap(in folder: URL) -> (URL, Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let highestInFolder = names.compactMap { name -> Int? in
            guard name.hasPrefix("slyy-"), name.lowercased().hasSuffix(".png") else { return nil }
            let digits = name.dropFirst(5).dropLast(4)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(digits)
        }.max() ?? 0
        var n = max(highestInFolder, Settings.lastSnapNumber) + 1
        var url = folder.appendingPathComponent(String(format: "slyy-%05d.png", n))
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent(String(format: "slyy-%05d.png", n))
        }
        return (url, n)
    }
}

enum Clipboard {
    /// One pasteboard item with PNG + TIFF and the file URL: pastes as an image in apps and as a file in Finder.
    @MainActor
    static func copy(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        copy(png: data, file: url)
    }

    @MainActor
    static func copy(png data: Data, file url: URL?) {
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        if let url { item.setString(url.absoluteString, forType: .fileURL) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }
}

@MainActor
enum Alerts {
    static func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// Quit and reopen the app at `path` a second later (after this process is gone).
@MainActor func relaunch(_ path: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 1; open \"$0\"", path]
    try? p.run()
    NSApp.terminate(nil)
}

/// Rebrand (1.3.0): "Slyy Snap.app" -> "Slyy Shot.app" (updates arrive under the old name) and the
/// default folder ~/Pictures/Slyy Snap -> Slyy Shot. Returns true when relaunching from the new name.
@MainActor func migrateFromSlyySnap() -> Bool {
    let fm = FileManager.default, app = Bundle.main.bundleURL, folder = Settings.folder
    let oldFolder = folder.deletingLastPathComponent().appendingPathComponent("Slyy Snap")
    if folder.lastPathComponent == "Slyy Shot", !fm.fileExists(atPath: folder.path) { try? fm.moveItem(at: oldFolder, to: folder) }
    let renamed = app.deletingLastPathComponent().appendingPathComponent("Slyy Shot.app")
    guard app.lastPathComponent == "Slyy Snap.app", (try? fm.moveItem(at: app, to: renamed)) != nil else { return false }
    relaunch(renamed.path)
    return true
}
