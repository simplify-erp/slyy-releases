import AppKit

/// Floating thumbnail shown after a capture (bottom right of the screen with
/// the mouse): Edit / Copy / Show in Finder / close. Disappears after a few
/// seconds unless the mouse is over it. Clicking the image also opens the editor.
@MainActor
final class SnapPreview: NSObject {
    private static var current: SnapPreview?

    static func show(_ url: URL) {
        current?.close()
        guard let image = NSImage(contentsOf: url) else { return }
        let preview = SnapPreview(url: url, image: image)
        current = preview
        preview.present()
    }

    private let url: URL
    private let panel: NSPanel
    private var timer: Timer?

    private init(url: URL, image: NSImage) {
        self.url = url
        let maxW: CGFloat = 240
        let maxH: CGFloat = 150
        let scale = min(maxW / max(image.size.width, 1), maxH / max(image.size.height, 1), 1)
        let thumb = NSSize(width: max(140, image.size.width * scale), height: max(60, image.size.height * scale))
        let pad: CGFloat = 8
        let buttonRow: CGFloat = 30
        let width = max(thumb.width + 2 * pad, 260)
        let size = NSSize(width: width, height: thumb.height + buttonRow + 3 * pad)

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let imageButton = NSButton(frame: NSRect(x: (width - thumb.width) / 2, y: buttonRow + 2 * pad,
                                                 width: thumb.width, height: thumb.height))
        imageButton.image = image
        imageButton.imageScaling = .scaleProportionallyUpOrDown
        imageButton.isBordered = false
        imageButton.title = ""
        imageButton.target = self
        imageButton.action = #selector(edit)
        imageButton.toolTip = "Edit"
        background.addSubview(imageButton)

        let edit = NSButton(title: "Edit", target: self, action: #selector(edit))
        edit.bezelColor = .controlAccentColor
        edit.keyEquivalent = "\r"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        let reveal = NSButton(title: "Show", target: self, action: #selector(reveal))
        reveal.toolTip = "Show in Finder"
        let close = NSButton(title: "✕", target: self, action: #selector(closeClicked))
        close.toolTip = "Close"
        for b in [edit, copy, reveal, close] { b.controlSize = .small }
        let row = NSStackView(views: [edit, copy, reveal, close])
        row.orientation = .horizontal
        row.spacing = 6
        row.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: buttonRow)
        row.distribution = .fillProportionally
        background.addSubview(row)

        panel.contentView = background
    }

    private func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.minY + 16))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        scheduleDismiss(after: 8)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.dismissIfIdle() }
        }
    }

    private func dismissIfIdle() {
        if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
            scheduleDismiss(after: 2)
        } else {
            close()
        }
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        if SnapPreview.current === self { SnapPreview.current = nil }
    }

    @objc private func edit() {
        close()
        Editor.open(url)
    }

    @objc private func copyImage() {
        Clipboard.copy(url)
        NSSound(named: "Tink")?.play()
        scheduleDismiss(after: 3)
    }

    @objc private func reveal() {
        close()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func closeClicked() {
        close()
    }
}
