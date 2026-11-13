import AppKit
import CoreImage
import UniformTypeIdentifiers

// Simple annotation editor: one window per image. Marks are kept as vectors
// (undoable) and flattened into the PNG on save/copy.

enum Tool: Int, CaseIterable {
    case move, arrow, rect, ellipse, pen, highlight, text, pixelate, crop

    private var info: (title: String, symbol: String, key: String) {
        switch self {
        case .move: return ("Move (V)", "hand.point.up.left", "v")
        case .arrow: return ("Arrow (A)", "arrow.up.right", "a")
        case .rect: return ("Box (R)", "rectangle", "r")
        case .ellipse: return ("Ellipse (O)", "circle", "o")
        case .pen: return ("Pen (P)", "scribble", "p")
        case .highlight: return ("Highlight (H)", "highlighter", "h")
        case .text: return ("Text (T)", "textformat", "t")
        case .pixelate: return ("Pixelate (X)", "square.grid.3x3.fill", "x")
        case .crop: return ("Crop (C)", "crop", "c")
        }
    }

    var title: String { info.title }
    var symbol: String { info.symbol }
    var key: String { info.key }
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

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Mark {
        func o(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        var m = self
        switch kind {
        case .arrow(let a, let b): m.kind = .arrow(o(a), o(b))
        case .rect(let r): m.kind = .rect(r.offsetBy(dx: dx, dy: dy))
        case .ellipse(let r): m.kind = .ellipse(r.offsetBy(dx: dx, dy: dy))
        case .pen(let pts): m.kind = .pen(pts.map(o))
        case .highlight(let r): m.kind = .highlight(r.offsetBy(dx: dx, dy: dy))
        case .text(let p, let s): m.kind = .text(o(p), s)
        case .pixelate(let r): m.kind = .pixelate(r.offsetBy(dx: dx, dy: dy))
        }
        return m
    }

    /// Whether a click at `p` grabs this mark (generous tolerance).
    func contains(_ p: CGPoint) -> Bool {
        let tol = max(6, width * 1.5)
        func nearSegment(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)) <= tol
        }
        switch kind {
        case .arrow(let a, let b): return nearSegment(a, b)
        case .rect(let r), .ellipse(let r), .highlight(let r), .pixelate(let r):
            return r.insetBy(dx: -tol, dy: -tol).contains(p)
        case .pen(let pts):
            if pts.count == 1 { return hypot(p.x - pts[0].x, p.y - pts[0].y) <= tol }
            return zip(pts, pts.dropFirst()).contains { nearSegment($0, $1) }
        case .text(let at, let s):
            let size = (s as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: EditorCanvas.fontSize(width))])
            return CGRect(origin: at, size: size).insetBy(dx: -4, dy: -4).contains(p)
        }
    }

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
final class EditorCanvas: NSView, NSTextFieldDelegate {
    let image: NSImage
    private let pixelated: NSImage?
    private(set) var marks: [Mark] = []
    private(set) var crop: CGRect?
    private(set) var changeCount = 0
    private var undoStack: [([Mark], CGRect?)] = []
    private var draft: Mark?
    private var draftCrop: CGRect?
    private var start = CGPoint.zero

