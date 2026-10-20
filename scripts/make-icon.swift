import AppKit
import ImageIO
import UniformTypeIdentifiers

// Draws GearUp's app icon with CoreGraphics: a squircle, a gradient, and one of
// three bicycle-drivetrain motifs. No external tool is involved, so the icon is
// reproducible from the repository alone.
//
//   swift scripts/make-icon.swift --preview Design          # the three options
//   swift scripts/make-icon.swift --variant bike --out icon.png
//   swift scripts/make-icon.swift --variant bike --iconset Icon.iconset
//
// The artwork is drawn in a 1024-point design space and scaled to whatever size
// is being rendered, so the teeth stay crisp at 16 pt instead of being
// downsampled from a big bitmap.

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let ink = rgb(0x0D1016)
let paper = rgb(0xF4F7FC)
let silver = rgb(0xC9D4E4)
let steel = rgb(0x8FA1B9)
let accent = rgb(0xFF7A45)
let accentDeep = rgb(0xE0511C)
let accentLight = rgb(0xFFAD8A)
let topOfTile = rgb(0x33425E)
let bottomOfTile = rgb(0x0B0E14)

// MARK: - Canvas

/// A context whose coordinates are the 1024-point design space, y downwards, so
/// the drawing code can be written the way the picture is read.
func withDesignSpace(size: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil,
            width: Int(size),
            height: Int(size),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    body(ctx)
    return ctx.makeImage()
}

/// The rounded square every macOS app icon sits on: 824 across, centred, with a
/// shadow of its own because the Dock does not add one.
func drawTile(_ ctx: CGContext) {
    let tile = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 186,
        cornerHeight: 186,
        transform: nil
    )

    ctx.saveGState()
    // Shadow offsets are in device space, which the flipped design space does
    // not follow: a negative y is what puts the shadow below the tile.
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: rgb(0x000000, 0.42))
    ctx.addPath(tile)
    ctx.setFillColor(ink)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [topOfTile, bottomOfTile] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 60, y: 40),
        end: CGPoint(x: 980, y: 1000),
        options: []
    )

    // A soft light from the upper left, which keeps the tile from looking flat.
    let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        sheen,
        startCenter: CGPoint(x: 330, y: 250),
        startRadius: 0,
        endCenter: CGPoint(x: 330, y: 250),
        endRadius: 520,
        options: []
    )

    ctx.restoreGState()

    // Inner rim: the thin highlight along the top edge of the tile.
    ctx.saveGState()
    ctx.addPath(CGPath(
        roundedRect: CGRect(x: 104, y: 104, width: 816, height: 816),
        cornerWidth: 182,
        cornerHeight: 182,
        transform: nil
    ))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Gears

/// The windows a chainring is lightened with.
enum Cutouts {
    case none
    case holes(radius: CGFloat)
    case slots(CGSize)
}

/// A toothed chainring: the ring with its teeth, optional windows that let the
/// tile show through, and a hub.
func drawCog(
    _ ctx: CGContext,
    center: CGPoint,
    outer: CGFloat,
    hole: CGFloat,
    teeth: Int,
    tooth: CGSize,
    fill: CGColor,
    cutouts: Cutouts = .none,
    hub: CGFloat = 0,
    hubFill: CGColor = ink
) {
    // Ring plus windows as one even-odd path, so the gradient stays visible
    // through them instead of being painted over.
    let shape = CGMutablePath()
    shape.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
    if hole > 0 {
        shape.addEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
    }

    let windowCount = 5
    let mid = (hole + outer) / 2
    for index in 0..<windowCount {
        let angle = CGFloat(index) * 2 * .pi / CGFloat(windowCount) - .pi / 2
        var window: CGPath?
        switch cutouts {
        case .none:
            break
        case .holes(let radius):
            window = CGPath(
                ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                transform: nil
            )
        case .slots(let size):
            window = CGPath(
                roundedRect: CGRect(
                    x: -size.width / 2, y: -size.height / 2,
                    width: size.width, height: size.height
                ),
                cornerWidth: size.width / 2,
                cornerHeight: size.width / 2,
                transform: nil
            )
        }
        guard let window else { continue }
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: 0, y: mid)
        shape.addPath(window, transform: transform)
    }

    ctx.addPath(shape)
    ctx.setFillColor(fill)
    ctx.fillPath(using: .evenOdd)

    // Teeth as rounded stubs around the rim: cheaper to reason about than a
    // single toothed outline, and indistinguishable at icon sizes.
    let toothPath = CGMutablePath()
    for index in 0..<teeth {
        let angle = CGFloat(index) * 2 * .pi / CGFloat(teeth)
        let stub = CGPath(
            roundedRect: CGRect(x: -tooth.width / 2, y: 0, width: tooth.width, height: tooth.height),
            cornerWidth: tooth.width * 0.28,
            cornerHeight: tooth.width * 0.28,
            transform: nil
        )
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: 0, y: outer - 2)
        toothPath.addPath(stub, transform: transform)
    }
    ctx.addPath(toothPath)
    ctx.setFillColor(fill)
    ctx.fillPath()

    if hub > 0 {
        ctx.setFillColor(hubFill)
        ctx.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))
    }
}

