import AppKit

/// Editable shape in window-normalised coordinates (origin top-left).
struct EditableShape: Equatable {
    enum Kind: String { case rect, square, ellipse }
    var kind: Kind
    var rect: CGRect
    var mode: String           // "pixellate" | "blur" | "solid"
    var name: String

    var presetShape: String { kind == .ellipse ? "ellipse" : "rect" }
}

/// Overlay editor: transparent view laid exactly over the target window. Shapes show the
/// pixellated screenshot inside them; drag empty space to create, drag a shape to move, drag a
/// handle to resize. Delete removes the selection.
final class ShapeEditorView: NSView {
    var shapes: [EditableShape] = [] { didSet { needsDisplay = true; onChange?() } }
    var selected: Int? { didSet { needsDisplay = true; onSelectionChange?() } }
    var tool: EditableShape.Kind = .rect
    var defaultMode = "pixellate"
    var onChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private let pixellated: NSImage?
    private let handleSize: CGFloat = 9
    private enum Drag { case create(start: NSPoint), move(index: Int, origin: NSPoint, start: CGRect), resize(index: Int, handle: Int, start: CGRect) }
    private var drag: Drag?
    private var dragPreview: CGRect?

    init(pixellated: NSImage?) {
        self.pixellated = pixellated
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Geometry helpers

    private func toView(_ n: CGRect) -> NSRect {
        NSRect(x: n.minX * bounds.width, y: n.minY * bounds.height, width: n.width * bounds.width, height: n.height * bounds.height)
    }
    private func toNorm(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX / bounds.width, y: r.minY / bounds.height, width: r.width / bounds.width, height: r.height / bounds.height).clamped01
    }
    private func path(for shape: EditableShape, in r: NSRect) -> NSBezierPath {
        shape.kind == .ellipse ? NSBezierPath(ovalIn: r) : NSBezierPath(rect: r)
    }
    /// 8 handles: 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L
    private func handleRects(_ r: NSRect) -> [NSRect] {
        let pts = [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
                   NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY),
                   NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
        return pts.map { NSRect(x: $0.x - handleSize / 2, y: $0.y - handleSize / 2, width: handleSize, height: handleSize) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0, alpha: 0.12).setFill()
        bounds.fill()
        NSColor.systemGreen.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); border.lineWidth = 2; border.stroke()

