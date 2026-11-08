#!/usr/bin/env swift
//
// Draw the TABULA app icon and write Resources/AppIcon.icns.
//
//   ./scripts/make-icon.swift [output.icns]
//
// The icon is the menu bar display, enlarged: one coloured dot sunk into a
// graphite face. The app never shows anything else, so the icon is not a
// metaphor for the device — it is the device, at 1024 pt. Red is the only
// state that is steady-state meaningful (recording; red blinking is error),
// so red is what got the icon. Green, cyan and magenta stay in the menu bar.
//
// Everything is drawn as vectors at each size — 16 px is not a shrunken
// 1024 px — so the dot keeps its shape down to Finder's list view. Needs only
// AppKit and `iconutil`; `make-app.sh` runs this, so the .icns is not in git.
//
import AppKit
import CoreGraphics
import Foundation

let canvasSize: CGFloat = 1024

// MARK: - palette (matches StatusLED: systemRed on a dark bezel)

private let LED_RED = (r: 1.0, g: 0.231, b: 0.188)

private func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// MARK: - shapes

/// Superellipse — the macOS squircle. `NSBezierPath(roundedRect:)` gives
/// circular corners, which read as a web button next to real app icons.
private func squircle(_ rect: CGRect, n: Double = 5.0) -> CGPath {
    let path = CGMutablePath()
    let steps = 1440
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let p = CGPoint(x: rect.midX + a * copysign(pow(abs(ct), 2 / n), ct),
                        y: rect.midY + b * copysign(pow(abs(st), 2 / n), st))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

private func radialFill(_ ctx: CGContext, colors: [CGColor], locations: [CGFloat],
                        center: CGPoint, startRadius: CGFloat, endCenter: CGPoint? = nil,
                        endRadius: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors as CFArray, locations: locations)!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: startRadius,
                           endCenter: endCenter ?? center, endRadius: endRadius, options: [])
}

private func linearFill(_ ctx: CGContext, colors: [CGColor], locations: [CGFloat],
                        from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
}

// MARK: - the three parts

/// Graphite face: 824 pt on a 1024 canvas — Apple's macOS icon grid — with a
/// drop shadow and a sheen from above so it sits on a Finder window like a
/// sibling of the system apps.
private func drawFace(_ ctx: CGContext) -> CGPath {
    let face = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgba(0, 0, 0, 0.35))
    ctx.addPath(face)
    ctx.clip()
    linearFill(ctx, colors: [rgba(0.26, 0.28, 0.31), rgba(0.13, 0.14, 0.16)],
               locations: [0, 1], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(face)
    ctx.clip()
    linearFill(ctx, colors: [rgba(1, 1, 1, 0.10), rgba(1, 1, 1, 0)],
               locations: [0, 1], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 560))
    ctx.restoreGState()
    return face
}

/// The milled socket the lamp sits in: dark in the middle, shaded under the
/// top rim, a little light on the lower rim. This is what stops the icon from
/// reading as a plain stop-button.
private func drawSocket(_ ctx: CGContext, center: CGPoint, radius: CGFloat) {
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2))
    ctx.clip()
    radialFill(ctx, colors: [rgba(0.045, 0.05, 0.06), rgba(0.175, 0.185, 0.20)],
               locations: [0.35, 1], center: center, startRadius: 0, endRadius: radius * 1.12)
    linearFill(ctx, colors: [rgba(0, 0, 0, 0.40), rgba(0, 0, 0, 0)],
               locations: [0, 1],
               from: CGPoint(x: center.x, y: center.y + radius),
               to: CGPoint(x: center.x, y: center.y - radius * 0.2))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setLineWidth(6)
    ctx.addArc(center: center, radius: radius - 2,
               startAngle: 0.05 * .pi, endAngle: 0.95 * .pi, clockwise: false)
    ctx.setStrokeColor(rgba(1, 1, 1, 0.13))
    ctx.strokePath()
    ctx.addArc(center: center, radius: radius - 2,
               startAngle: 1.05 * .pi, endAngle: 1.95 * .pi, clockwise: false)
    ctx.setStrokeColor(rgba(0, 0, 0, 0.45))
    ctx.strokePath()
    ctx.restoreGState()
}

/// The dot itself, same recipe as the menu bar glyph: coloured fill, hard dark
/// bezel ring, glow bleeding onto the face.
private func drawLamp(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
                      color: (r: Double, g: Double, b: Double), face: CGPath) {
    ctx.saveGState()
    ctx.addPath(face)
    ctx.clip()
    radialFill(ctx, colors: [rgba(color.r, color.g, color.b, 0.45),
                             rgba(color.r, color.g, color.b, 0)],
               locations: [0, 1], center: center, startRadius: 0, endRadius: radius * 2.6)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: rgba(0, 0, 0, 0.55))
    ctx.setFillColor(rgba(0.05, 0.05, 0.06))
    ctx.fillEllipse(in: CGRect(x: center.x - radius - 12, y: center.y - radius - 12,
                               width: (radius + 12) * 2, height: (radius + 12) * 2))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2))
    ctx.clip()
    radialFill(ctx, colors: [rgba(min(1, color.r + 0.45), min(1, color.g + 0.55), min(1, color.b + 0.55)),
                             rgba(color.r, color.g, color.b),
                             rgba(color.r * 0.62, color.g * 0.30, color.b * 0.30)],
               locations: [0, 0.55, 1],
               center: CGPoint(x: center.x, y: center.y + radius * 0.45), startRadius: 0,
               endCenter: center, endRadius: radius * 1.35)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius * 0.5, y: center.y + radius * 0.18,
                              width: radius * 0.8, height: radius * 0.5))
    ctx.setFillColor(rgba(1, 1, 1, 0.35))
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - render + iconset

private func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(px) / canvasSize, y: CGFloat(px) / canvasSize)

    let face = drawFace(context.cgContext)
    let center = CGPoint(x: 512, y: 512)
    drawSocket(context.cgContext, center: center, radius: 252)
    drawLamp(context.cgContext, center: center, radius: 158, color: LED_RED, face: face)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let destination = URL(fileURLWithPath: CommandLine.arguments.count > 1
                      ? CommandLine.arguments[1]
                      : "Resources/AppIcon.icns")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Tabula-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// name: (pixels). @2x entries are their own renders, not upscales.
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    try png(px).write(to: iconset.appendingPathComponent("\(name).png"))
}

try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed (\(iconutil.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
print(destination.path)
