import AppKit
import Foundation

/// One image placed freely on the canvas. `frame` is in canvas points, y grows downward.
struct ImageItem: Identifiable {
    let id: UUID
    let image: NSImage
    var frame: CGRect
    var z: Double

    init(id: UUID = UUID(), image: NSImage, frame: CGRect, z: Double = 0) {
        self.id = id
        self.image = image
        self.frame = frame
        self.z = z
    }

    var nativeSize: CGSize {
        let size = image.size
        return size.width > 0 && size.height > 0 ? size : CGSize(width: 1, height: 1)
    }

    var aspectRatio: CGFloat {
        nativeSize.width / nativeSize.height
    }
}

enum ResizeCorner: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

enum Snapper {
    static let threshold: CGFloat = 8
    static let minimumSide: CGFloat = 30

    struct Result {
        var origin: CGPoint
        var guideX: [CGFloat]
        var guideY: [CGFloat]
    }

    /// Nudges a dragged frame so its edges or center line up with the other frames.
    static func snap(frame: CGRect, against others: [CGRect]) -> Result {
        var result = Result(origin: frame.origin, guideX: [], guideY: [])
        guard !others.isEmpty else { return result }

        let movingX: [(offset: CGFloat, value: CGFloat)] = [
            (0, frame.minX), (frame.width / 2, frame.midX), (frame.width, frame.maxX)
        ]
        let movingY: [(offset: CGFloat, value: CGFloat)] = [
            (0, frame.minY), (frame.height / 2, frame.midY), (frame.height, frame.maxY)
        ]
        let targetsX = others.flatMap { [$0.minX, $0.midX, $0.maxX] }
        let targetsY = others.flatMap { [$0.minY, $0.midY, $0.maxY] }

        if let match = bestMatch(moving: movingX, targets: targetsX) {
            result.origin.x = match.target - match.offset
            result.guideX = [match.target]
        }
        if let match = bestMatch(moving: movingY, targets: targetsY) {
            result.origin.y = match.target - match.offset
            result.guideY = [match.target]
        }
        return result
    }

    private static func bestMatch(
        moving: [(offset: CGFloat, value: CGFloat)],
        targets: [CGFloat]
    ) -> (offset: CGFloat, target: CGFloat)? {
        var best: (offset: CGFloat, target: CGFloat, distance: CGFloat)?
        for candidate in moving {
            for target in targets {
                let distance = abs(candidate.value - target)
                guard distance <= threshold else { continue }
                if best == nil || distance < best!.distance {
                    best = (candidate.offset, target, distance)
                }
            }
        }
        guard let best else { return nil }
        return (best.offset, best.target)
    }

    /// Resizes proportionally while keeping the opposite corner pinned.
    static func resize(start: CGRect, corner: ResizeCorner, translation: CGSize, aspectRatio: CGFloat) -> CGRect {
        let delta: CGFloat
        switch corner {
        case .bottomTrailing, .topTrailing:
            delta = translation.width
        case .bottomLeading, .topLeading:
            delta = -translation.width
        }

        let width = max(start.width + delta, minimumSide)
        let height = max(width / aspectRatio, minimumSide)
        let size = CGSize(width: height * aspectRatio, height: height)

        let origin: CGPoint
        switch corner {
        case .bottomTrailing:
            origin = start.origin
        case .bottomLeading:
            origin = CGPoint(x: start.maxX - size.width, y: start.minY)
        case .topTrailing:
            origin = CGPoint(x: start.minX, y: start.maxY - size.height)
        case .topLeading:
            origin = CGPoint(x: start.maxX - size.width, y: start.maxY - size.height)
        }
        return CGRect(origin: origin, size: size)
    }
}