        var all = shapes.enumerated().map { ($0.offset, $0.element, toView($0.element.rect)) }
        if let p = dragPreview, case .create = drag {
            all.append((-1, EditableShape(kind: tool, rect: .zero, mode: defaultMode, name: ""), toView(p)))
        }
        for (i, shape, r) in all {
            guard r.width > 0, r.height > 0 else { continue }
            let p = path(for: shape, in: r)
            NSGraphicsContext.saveGraphicsState()
            p.addClip()
            if shape.mode == "solid" {
                NSColor.black.setFill(); r.fill()
            } else if let img = pixellated {
                img.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                if shape.mode == "blur" { NSColor(calibratedWhite: 0.5, alpha: 0.35).setFill(); r.fill() }
            } else {
                NSColor(calibratedWhite: 0.3, alpha: 0.8).setFill(); r.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            let isSel = i == selected
            (isSel ? NSColor.systemYellow : NSColor.systemGreen).setStroke()
            p.lineWidth = isSel ? 2.5 : 1.5
            p.stroke()
            if isSel {
                NSColor.systemYellow.setFill()
                for h in handleRects(r) { NSBezierPath(ovalIn: h).fill() }
            }
            if i >= 0 {
                let label = "\(shape.name) · \(shape.mode)"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white]
                let size = label.size(withAttributes: attrs)
                let bg = NSRect(x: r.minX + 4, y: r.minY + 4, width: size.width + 8, height: size.height + 2)
                NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
                label.draw(at: NSPoint(x: bg.minX + 4, y: bg.minY + 1), withAttributes: attrs)
            }
        }
    }

    // MARK: Mouse

    private func hitTest(_ p: NSPoint) -> (Int, Int?)? {   // (shape index, handle index)
        if let s = selected, s < shapes.count {
            let r = toView(shapes[s].rect)
            for (h, hr) in handleRects(r).enumerated() where hr.insetBy(dx: -3, dy: -3).contains(p) { return (s, h) }
        }
        for (i, shape) in shapes.enumerated().reversed() {
            let r = toView(shape.rect)
            if path(for: shape, in: r).contains(p) || r.insetBy(dx: -2, dy: -2).contains(p) { return (i, nil) }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let (i, h) = hitTest(p) {
            selected = i
            if let h = h { drag = .resize(index: i, handle: h, start: shapes[i].rect) }
            else { drag = .move(index: i, origin: p, start: shapes[i].rect) }
        } else {
            selected = nil
            drag = .create(start: p)
            dragPreview = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .create(let start):
            var r = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            if tool == .square || event.modifierFlags.contains(.shift) {
                let side = max(r.width, r.height)
                r = NSRect(x: p.x < start.x ? start.x - side : start.x, y: p.y < start.y ? start.y - side : start.y, width: side, height: side)
            }
            dragPreview = toNorm(r)
            needsDisplay = true
        case .move(let i, let origin, let start):
            let dx = (p.x - origin.x) / bounds.width, dy = (p.y - origin.y) / bounds.height
            var r = start.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(0, r.minX), 1 - r.width)
            r.origin.y = min(max(0, r.minY), 1 - r.height)
            shapes[i].rect = r
        case .resize(let i, let h, let start):
            var r = toView(start)
            let minSize: CGFloat = 8
            if [0, 6, 7].contains(h) { let nx = min(p.x, r.maxX - minSize); r.size.width = r.maxX - nx; r.origin.x = nx }
            if [2, 3, 4].contains(h) { r.size.width = max(minSize, p.x - r.minX) }
            if [0, 1, 2].contains(h) { let ny = min(p.y, r.maxY - minSize); r.size.height = r.maxY - ny; r.origin.y = ny }
            if [4, 5, 6].contains(h) { r.size.height = max(minSize, p.y - r.minY) }
            if shapes[i].kind == .square {
                let side = max(r.width, r.height)
                if [0, 6, 7].contains(h) { r.origin.x = r.maxX - side }
                if [0, 1, 2].contains(h) { r.origin.y = r.maxY - side }
                r.size = NSSize(width: side, height: side)
            }
            shapes[i].rect = toNorm(r.intersection(bounds))
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .create = drag, let n = dragPreview, n.width > 0.005, n.height > 0.005 {
            shapes.append(EditableShape(kind: tool, rect: n, mode: defaultMode, name: "region \(shapes.count + 1)"))
            selected = shapes.count - 1
        }
        drag = nil
        dragPreview = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x33, 0x75: deleteSelected()
        case 0x35: onCancel?()
        case 0x24, 0x4C: onCommit?()
        case 0x7B, 0x7C, 0x7D, 0x7E:   // arrows nudge the selection by 1 px
            guard let s = selected else { return }
            let dx: CGFloat = event.keyCode == 0x7B ? -1 : event.keyCode == 0x7C ? 1 : 0
            let dy: CGFloat = event.keyCode == 0x7E ? -1 : event.keyCode == 0x7D ? 1 : 0
            shapes[s].rect = shapes[s].rect.offsetBy(dx: dx / bounds.width, dy: dy / bounds.height).clamped01
        default: super.keyDown(with: event)
        }
    }

    func deleteSelected() {
        guard let s = selected, s < shapes.count else { return }
        shapes.remove(at: s)
        selected = nil
    }

    func addTemplate(_ rect: CGRect, kind: EditableShape.Kind, name: String) {
        shapes.append(EditableShape(kind: kind, rect: rect, mode: defaultMode, name: name))
        selected = shapes.count - 1
    }
}
