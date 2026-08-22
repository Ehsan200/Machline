// Renders the Machline app icon.
//
// The icon is generated rather than checked in as a binary blob so it stays reviewable and
// editable in a diff. The mark is a mach cone — three swept shocks off a leading point — which
// stays legible down to the 16pt menu-bar size where detail disappears.

import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

/// Gruvbox dark-hard, the same palette the interface uses.
let panel = color(0x28_2828)
let canvas = color(0x1D_2021)
let accent = color(0x8E_C07C)
let accentDim = color(0x68_9D6A)
let highlight = color(0xB8_BB26)

func draw(size: Int) -> CGImage? {
    let side = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icons sit inside a margin rather than filling the tile edge to edge.
    let inset = side * 0.10
    let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = plate.width * 0.225

    let rounded = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(rounded)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [panel, canvas] as CFArray,
        locations: [0, 1])
    {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.minX, y: plate.minY),
            options: [])
    }
    context.restoreGState()

    // A hairline rim keeps the plate from dissolving into a dark desktop.
    context.saveGState()
    context.addPath(rounded)
    context.setStrokeColor(color(0x66_5C54, 0.55))
    context.setLineWidth(max(1, side * 0.006))
    context.strokePath()
    context.restoreGState()

    // The mach cone: shocks sweeping back from a leading point, tightest and brightest in front.
    //
    // The whole mark is clipped to the plate so a stroke's round cap cannot spill over the corner
    // radius, and the geometry is sized to land inside that clip rather than rely on it.
    context.saveGState()
    context.addPath(rounded)
    context.clip()

    let centerY = plate.midY
    let lineWidth = max(1, plate.width * 0.075)
    let spread = plate.height * 0.235
    let sweep = plate.width * 0.215
    // Leading edge, leaving room for the body dot and the stroke's own half-width.
    let apexX = plate.minX + plate.width * 0.70

    context.setLineCap(.round)
    context.setLineJoin(.round)

    let shocks: [(offset: CGFloat, stroke: CGColor, width: CGFloat)] = [
        (0.00, accent, lineWidth),
        (0.215, accentDim, lineWidth * 0.85),
        (0.430, accentDim, lineWidth * 0.70)
    ]

    for shock in shocks {
        let x = apexX - plate.width * shock.offset
        let tail = x - sweep
        context.setStrokeColor(shock.stroke)
        context.setLineWidth(shock.width)
        context.beginPath()
        context.move(to: CGPoint(x: tail, y: centerY + spread))
        context.addLine(to: CGPoint(x: x, y: centerY))
        context.addLine(to: CGPoint(x: tail, y: centerY - spread))
        context.strokePath()
    }

    // The body riding the cone. Dropped below 32pt, where it becomes a smudge.
    if size >= 32 {
        let dot = plate.width * 0.05
        context.setFillColor(highlight)
        context.fillEllipse(in: CGRect(
            x: apexX + plate.width * 0.085 - dot,
            y: centerY - dot,
            width: dot * 2,
            height: dot * 2))
    }

    context.restoreGState()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try data.write(to: url)
}

for size in sizes {
    guard let image = draw(size: size) else { continue }
    let scale = size / 2
    try write(image, to: outputDirectory.appendingPathComponent("icon_\(size)x\(size).png"))
    // The @2x slot for the next size down shares the same pixels.
    if sizes.contains(scale) {
        try write(image, to: outputDirectory.appendingPathComponent("icon_\(scale)x\(scale)@2x.png"))
    }
}
