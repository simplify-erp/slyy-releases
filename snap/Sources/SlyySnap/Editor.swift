import AppKit
import CoreImage
import UniformTypeIdentifiers

// Simple annotation editor: one window per image. Marks are kept as vectors
// (undoable) and flattened into the PNG on save/copy.

enum Tool: Int, CaseIterable {
    case arrow, rect, ellipse, pen, highlight, text, pixelate, crop

    var title: String {
        switch self {
        case .arrow: return "Arrow (A)"
        case .rect: return "Box (R)"
        case .ellipse: return "Ellipse (O)"
        case .pen: return "Pen (P)"
        case .highlight: return "Highlight (H)"
        case .text: return "Text (T)"
        case .pixelate: return "Pixelate (X)"
        case .crop: return "Crop (C)"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "square.grid.3x3.fill"
        case .crop: return "crop"
        }
    }

    var key: String {
        switch self {
        case .arrow: return "a"
        case .rect: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlight: return "h"
        case .text: return "t"
        case .pixelate: return "x"
        case .crop: return "c"
        }
    }
}

struct Mark {
    enum Kind {
        case arrow(CGPoint, CGPoint)
        case rect(CGRect)
        case ellipse(CGRect)
        case pen([CGPoint])
        case highlight(CGRect)
        case text(CGPoint, String)
        case pixelate(CGRect)
    }

    var kind: Kind
    var color: NSColor
    var width: CGFloat

    var isMeaningful: Bool {
        switch kind {
        case .arrow(let a, let b): return hypot(b.x - a.x, b.y - a.y) > 4
        case .rect(let r), .ellipse(let r), .highlight(let r), .pixelate(let r): return r.width > 3 && r.height > 3
        case .pen(let pts): return pts.count > 1
        case .text(_, let s): return !s.isEmpty
        }
    }
}

@MainActor
final class EditorCanvas: NSView {
    let image: NSImage
    private let pixelated: NSImage?
    private(set) var marks: [Mark] = []
    private(set) var crop: CGRect?
    private(set) var changeCount = 0
    private var undoStack: [([Mark], CGRect?)] = []
    private var draft: Mark?
    private var draftCrop: CGRect?
    private var start = CGPoint.zero

    var tool: Tool = .arrow { didSet { onToolChange?(tool) } }
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var onChange: (() -> Void)?
    var onToolChange: ((Tool) -> Void)?

    init(image: NSImage) {
        self.image = image
        self.pixelated = Self.pixelate(image)
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        render(draft.map { marks + [$0] } ?? marks)
        if let c = draftCrop ?? crop {
            let shade = NSBezierPath(rect: bounds)
            shade.appendRect(c)
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            shade.fill()
            let border = NSBezierPath(rect: c)
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.setLineDash([5, 4], count: 2, phase: 0)
            border.stroke()
        }
    }

    private func render(_ marks: [Mark]) {
        let full = NSRect(origin: .zero, size: image.size)
        image.draw(in: full)
        for m in marks { draw(m, in: full) }
    }

    static func fontSize(_ width: CGFloat) -> CGFloat { 12 + width * 4 }