/// A chain: a rounded stroke for the plates and stubs across it for the links.
func drawChain(_ ctx: CGContext, points: [CGPoint], width: CGFloat) {
    guard points.count > 1 else { return }

    let path = CGMutablePath()
    path.move(to: points.first!)
    for point in points.dropFirst() { path.addLine(to: point) }

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0x0D1016, 0.75))
    ctx.setLineWidth(width * 1.7)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.setStrokeColor(silver)
    ctx.setLineWidth(width)
    ctx.strokePath()
    ctx.restoreGState()

    // Links, walked by hand along the polyline.
    let spacing = width * 1.85
    for index in 0..<(points.count - 1) {
        let a = points[index]
        let b = points[index + 1]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { continue }
        let ux = dx / length
        let uy = dy / length

        var distance = spacing / 2
        while distance < length {
            let px = a.x + ux * distance
            let py = a.y + uy * distance
            let half = width * 0.62
            let tick = CGMutablePath()
            tick.move(to: CGPoint(x: px - uy * half, y: py + ux * half))
            tick.addLine(to: CGPoint(x: px + uy * half, y: py - ux * half))
            ctx.addPath(tick)
            distance += spacing
        }
    }
    ctx.setStrokeColor(rgb(0x7C8CA4, 0.9))
    ctx.setLineWidth(width * 0.30)
    ctx.setLineCap(.butt)
    ctx.strokePath()
}

/// The path a chain takes between two cogs: the two outer tangents and the wrap
/// around the smaller one. Running the chain through the middle of a chainring —
/// the obvious straight-line version — reads as a scratch, not a drivetrain.
func chainBetween(
    big: (center: CGPoint, radius: CGFloat),
    small: (center: CGPoint, radius: CGFloat)
) -> [CGPoint] {
    let (a, bigRadius) = big
    let (b, smallRadius) = small
    let distance = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
    guard distance > abs(bigRadius - smallRadius) + 1 else { return [] }

    let base = atan2(b.y - a.y, b.x - a.x)
    let offset = acos((bigRadius - smallRadius) / distance)

    func point(_ center: CGPoint, _ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    var points = [
        point(a, bigRadius, base + offset),
        point(b, smallRadius, base + offset),
    ]

    // The wrap goes round the far side of the small cog, away from the ring.
    let steps = 20
    let start = base + offset
    let end = base - offset + 2 * .pi
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        points.append(point(b, smallRadius, start + (end - start) * t))
    }

    points.append(point(a, bigRadius, base - offset))
    return points
}

// MARK: - Motifs

