// Generates the iMerge app icon into iMerge/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root:  swift Tools/GenerateAppIcon.swift

import AppKit

let outputDirectory = URL(fileURLWithPath: "iMerge/Assets.xcassets/AppIcon.appiconset")

/// Apple-style continuous corner shape (superellipse) rather than a circular rounded rect.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 900

    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = rect.midX + a * copysign(pow(abs(ct), 2 / exponent), ct)
        let y = rect.midY + b * copysign(pow(abs(st), 2 / exponent), st)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.line(to: CGPoint(x: x, y: y))
        }
    }

    path.close()
    return path
}

func makeIcon(pixelSize: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixelSize)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("cannot allocate bitmap") }
    rep.size = CGSize(width: size, height: size)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("cannot make context") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let cg = context.cgContext

    let inset = size * 0.094
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    /// Design coordinates: origin top-left, units are fractions of the plate.
    func area(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(
            x: plate.minX + x * plate.width,
            y: plate.minY + (1 - y - height) * plate.height,
            width: width * plate.width,
            height: height * plate.height
        )
    }

    // Plate with gradient fill.
    cg.saveGState()
    squirclePath(in: plate).addClip()

    let top = NSColor(srgbRed: 0.38, green: 0.55, blue: 1.0, alpha: 1)
    let bottom = NSColor(srgbRed: 0.46, green: 0.24, blue: 0.90, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: plate, angle: 270)

    NSGradient(
        starting: NSColor(white: 1, alpha: 0.30),
        ending: NSColor(white: 1, alpha: 0)
    )?.draw(
        fromCenter: CGPoint(x: plate.midX, y: plate.maxY),
        radius: 0,
        toCenter: CGPoint(x: plate.midX, y: plate.maxY),
        radius: plate.width * 0.85,
        options: []
    )
    cg.restoreGState()

    // Two overlapping cards: the overlap is the "merge".
    let cardRadius = plate.width * 0.075
    let backCard = NSBezierPath(
        roundedRect: area(0.135, 0.150, 0.465, 0.430),
        xRadius: cardRadius,
        yRadius: cardRadius
    )
    let frontCard = NSBezierPath(
        roundedRect: area(0.400, 0.420, 0.465, 0.430),
        xRadius: cardRadius,
        yRadius: cardRadius
    )

    NSColor(white: 1, alpha: 0.55).setFill()
    backCard.fill()
    NSColor(white: 1, alpha: 0.85).setStroke()
    backCard.lineWidth = max(size * 0.008, 0.75)
    backCard.stroke()

    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012),
        blur: size * 0.03,
        color: NSColor(white: 0, alpha: 0.28).cgColor
    )
    NSColor(white: 1, alpha: 0.97).setFill()
    frontCard.fill()
    cg.restoreGState()

    // Photo motif inside the front card so the icon reads as images, not blank cards.
    let card = area(0.400, 0.420, 0.465, 0.430)
    cg.saveGState()
    frontCard.addClip()

    let sun = NSBezierPath(ovalIn: CGRect(
        x: card.minX + card.width * 0.615,
        y: card.minY + card.height * 0.595,
        width: card.width * 0.175,
        height: card.width * 0.175
    ))
    NSColor(srgbRed: 0.53, green: 0.36, blue: 0.95, alpha: 0.55).setFill()
    sun.fill()

    let hills = NSBezierPath()
    hills.move(to: CGPoint(x: card.minX, y: card.minY))
    hills.line(to: CGPoint(x: card.minX + card.width * 0.30, y: card.minY + card.height * 0.52))
    hills.line(to: CGPoint(x: card.minX + card.width * 0.50, y: card.minY + card.height * 0.24))
    hills.line(to: CGPoint(x: card.minX + card.width * 0.70, y: card.minY + card.height * 0.60))
    hills.line(to: CGPoint(x: card.maxX, y: card.minY + card.height * 0.16))
    hills.line(to: CGPoint(x: card.maxX, y: card.minY))
    hills.close()
    NSColor(srgbRed: 0.44, green: 0.30, blue: 0.92, alpha: 0.72).setFill()
    hills.fill()
    cg.restoreGState()

    // Inner border on the plate to crisp up the edge.
    let edge = squirclePath(in: plate.insetBy(dx: size * 0.004, dy: size * 0.004))
    edge.lineWidth = max(size * 0.008, 0.75)
    NSColor(white: 1, alpha: 0.20).setStroke()
    edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for variant in variants {
    let rep = makeIcon(pixelSize: variant.pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode \(variant.name)")
    }
    try data.write(to: outputDirectory.appendingPathComponent(variant.name))
    print("wrote \(variant.name) (\(variant.pixels)px)")
}
