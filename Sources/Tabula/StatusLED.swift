import AppKit
import TabulaCore

/// The menu bar icon *is* the device's display. One coloured dot, four states:
/// red = recording, green = playback, cyan = cue detent, magenta = scrub.
/// Error and paused states blink.
final class StatusLED {
    private let item: NSStatusItem
    private var cache: [String: NSImage] = [:]
    private var phase: Double = 0
    private var lastKey = ""

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.image = image(for: nil, alpha: 0.32)
        item.button?.toolTip = "TABULA"
    }

    var menu: NSMenu? {
        get { item.menu }
        set { item.menu = newValue }
    }

    /// Driven from the 20 Hz tick loop, so flash/blink animate without a
    /// second timer.
    func update(_ state: LedState, dtMs: Double) {
        let key = "\(state.color?.rawValue ?? "-")|\(state.mode.rawValue)|\(state.reason ?? "-")"
        if key != lastKey {
            lastKey = key
            phase = 0
        }
        phase += dtMs

        let alpha: Double
        switch state.mode {
        case .off:
            alpha = 0.32
        case .steady:
            alpha = 1.0
        case .flash:
            alpha = 1.0 - 0.6 * min(1, phase / 200.0)
        case .blink:
            alpha = sin(phase / 1000 * 2 * Double.pi * 1.6) > 0 ? 1.0 : 0.28
        }

        item.button?.image = image(for: state.color, alpha: alpha)
        item.button?.toolTip = tooltip(state)
    }

    private func tooltip(_ state: LedState) -> String {
        switch state.mode {
        case .off: return "TABULA — idle"
        case .steady, .flash, .blink:
            return "TABULA — \(state.reason ?? state.mode.rawValue)"
        }
    }

    private func image(for color: LedColor?, alpha: Double) -> NSImage {
        let bucket = Int((max(0, min(1, alpha)) * 12).rounded())
        let key = "\(color?.rawValue ?? "none")-\(bucket)"
        if let cached = cache[key] { return cached }

        let a = Double(bucket) / 12
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            // Kept small and slightly inset: menu bar items are dense on
            // modern macOS, and the ring keeps the dot readable on light and
            // dark menu bars alike.
            let dot = NSRect(x: 4.5, y: 4.5, width: 9, height: 9)
            let path = NSBezierPath(ovalIn: dot)
            let fill = color.map { StatusLED.color($0).withAlphaComponent(a) }
                ?? NSColor.tertiaryLabelColor.withAlphaComponent(a)
            fill.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        img.isTemplate = false
        cache[key] = img
        return img
    }

    private static func color(_ c: LedColor) -> NSColor {
        switch c {
        case .red: return .systemRed
        case .green: return .systemGreen
        case .cyan: return .systemTeal
        case .magenta: return .systemPurple
        }
    }
}