    var tool: Tool = .arrow {
        didSet {
            onToolChange?(tool)
            window?.invalidateCursorRects(for: self)
        }
    }
    private var moving: (index: Int, original: [Mark])?
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .move ? .openHand : .crosshair) }

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

    nonisolated static func fontSize(_ width: CGFloat) -> CGFloat { 12 + width * 4 }

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
        case .rect(let r), .ellipse(let r):
            let p: NSBezierPath
            if case .rect = m.kind { p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3) } else { p = NSBezierPath(ovalIn: r) }
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
        let before = (marks, crop)
        change()
        recordChange(undoTo: before)
    }

    private func recordChange(undoTo before: ([Mark], CGRect?)) {
        undoStack.append(before)
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
        case .move:
            if let i = marks.indices.reversed().first(where: { marks[$0].contains(start) }) {
                moving = (i, marks)
                NSCursor.closedHand.set()
            }
        case .text: addText(at: start)
        case .pen: draft = Mark(kind: .pen([start]), color: color, width: lineWidth)
        default: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        switch tool {
        case .move:
            if let m = moving {
                marks[m.index] = m.original[m.index].offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            }
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
        if let m = moving {
            moving = nil
            NSCursor.openHand.set()
            if hypot(point(event).x - start.x, point(event).y - start.y) > 0.5 {
                recordChange(undoTo: (m.original, crop))
            } else {
                marks = m.original
                needsDisplay = true
            }
            return
        }
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

    // MARK: Text (typed in place)

    private var textField: NSTextField?
    private var textCancelled = false

    private func addText(at p: CGPoint) {
        let size = Self.fontSize(lineWidth)
        let font = NSFont.boldSystemFont(ofSize: size)
        let height = ceil(size * 1.4)
        let field = NSTextField(frame: NSRect(x: p.x - 3, y: p.y - height / 2, width: max(120, size * 6), height: height))
        field.font = font
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .exterior
        field.placeholderString = "Type text"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        addSubview(field)
        textField = field
        textCancelled = false
        window?.makeFirstResponder(field)
    }

    /// End text entry (places the text unless cancelled); used before save/copy.
    func finishText() {
        if textField != nil { window?.makeFirstResponder(self) }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField, let font = field.font else { return }
        let w = (field.stringValue as NSString).size(withAttributes: [.font: font]).width + 24
        field.frame.size.width = min(max(120, w), max(120, bounds.width - field.frame.minX))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            textCancelled = true
            window?.makeFirstResponder(self)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fieldColor = field.textColor ?? color
        let fontSize = field.font?.pointSize ?? Self.fontSize(lineWidth)
        let frame = field.frame
        field.removeFromSuperview()
        if textCancelled || text.isEmpty {
            needsDisplay = true
            return
        }
        // Same spot as typed: text field inset 2 pt, line box vertically centered.
        let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.boldSystemFont(ofSize: fontSize))
        let at = CGPoint(x: frame.minX + 2, y: frame.minY + max(0, (frame.height - lineHeight) / 2))
        let width = (fontSize - 12) / 4
        let mark = Mark(kind: .text(at, text), color: fieldColor, width: width)
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
final class Editor: NSObject, NSWindowDelegate, NSPopoverDelegate {
    private static var editors: [Editor] = []
    /// Called after a file was renamed in an editor (old URL, new URL).
    static var onRename: ((URL, URL) -> Void)?

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
    let window: EditorWindow
    private let canvas: EditorCanvas
    private let scroll = NSScrollView()
    private let tools = NSSegmentedControl()
    private var savedChangeCount = 0

    private var isDirty: Bool { canvas.changeCount != savedChangeCount }

    private init(url: URL, image: NSImage) {
        self.url = url
        canvas = EditorCanvas(image: image)
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 320)
        setURL(url)
        buildUI()
        canvas.onChange = { [weak self] in self?.updateTitle() }
        canvas.onToolChange = { [weak self] t in self?.tools.selectedSegment = t.rawValue }
        window.onTitleClick = { [weak self] rect in self?.showRename(at: rect) }
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
        canvas.finishText()
        guard let png = canvas.renderedPNG() else { return }
        Clipboard.copy(png: png, file: nil)
        NSSound(named: "Tink")?.play()
    }

    private var canSaveInPlace: Bool { url.pathExtension.lowercased() == "png" }

    @objc func saveDocument(_ sender: Any?) {
        canvas.finishText()
        if canSaveInPlace { write(to: url) } else { saveDocumentAs(sender) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-edited.png"
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
        setURL(target)
        savedChangeCount = canvas.changeCount
        updateTitle()
        if Settings.copyToClipboard { Clipboard.copy(png: png, file: target) }
        return true
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.finishText()
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(url.lastPathComponent)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canSaveInPlace { return write(to: url) }
            saveDocumentAs(nil)
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Rename (click on the title)

    private var renamePopover: NSPopover?

    private func showRename(at rect: NSRect) {
        guard renamePopover == nil, let frameView = window.contentView?.superview else { return }
        let field = NSTextField(string: url.deletingPathExtension().lastPathComponent)
        field.frame = NSRect(x: 12, y: 12, width: 240, height: 24)
        field.target = self
        field.action = #selector(renameCommitted(_:))
        let ext = NSTextField(labelWithString: url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
        ext.frame = NSRect(x: 256, y: 15, width: 44, height: 18)
        ext.textColor = .secondaryLabelColor
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        view.addSubview(field)
        view.addSubview(ext)
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        renamePopover = popover
        popover.show(relativeTo: rect, of: frameView, preferredEdge: .minY)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func renameCommitted(_ sender: NSTextField) {
        renamePopover?.close()
        rename(to: sender.stringValue)
    }

    private func rename(to newName: String) {
        var base = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if !url.pathExtension.isEmpty, base.lowercased().hasSuffix("." + url.pathExtension.lowercased()) {
            base = String(base.dropLast(url.pathExtension.count + 1))
        }
        guard !base.isEmpty, !base.hasPrefix(".") else { return }
        var target = url.deletingLastPathComponent().appendingPathComponent(base)
        if !url.pathExtension.isEmpty { target.appendPathExtension(url.pathExtension) }
        guard target.path != url.path else { return }
        let onlyCaseChanges = target.path.lowercased() == url.path.lowercased()
        if !onlyCaseChanges, FileManager.default.fileExists(atPath: target.path) {
            Alerts.info("Cannot rename", "\"\(target.lastPathComponent)\" already exists in this folder.")
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            Alerts.info("Cannot rename", error.localizedDescription)
            return
        }
        let old = url
        setURL(target)
        Editor.onRename?(old, target)
    }

    private func setURL(_ new: URL) {
        url = new
        window.title = new.lastPathComponent
        window.representedURL = new
    }

    func windowWillClose(_ notification: Notification) {
        Editor.editors.removeAll { $0 === self }
    }
}

extension Editor {
    func popoverDidClose(_ notification: Notification) {
        renamePopover = nil
        window.makeFirstResponder(canvas)
    }
}

/// Editor window that reports a single click on its title (not a drag, not a
/// double-click) with the title's rectangle in window coordinates.
@MainActor
final class EditorWindow: NSWindow {
    var onTitleClick: ((NSRect) -> Void)?
    private var pending: (origin: NSPoint, rect: NSRect)?
    private var clickWork: DispatchWorkItem?

    private func titleRect() -> NSRect {
        let layout = contentLayoutRect
        let barHeight = frame.height - layout.maxY
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.titleBarFont(ofSize: 0)]
        let textWidth = (title as NSString).size(withAttributes: attrs).width
        let width = min(frame.width - 160, textWidth + (representedURL == nil ? 16 : 40))
        return NSRect(x: (frame.width - width) / 2, y: layout.maxY, width: width, height: barHeight)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            clickWork?.cancel()
            clickWork = nil
            pending = nil
            let rect = titleRect()
            if event.clickCount == 1, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               rect.contains(event.locationInWindow) {
                pending = (frame.origin, rect)
            }
        }
        super.sendEvent(event)
        switch event.type {
        case .leftMouseDown where pending != nil && NSEvent.pressedMouseButtons & 1 == 0:
            finishTitleClick() // the titlebar's own tracking loop consumed the mouse-up
        case .leftMouseUp where pending != nil:
            finishTitleClick()
        default:
            break
        }
    }

    private func finishTitleClick() {
        guard let p = pending else { return }
        pending = nil
        guard frame.origin == p.origin else { return } // the window was dragged
        // Wait out a possible double-click (zoom).
        let work = DispatchWorkItem { [weak self] in self?.onTitleClick?(p.rect) }
        clickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
}
