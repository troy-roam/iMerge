import AppKit
import Foundation

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, pointer, pen, text

    var id: String { rawValue }
    var isDrawing: Bool { self != .select }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .pointer: "Cursor"
        case .pen: "Sketch"
        case .text: "Text"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .pointer: "cursorarrow.click"
        case .pen: "scribble"
        case .text: "textformat"
        }
    }
}

/// A single drawing primitive. The live canvas and the exporter both render these,
/// so an annotation can never look different on screen than it does in the output.
struct DrawOp {
    let path: CGPath
    let color: NSColor
    let isFill: Bool
    let lineWidth: CGFloat
    /// Decoration drawn under the ink (the pointer's white outline), never a click target.
    var isHalo: Bool = false
}

enum AnnotationKind {
    case arrow(start: CGPoint, end: CGPoint)
    case pointer(tip: CGPoint)
    case pen(points: [CGPoint])
    case text(origin: CGPoint, value: String, fontSize: CGFloat)
}

enum ArrowEndpoint {
    case start, end
}

struct Annotation: Identifiable {
    let id: UUID
    var kind: AnnotationKind
    var color: NSColor
    var lineWidth: CGFloat
    var z: Double

    init(id: UUID = UUID(), kind: AnnotationKind, color: NSColor, lineWidth: CGFloat, z: Double = 0) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
        self.z = z
    }
}

