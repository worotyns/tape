#!/usr/bin/env swift
//
// Draw the TABULA app icon and write Resources/AppIcon.icns.
//
//   ./scripts/make-icon.swift [output.icns]
//
// Flat by construction: one solid dot on one solid plate. No gradient, no
// bevel, no glow, no drop shadow — the only two decisions are the red and the
// size of the dot, and both survive being scaled to a Finder list.
//
// The icon is the menu bar display, enlarged: the app never shows anything but
// this dot, so the icon is the dot. Red, because recording is the only steady
// state — blinking red is error, and green/cyan/magenta only ever live in the
// status bar.
//
// Drawn as vectors at each size — 16 px is rendered, not a shrunken 1024 px.
// Needs only AppKit and `iconutil`; `make-app.sh` runs this, so the .icns is
// not in git.
//
import AppKit
import CoreGraphics
import Foundation

let canvasSize: CGFloat = 1024

// MARK: - the whole palette

/// systemRed, the same colour StatusLED paints the menu bar dot with.
private let LED_RED = (r: 1.0, g: 0.231, b: 0.188)
/// Graphite plate: dark enough that the dot is the only thing you see.
private let PLATE = (r: 0.169, g: 0.180, b: 0.196)

private func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

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
    let ctx = context.cgContext

    // Plate: 824 pt on a 1024 canvas — Apple's macOS icon grid.
    ctx.addPath(squircle(CGRect(x: 100, y: 100, width: 824, height: 824)))
    ctx.setFillColor(rgba(PLATE.r, PLATE.g, PLATE.b))
    ctx.fillPath()

    // Dot.
    let radius: CGFloat = 168
    ctx.setFillColor(rgba(LED_RED.r, LED_RED.g, LED_RED.b))
    ctx.fillEllipse(in: CGRect(x: 512 - radius, y: 512 - radius,
                               width: radius * 2, height: radius * 2))

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
