import AppKit

enum CaptureMode {
    case area, window, screen
}

/// Takes screenshots with the system's /usr/sbin/screencapture, saves them as
/// PNG to Settings.folder and (optionally) copies them to the clipboard.
@MainActor
final class Snapper {
    private(set) var lastSnap: URL?
    private var busy = false

    func capture(_ mode: CaptureMode) {
        guard !busy else { return }
        // First run: show the system's Screen Recording prompt. Without the
        // permission screencapture still works but shows only the desktop.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        let folder = Settings.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Alerts.info("Cannot create snap folder", "\(folder.path)\n\n\(error.localizedDescription)")
            return
        }
        let url = folder.appendingPathComponent(Self.fileName())
        var args = ["-x", "-t", "png"] // -x: no system sound (we play our own)
        switch mode {
        case .area: args.append("-i") // drag a rectangle; Space toggles window mode, Esc cancels
        case .window: args += ["-i", "-w"] // click a window
        case .screen: args.append("-m") // main display
        }
        args.append(url.path)

        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                NSLog("Slyy Snap: screencapture failed: \(error)")
            }
            DispatchQueue.main.async {
                self.busy = false
                // No file: the user pressed Esc.
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                self.lastSnap = url
                if Settings.copyToClipboard { Clipboard.copy(url) }
                if Settings.playSound { NSSound(named: "Tink")?.play() }
            }
        }
    }

    func copyLast() {
        if let lastSnap { Clipboard.copy(lastSnap) }
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

    private static func fileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Snap \(f.string(from: Date())).png"
    }
}

enum Clipboard {
    /// One pasteboard item with PNG + TIFF data and the file URL: pastes as an
    /// image into chats/docs and as a file into Finder.
    @MainActor
    static func copy(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        item.setString(url.absoluteString, forType: .fileURL)
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