    private func draw(_ m: Mark, in full: NSRect) {
        m.color.setStroke()
        m.color.setFill()
        switch m.kind {
        case .arrow(let a, let b):
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(12, m.width * 4)
            let shaftEnd = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
            let shaft = NSBezierPath()
            shaft.lineWidth = m.width
            shaft.lineCapStyle = .round
            shaft.move(to: a)
            shaft.line(to: shaftEnd)
            shaft.stroke()
            let tip = NSBezierPath()
            tip.move(to: b)
            tip.line(to: CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7)))
            tip.line(to: CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7)))
            tip.close()
            tip.fill()
        case .rect(let r):
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            p.lineWidth = m.width
            p.stroke()
        case .ellipse(let r):
            let p = NSBezierPath(ovalIn: r)
            p.lineWidth = m.width
            p.stroke()
        case .pen(let pts):
            guard let first = pts.first else { return }
            let p = NSBezierPath()
            p.lineWidth = m.width
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: first)
            for pt in pts.dropFirst() { p.line(to: pt) }
            p.stroke()
        case .highlight(let r):
            m.color.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: r).fill()
        case .text(let at, let s):
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: Self.fontSize(m.width)),
                .foregroundColor: m.color,
                .shadow: shadow,
            ]
            (s as NSString).draw(at: at, withAttributes: attrs)
        case .pixelate(let r):
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            if let pixelated {
                pixelated.draw(in: full)
            } else {
                NSColor.black.setFill()
                NSBezierPath(rect: r).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func pixelate(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIPixellate") else { return nil }
        let input = CIImage(cgImage: cg)
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(8, CGFloat(cg.width) / 100), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }

    // MARK: Editing

    private func commit(_ change: () -> Void) {
        undoStack.append((marks, crop))
        change()
        changeCount += 1
        needsDisplay = true
        onChange?()
    }

    func undo() {
        guard let last = undoStack.popLast() else {
            NSSound.beep()
            return
        }
        marks = last.0
        crop = last.1
        changeCount += 1
        needsDisplay = true
        onChange?()
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        start = point(event)
        switch tool {
        case .text: addText(at: start)
        case .pen: draft = Mark(kind: .pen([start]), color: color, width: lineWidth)
        default: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        switch tool {
        case .arrow: draft = Mark(kind: .arrow(start, p), color: color, width: lineWidth)
        case .rect: draft = Mark(kind: .rect(r), color: color, width: lineWidth)
        case .ellipse: draft = Mark(kind: .ellipse(r), color: color, width: lineWidth)
        case .highlight: draft = Mark(kind: .highlight(r), color: color, width: lineWidth)
        case .pixelate: draft = Mark(kind: .pixelate(r), color: color, width: lineWidth)
        case .pen:
            if case .pen(var pts)? = draft?.kind {
                pts.append(p)
                draft?.kind = .pen(pts)
            }
        case .crop: draftCrop = r
        case .text: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let finishedDraft = draft
        let finishedCrop = draftCrop
        draft = nil
        draftCrop = nil
        if tool == .crop, let c = finishedCrop, c.width > 4, c.height > 4 {
            commit { crop = c.integral }
        } else if let d = finishedDraft, d.isMeaningful {
            commit { marks.append(d) }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty, let t = Tool.allCases.first(where: { $0.key == chars }) {
            tool = t
        } else if event.keyCode == 53 { // Esc: drop the shape being drawn
            draft = nil
            draftCrop = nil
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }

    private func addText(at p: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "Add text"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Text"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        let size = Self.fontSize(lineWidth)
        let mark = Mark(kind: .text(CGPoint(x: p.x, y: p.y - size / 2), s), color: color, width: lineWidth)
        commit { marks.append(mark) }
    }

    // MARK: Export

    /// The image with all marks, cropped, at the original pixel size, as PNG.
    func renderedPNG() -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let size = image.size
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        render(marks)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var out = rep
        if let crop, let full = rep.cgImage {
            let sx = CGFloat(cg.width) / size.width
            let sy = CGFloat(cg.height) / size.height
            // CGImage cropping uses a top-left origin.
            let px = CGRect(x: crop.minX * sx, y: (size.height - crop.maxY) * sy,
                            width: crop.width * sx, height: crop.height * sy).integral
            if let cropped = full.cropping(to: px) {
                out = NSBitmapImageRep(cgImage: cropped)
                out.size = crop.size
            }
        }
        return out.representation(using: .png, properties: [:])
    }
}

@MainActor
final class Editor: NSObject, NSWindowDelegate {
    private static var editors: [Editor] = []

    static func open(_ url: URL) {
        if let existing = editors.first(where: { $0.url == url }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let image = NSImage(contentsOf: url), image.isValid else {
            Alerts.info("Cannot open image", url.path)
            return
        }
        let editor = Editor(url: url, image: image)
        editors.append(editor)
        editor.show()
    }

    static func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp]
        panel.directoryURL = Settings.folder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private(set) var url: URL
    let window: NSWindow
    private let canvas: EditorCanvas
    private let scroll = NSScrollView()
    private let tools = NSSegmentedControl()
    private var savedChangeCount = 0

    private var isDirty: Bool { canvas.changeCount != savedChangeCount }

    private init(url: URL, image: NSImage) {
        self.url = url
        canvas = EditorCanvas(image: image)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = url.lastPathComponent
        window.representedURL = url
        window.minSize = NSSize(width: 560, height: 320)
        buildUI()
        canvas.onChange = { [weak self] in self?.updateTitle() }
        canvas.onToolChange = { [weak self] t in self?.tools.selectedSegment = t.rawValue }
    }

    private func buildUI() {
        tools.segmentCount = Tool.allCases.count
        tools.trackingMode = .selectOne
        for t in Tool.allCases {
            if let img = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title) {
                tools.setImage(img, forSegment: t.rawValue)
            } else {
                tools.setLabel(String(t.title.prefix(1)), forSegment: t.rawValue)
            }
            tools.setToolTip(t.title, forSegment: t.rawValue)
            tools.setWidth(30, forSegment: t.rawValue)
        }
        tools.selectedSegment = canvas.tool.rawValue
        tools.target = self
        tools.action = #selector(toolChanged(_:))

        let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Color"
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let widths = NSPopUpButton(frame: .zero, pullsDown: false)
        widths.addItems(withTitles: ["Thin", "Medium", "Thick"])
        widths.selectItem(at: 1)
        widths.target = self
        widths.action = #selector(widthChanged(_:))
        widths.toolTip = "Line width / text size"

        let undo = NSButton(title: "Undo", target: self, action: #selector(undoMark(_:)))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copy(_:)))
        let save = NSButton(title: "Save", target: self, action: #selector(saveDocument(_:)))
        save.bezelColor = .controlAccentColor
        undo.toolTip = "Undo (⌘Z)"
        copy.toolTip = "Copy image (⌘C)"
        save.toolTip = "Save (⌘S); Save As: ⇧⌘S"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [tools, colorWell, widths, spacer, undo, copy, save])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 4
        scroll.backgroundColor = NSColor(white: 0.18, alpha: 1)
        scroll.drawsBackground = true

        let content = NSView()
        for v in [bar, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    private func show() {
        let barHeight: CGFloat = 44
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let img = canvas.image.size
        let fit = min(1, (visible.width * 0.85) / max(img.width, 1), (visible.height * 0.85 - barHeight) / max(img.height, 1))
        let size = NSSize(width: max(640, img.width * fit + 2), height: max(360, img.height * fit + barHeight + 2))
        window.setContentSize(size)
        window.center()
        scroll.magnification = fit
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    private func updateTitle() {
        window.isDocumentEdited = isDirty
    }

    // MARK: Actions (buttons + the Edit/File menu via the responder chain)

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        if let t = Tool(rawValue: sender.selectedSegment) { canvas.tool = t }
        window.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.color = sender.color
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        let widths: [CGFloat] = [2, 4, 8]
        canvas.lineWidth = widths[max(0, min(2, sender.indexOfSelectedItem))]
        window.makeFirstResponder(canvas)
    }

    @objc func undoMark(_ sender: Any?) {
        canvas.undo()
    }

    @objc func copy(_ sender: Any?) {
        guard let png = canvas.renderedPNG() else { return }
        Clipboard.copy(png: png, file: nil)
        NSSound(named: "Tink")?.play()
    }

    @objc func saveDocument(_ sender: Any?) {
        if ["png"].contains(url.pathExtension.lowercased()) {
            write(to: url)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " edited.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let target = panel.url else { return }
            self.write(to: target)
        }
    }

    @discardableResult
    private func write(to target: URL) -> Bool {
        guard let png = canvas.renderedPNG() else {
            Alerts.info("Save failed", "Could not render the image.")
            return false
        }
        do {
            try png.write(to: target, options: .atomic)
        } catch {
            Alerts.info("Save failed", error.localizedDescription)
            return false
        }
        url = target
        window.title = target.lastPathComponent
        window.representedURL = target
        savedChangeCount = canvas.changeCount
        updateTitle()
        if Settings.copyToClipboard { Clipboard.copy(png: png, file: target) }
        return true
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(url.lastPathComponent)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if ["png"].contains(url.pathExtension.lowercased()) { return write(to: url) }
            saveDocumentAs(nil)
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Editor.editors.removeAll { $0 === self }
    }
}
