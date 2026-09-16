import AppKit
import Foundation

enum ImageMerger {
    /// Tight box around everything on the canvas: this is exactly what gets exported.
    static func bounds(of items: [ImageItem], annotations: [Annotation] = []) -> CGRect {
        let rects = items.map(\.frame) + annotations.map(\.bounds)
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Renders at native resolution where possible so shrinking on canvas doesn't lose detail.
    static func exportScale(for items: [ImageItem]) -> CGFloat {
        let ratios = items.map { $0.nativeSize.width / max($0.frame.width, 1) }
        return min(max(ratios.max() ?? 1, 1), 4)
    }

    static func exportPixelSize(for items: [ImageItem], annotations: [Annotation] = []) -> CGSize {
        let bounds = bounds(of: items, annotations: annotations)
        let scale = exportScale(for: items)
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    /// Draws the canvas layout into a bitmap. Canvas y grows downward, AppKit's grows upward.
    static func merge(
        items: [ImageItem],
        annotations: [Annotation] = [],
        backgroundColor: NSColor?
    ) -> NSImage? {
        guard !items.isEmpty || !annotations.isEmpty else { return nil }

        let bounds = bounds(of: items, annotations: annotations)
        let scale = exportScale(for: items)
        let pixelWidth = Int((bounds.width * scale).rounded())
        let pixelHeight = Int((bounds.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: pixelWidth, height: pixelHeight)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        if let backgroundColor {
            backgroundColor.setFill()
            NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
        }

        for item in items.sorted(by: { $0.z < $1.z }) {
            let dest = NSRect(
                x: (item.frame.minX - bounds.minX) * scale,
                y: (bounds.maxY - item.frame.maxY) * scale,
                width: item.frame.width * scale,
                height: item.frame.height * scale
            )
            item.image.draw(
                in: dest,
                from: NSRect(origin: .zero, size: item.image.size),
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }

        // Annotations sit above the images. Canvas y-down maps to context y-up here.
        var transform = CGAffineTransform(
            a: scale, b: 0,
            c: 0, d: -scale,
            tx: -bounds.minX * scale,
            ty: bounds.maxY * scale
        )
        let cg = context.cgContext
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        for annotation in annotations.sorted(by: { $0.z < $1.z }) {
            for op in annotation.drawOps {
                guard let path = op.path.copy(using: &transform) else { continue }
                let color = (op.color.usingColorSpace(.sRGB) ?? op.color).cgColor

                cg.saveGState()
                cg.addPath(path)
                if op.isFill {
                    cg.setFillColor(color)
                    cg.fillPath()
                } else {
                    cg.setStrokeColor(color)
                    cg.setLineWidth(op.lineWidth * scale)
                    cg.strokePath()
                }
                cg.restoreGState()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: rep.size)
        output.addRepresentation(rep)
        return output
    }

    static func pngData(from image: NSImage) -> Data? {
        if let rep = image.representations.first as? NSBitmapImageRep {
            return rep.representation(using: .png, properties: [:])
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func copyToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = pngData(from: image) {
            pasteboard.setData(data, forType: .png)
        }
        pasteboard.writeObjects([image])
    }

    static func imagesFromPasteboard() -> [NSImage] {
        let pasteboard = NSPasteboard.general
        var images: [NSImage] = []

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.image"]
        ]) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    images.append(image)
                }
            }
        }

        if images.isEmpty,
           let pasted = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            images.append(contentsOf: pasted)
        }

        return images
    }

    static func imagesFromDroppedProviders(_ providers: [NSItemProvider]) async -> [NSImage] {
        var images: [NSImage] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                if let url = try? await loadURL(from: provider),
                   let image = NSImage(contentsOf: url) {
                    images.append(image)
                    continue
                }
            }

            if provider.canLoadObject(ofClass: NSImage.self) {
                if let image = try? await loadImage(from: provider) {
                    images.append(image)
                }
            }
        }

        return images
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private static func loadImage(from provider: NSItemProvider) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image = object as? NSImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