/// The literal one: a bicycle whose crankset is the hero, in the accent colour
/// so it does not merge with the white frame. Three concentric chainrings — a
/// real triple — because "several gears" is the point.
func drawBicycle(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: -30)

    let rearAxle = CGPoint(x: 348, y: 600)
    let frontAxle = CGPoint(x: 700, y: 600)
    let seatTop = CGPoint(x: 462, y: 388)
    let headTop = CGPoint(x: 632, y: 388)
    let headBottom = CGPoint(x: 656, y: 470)
    let bottomBracket = CGPoint(x: 512, y: 616)
    let wheelRadius: CGFloat = 160

    // Wheels: a tyre weight and a fainter rim line, no spokes (they turn to mud
    // at 16 pt).
    for axle in [rearAxle, frontAxle] {
        ctx.setStrokeColor(paper)
        ctx.setLineWidth(25)
        ctx.strokeEllipse(in: CGRect(
            x: axle.x - wheelRadius, y: axle.y - wheelRadius,
            width: wheelRadius * 2, height: wheelRadius * 2
        ))
        ctx.setStrokeColor(rgb(0xF4F7FC, 0.30))
        ctx.setLineWidth(7)
        ctx.strokeEllipse(in: CGRect(
            x: axle.x - wheelRadius + 25, y: axle.y - wheelRadius + 25,
            width: (wheelRadius - 25) * 2, height: (wheelRadius - 25) * 2
        ))
        ctx.setFillColor(paper)
        ctx.fillEllipse(in: CGRect(x: axle.x - 11, y: axle.y - 11, width: 22, height: 22))
    }

    // Frame.
    let tubes = [
        (rearAxle, seatTop),           // seat stay
        (seatTop, bottomBracket),      // seat tube
        (seatTop, headTop),            // top tube
        (bottomBracket, headBottom),   // down tube
        (headTop, headBottom),         // head tube
        (headBottom, frontAxle),       // fork
    ]
    ctx.setStrokeColor(paper)
    ctx.setLineWidth(23)
    ctx.setLineCap(.round)
    for (a, b) in tubes {
        ctx.move(to: a)
        ctx.addLine(to: b)
    }
    ctx.strokePath()

    // Chain stay, drawn once so it can pass behind the crankset.
    ctx.setLineWidth(23)
    ctx.move(to: rearAxle)
    ctx.addLine(to: bottomBracket)
    ctx.strokePath()

    // Saddle and bars.
    ctx.setLineWidth(22)
    ctx.move(to: CGPoint(x: 418, y: 380))
    ctx.addLine(to: CGPoint(x: 494, y: 380))
    ctx.move(to: headTop)
    ctx.addLine(to: CGPoint(x: 682, y: 370))
    ctx.move(to: CGPoint(x: 682, y: 370))
    ctx.addLine(to: CGPoint(x: 698, y: 410))
    ctx.strokePath()

    // The crankset: three chainrings, each sitting in the gap of the next, with
    // room for its teeth. Orange, so the drivetrain reads even at 32 pt.
    let rings: [(outer: CGFloat, hole: CGFloat, teeth: Int, tooth: CGSize, fill: CGColor)] = [
        (44, 16, 20, CGSize(width: 9, height: 10), accentLight),
        (68, 60, 26, CGSize(width: 10, height: 11), accentDeep),
        (92, 86, 30, CGSize(width: 11, height: 12), accent),
    ]
    for ring in rings {
        drawCog(
            ctx,
            center: bottomBracket,
            outer: ring.outer,
            hole: ring.hole,
            teeth: ring.teeth,
            tooth: ring.tooth,
            fill: ring.fill
        )
    }

    // Crank and pedal in white, over the rings.
    ctx.setStrokeColor(paper)
    ctx.setLineWidth(23)
    ctx.setLineCap(.round)
    ctx.move(to: bottomBracket)
    ctx.addLine(to: CGPoint(x: bottomBracket.x - 58, y: bottomBracket.y + 62))
    ctx.strokePath()

    let pedal = CGMutablePath()
    pedal.addRoundedRect(
        in: CGRect(x: -30, y: -10, width: 60, height: 20),
        cornerWidth: 9,
        cornerHeight: 9
    )
    var pedalTransform = CGAffineTransform(
        translationX: bottomBracket.x - 64,
        y: bottomBracket.y + 68
    ).rotated(by: .pi / 4)
    ctx.addPath(pedal.copy(using: &pedalTransform)!)
    ctx.setFillColor(paper)
    ctx.fillPath()

    // A chainring needs a bolt at its centre.
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(
        x: bottomBracket.x - 17, y: bottomBracket.y - 17, width: 34, height: 34
    ))

    ctx.restoreGState()
}

/// The close-up: chainring, cassette and chain fill the tile. The boldest of the
/// three, and the one that says "gears" in a single shape.
func drawDrivetrain(_ ctx: CGContext) {
    let ring = CGPoint(x: 456, y: 566)
    let ringRadius: CGFloat = 282
    let cassette = CGPoint(x: 738, y: 316)
    let cassetteRadius: CGFloat = 134

    // Chain first, so the cogs sit on top of it.
    drawChain(
        ctx,
        points: chainBetween(
            big: (ring, ringRadius + 26),
            small: (cassette, cassetteRadius)
        ),
        width: 15
    )

    drawCog(
        ctx,
        center: ring,
        outer: ringRadius,
        hole: 160,
        teeth: 46,
        tooth: CGSize(width: 27, height: 26),
        fill: paper,
        cutouts: .slots(CGSize(width: 62, height: 104))
    )

    ctx.setFillColor(rgb(0x2A3547))
    ctx.fillEllipse(in: CGRect(x: ring.x - 46, y: ring.y - 46, width: 92, height: 92))
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: CGRect(x: ring.x - 20, y: ring.y - 20, width: 40, height: 40))

    // Crank and pedal, out of the ring's way.
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    ctx.move(to: ring)
    ctx.addLine(to: CGPoint(x: 312, y: 800))
    ctx.strokePath()

    let pedal = CGMutablePath()
    pedal.addRoundedRect(
        in: CGRect(x: -44, y: -15, width: 88, height: 30),
        cornerWidth: 14,
        cornerHeight: 14
    )
    var pedalTransform = CGAffineTransform(translationX: 302, y: 808).rotated(by: .pi / 4)
    ctx.addPath(pedal.copy(using: &pedalTransform)!)
    ctx.setFillColor(accent)
    ctx.fillPath()

    // A cassette cone: three sprockets, each further back than the last.
    let sprockets: [(outer: CGFloat, hole: CGFloat, teeth: Int, tooth: CGFloat, fill: CGColor)] = [
        (116, 34, 26, 18, steel),
        (86, 22, 22, 14, silver),
        (58, 12, 18, 10, paper),
    ]
    for (index, sprocket) in sprockets.enumerated() {
        drawCog(
            ctx,
            center: CGPoint(
                x: cassette.x + CGFloat(index) * 24,
                y: cassette.y - CGFloat(index) * 24
            ),
            outer: sprocket.outer,
            hole: sprocket.hole,
            teeth: sprocket.teeth,
            tooth: CGSize(width: sprocket.tooth, height: 12),
            fill: sprocket.fill
        )
    }
}