extension Annotation {
    /// Classic macOS pointer outline, tip at (0,0), normalized to a 0.86-tall box.
    private static let pointerOutline: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.00),
        CGPoint(x: 0.00, y: 0.72),
        CGPoint(x: 0.20, y: 0.55),
        CGPoint(x: 0.30, y: 0.85),
        CGPoint(x: 0.42, y: 0.80),
        CGPoint(x: 0.32, y: 0.50),
        CGPoint(x: 0.55, y: 0.50)
    ]

    var pointerHeight: CGFloat { max(18, lineWidth * 8) }

    var drawOps: [DrawOp] {
        switch kind {
        case let .arrow(start, end):
            return arrowOps(start: start, end: end)
        case let .pointer(tip):
            return pointerOps(tip: tip)
        case let .pen(points):
            return [DrawOp(path: penPath(points: points), color: color, isFill: false, lineWidth: lineWidth)]
        case .text:
            return []
        }
    }

    var textInfo: (origin: CGPoint, value: String, fontSize: CGFloat)? {
        guard case let .text(origin, value, fontSize) = kind else { return nil }
        return (origin, value, fontSize)
    }

    func textAttributes(scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: (textInfo?.fontSize ?? 24) * scale, weight: .semibold),
            .foregroundColor: color
        ]
    }

    private var textBounds: CGRect? {
        guard let info = textInfo else { return nil }
        let size = (info.value as NSString).size(withAttributes: textAttributes())
        return CGRect(origin: info.origin, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
    }

    private func arrowOps(start: CGPoint, end: CGPoint) -> [DrawOp] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length
        let uy = dy / length

        let headLength = min(max(lineWidth * 4.2, 12), length)
        let headHalf = max(lineWidth * 2.1, 5)
        let baseCenter = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)

        let shaft = CGMutablePath()
        shaft.move(to: start)
        // Stop slightly inside the head so the stroke cap doesn't poke past the tip.
        shaft.addLine(to: CGPoint(x: end.x - ux * headLength * 0.85, y: end.y - uy * headLength * 0.85))

        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(x: baseCenter.x - uy * headHalf, y: baseCenter.y + ux * headHalf))
        head.addLine(to: CGPoint(x: baseCenter.x + uy * headHalf, y: baseCenter.y - ux * headHalf))
        head.closeSubpath()

        return [
            DrawOp(path: shaft, color: color, isFill: false, lineWidth: lineWidth),
            DrawOp(path: head, color: color, isFill: true, lineWidth: 0)
        ]
    }

    private func pointerOps(tip: CGPoint) -> [DrawOp] {
        let scale = pointerHeight / 0.86
        let path = CGMutablePath()
        for (index, point) in Self.pointerOutline.enumerated() {
            let mapped = CGPoint(x: tip.x + point.x * scale, y: tip.y + point.y * scale)
            if index == 0 {
                path.move(to: mapped)
            } else {
                path.addLine(to: mapped)
            }
        }
        path.closeSubpath()

        // White halo first, then the fill, so the cursor stays visible on any image.
        return [
            DrawOp(
                path: path,
                color: .white,
                isFill: false,
                lineWidth: max(2, pointerHeight * 0.12),
                isHalo: true
            ),
            DrawOp(path: path, color: color, isFill: true, lineWidth: 0)
        ]
    }

    private func penPath(points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }

        guard points.count > 1 else {
            let radius = max(lineWidth / 2, 1)
            path.addEllipse(in: CGRect(
                x: first.x - radius,
                y: first.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            return path
        }

        // Quadratic segments through midpoints smooth out the raw pointer samples.
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Padded so strokes and the pointer halo are never clipped from the export.
    var bounds: CGRect {
        if let textBounds {
            return textBounds.insetBy(dx: -4, dy: -3)
        }
        var result: CGRect?
        for op in drawOps {
            let box = op.isFill
                ? op.path.boundingBox
                : op.path.boundingBox.insetBy(dx: -op.lineWidth / 2, dy: -op.lineWidth / 2)
            result = result.map { $0.union(box) } ?? box
        }
        return (result ?? .zero).insetBy(dx: -2, dy: -2)
    }

    /// Combined geometry used for click targets, so clicks off the ink pass through.
    var hitPath: CGPath {
        if let textBounds {
            return CGPath(rect: textBounds, transform: nil)
        }
        let combined = CGMutablePath()
        for op in drawOps where !op.isHalo {
            combined.addPath(op.path)
        }
        return combined
    }

    func translated(by translation: CGSize) -> Annotation {
        var copy = self
        func move(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + translation.width, y: point.y + translation.height)
        }

        switch kind {
        case let .arrow(start, end):
            copy.kind = .arrow(start: move(start), end: move(end))
        case let .pointer(tip):
            copy.kind = .pointer(tip: move(tip))
        case let .pen(points):
            copy.kind = .pen(points: points.map(move))
        case let .text(origin, value, fontSize):
            copy.kind = .text(origin: move(origin), value: value, fontSize: fontSize)
        }
        return copy
    }

    func movingEndpoint(_ endpoint: ArrowEndpoint, by translation: CGSize) -> Annotation {
        guard case let .arrow(start, end) = kind else { return self }
        var copy = self
        let moved = CGPoint(
            x: (endpoint == .start ? start.x : end.x) + translation.width,
            y: (endpoint == .start ? start.y : end.y) + translation.height
        )
        copy.kind = endpoint == .start ? .arrow(start: moved, end: end) : .arrow(start: start, end: moved)
        return copy
    }

    /// Applies the same uniform transform used when fitting images to the window.
    func mapped(_ transform: (CGPoint) -> CGPoint, widthScale: CGFloat) -> Annotation {
        var copy = self
        copy.lineWidth = lineWidth * widthScale

        switch kind {
        case let .arrow(start, end):
            copy.kind = .arrow(start: transform(start), end: transform(end))
        case let .pointer(tip):
            copy.kind = .pointer(tip: transform(tip))
        case let .pen(points):
            copy.kind = .pen(points: points.map(transform))
        case let .text(origin, value, fontSize):
            copy.kind = .text(
                origin: transform(origin),
                value: value,
                fontSize: fontSize * widthScale
            )
        }
        return copy
    }

    func replacingText(_ value: String) -> Annotation {
        guard case let .text(origin, _, fontSize) = kind else { return self }
        var copy = self
        copy.kind = .text(origin: origin, value: value, fontSize: fontSize)
        return copy
    }

    func replacingFontSize(_ fontSize: CGFloat) -> Annotation {
        guard case let .text(origin, value, _) = kind else { return self }
        var copy = self
        copy.kind = .text(origin: origin, value: value, fontSize: fontSize)
        return copy
    }

    var arrowEndpoints: (start: CGPoint, end: CGPoint)? {
        guard case let .arrow(start, end) = kind else { return nil }
        return (start, end)
    }
}