/// The sign-like one: one big chainring with an up chevron in the hub. The most
/// legible of the three at menu-bar and Finder sizes, and the least literal.
func drawGearMark(_ ctx: CGContext) {
    let center = CGPoint(x: 512, y: 512)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x000000, 0.35))
    drawCog(
        ctx,
        center: center,
        outer: 312,
        hole: 214,
        teeth: 46,
        tooth: CGSize(width: 30, height: 30),
        fill: paper,
        cutouts: .holes(radius: 30)
    )
    ctx.restoreGState()

    // Two chevrons: the up of GearUp, and the direction of a shift.
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: center.x - 88, y: center.y + 40))
    chevron.addLine(to: CGPoint(x: center.x, y: center.y - 68))
    chevron.addLine(to: CGPoint(x: center.x + 88, y: center.y + 40))
    ctx.addPath(chevron)
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(44)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    let second = CGMutablePath()
    second.move(to: CGPoint(x: center.x - 54, y: center.y + 128))
    second.addLine(to: CGPoint(x: center.x, y: center.y + 62))
    second.addLine(to: CGPoint(x: center.x + 54, y: center.y + 128))
    ctx.addPath(second)
    ctx.setStrokeColor(accentDeep)
    ctx.setLineWidth(34)
    ctx.strokePath()
}

// MARK: - Output

let variants: [String: (CGContext) -> Void] = [
    "bike": drawBicycle,
    "drivetrain": drawDrivetrain,
    "gear": drawGearMark,
]

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        FileHandle.standardError.write("could not write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func render(_ variant: String, size: CGFloat) -> CGImage? {
    guard let draw = variants[variant] else { return nil }
    return withDesignSpace(size: size) { ctx in
        drawTile(ctx)
        draw(ctx)
    }
}

var variant = "bike"
var output: String?
var iconset: String?
var preview: String?

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--variant": variant = arguments.first ?? variant; if !arguments.isEmpty { arguments.removeFirst() }
    case "--out": output = arguments.first; if !arguments.isEmpty { arguments.removeFirst() }
    case "--iconset": iconset = arguments.first; if !arguments.isEmpty { arguments.removeFirst() }
    case "--preview": preview = arguments.first; if !arguments.isEmpty { arguments.removeFirst() }
    default:
        FileHandle.standardError.write("unknown argument \(argument)\n".data(using: .utf8)!)
        exit(2)
    }
}

guard variants[variant] != nil else {
    FileHandle.standardError.write("unknown variant \(variant); pick \(variants.keys.sorted())\n".data(using: .utf8)!)
    exit(2)
}

if let preview {
    let directory = URL(fileURLWithPath: preview)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["bike", "drivetrain", "gear"] {
        guard let image = render(name, size: 512) else { continue }
        writePNG(image, to: directory.appendingPathComponent("icon-\(name).png"))
    }
}

if let output, let image = render(variant, size: 1024) {
    writePNG(image, to: URL(fileURLWithPath: output))
}

if let iconset {
    // The sizes Finder, the Dock and About windows ask for, drawn at each size
    // rather than shrunk from one bitmap.
    let directory = URL(fileURLWithPath: iconset)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sizes: [(String, CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, size) in sizes {
        guard let image = render(variant, size: size) else { continue }
        writePNG(image, to: directory.appendingPathComponent("\(name).png"))
    }
}
