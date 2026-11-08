// Rebindable global shortcuts.
//
// The app has no window and no context menu navigation: the *only* way to
// drive it is the shortcuts below, so they are a user-facing surface, not an
// implementation detail. They live in Core (not in the AppKit layer) so the
// defaults, the merge-on-upgrade behaviour and the conflict check are testable
// without a window server.

import Foundation

// MARK: - Modifiers
//
// Carbon's `RegisterEventHotKey` mask, named here so Core does not have to
// import Carbon and so the AppKit layer has one place to translate to/from
// `NSEvent.ModifierFlags`.

public enum KeyModifier {
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    /// A shortcut with none of these would be swallowed globally and eat
    /// ordinary typing, so every binding must carry at least one.
    public static let required: UInt32 = command | option | control
}

// MARK: - Actions

/// One rebindable action. Raw values are the stable keys written to
/// `UserDefaults`, so a case rename is a migration.
public enum HotKeyAction: String, CaseIterable, Codable, Sendable {
    case record
    case mem
    case previousCue
    case nextCue
    case scrubBackward
    case scrubForward
    case playPause
    case announce

    public var title: String {
        switch self {
        case .record: return "Record / stop"
        case .mem: return "MEM — marker / rewind"
        case .previousCue: return "Previous cue"
        case .nextCue: return "Next cue"
        case .scrubBackward: return "Scrub back"
        case .scrubForward: return "Scrub forward"
        case .playPause: return "Play / pause"
        case .announce: return "Announce position"
        }
    }

    public var hint: String {
        switch self {
        case .record:
            return "Start or stop recording. The microphone is requested the first time you record."
        case .mem:
            return "While recording: drop a marker. Outside a recording: rewind 2.5 s and audition."
        case .previousCue:
            return "Walk back one cue and audition it."
        case .nextCue:
            return "Walk forward one cue and audition it."
        case .scrubBackward:
            return "Fine scrub a few seconds back inside the current recording."
        case .scrubForward:
            return "Fine scrub a few seconds forward inside the current recording."
        case .playPause:
            return "Start or pause playback at the cursor."
        case .announce:
            return "Play a tone whose pitch tells you where you are in the archive."
        }
    }
}

// MARK: - A single binding

public struct KeyCombo: Codable, Equatable, Sendable {
    /// Carbon virtual key code (`kVK_*`), which is layout-independent.
    public var keyCode: UInt32
    /// Carbon modifier mask (`controlKey | optionKey | …`).
    public var modifiers: UInt32
    /// Human-readable label, captured when the shortcut was assigned. Only
    /// cosmetic — registration uses the code and the mask.
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// Two combos are the same shortcut if they register the same hot key,
    /// even if their labels differ.
    public func conflicts(with other: KeyCombo) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

// MARK: - The whole set

public struct Keybindings: Codable, Equatable, Sendable {
    public static let storageKey = "hotKeys.v1"

    /// Keyed by `HotKeyAction.rawValue` so the JSON stays readable and
    /// versioned even if the enum changes shape.
    public var combos: [String: [KeyCombo]]

    public init(combos: [String: [KeyCombo]] = [:]) {
        self.combos = combos
    }

    public subscript(action: HotKeyAction) -> [KeyCombo] {
        get { combos[action.rawValue] ?? [] }
        set { combos[action.rawValue] = newValue }
    }

    // MARK: Defaults

    /// Control-Option is the namespace: rarely taken by other apps, and the
    /// device is only a handful of controls. Cue navigation is bound on *both*
    /// axes — left/up go back, right/down go forward — because the hand's
    /// instinct and the simulator's wheel both point that way.
    public static let `default`: Keybindings = {
        let mods = KeyModifier.control | KeyModifier.option
        let shifted = mods | KeyModifier.shift
        return Keybindings(combos: [
            HotKeyAction.record.rawValue: [
                KeyCombo(keyCode: 0x0F, modifiers: mods, display: "⌃⌥R"), // kVK_ANSI_R
            ],
            HotKeyAction.mem.rawValue: [
                KeyCombo(keyCode: 0x2E, modifiers: mods, display: "⌃⌥M"), // kVK_ANSI_M
            ],
            HotKeyAction.previousCue.rawValue: [
                KeyCombo(keyCode: 0x7E, modifiers: mods, display: "⌃⌥↑"), // kVK_UpArrow
                KeyCombo(keyCode: 0x7B, modifiers: mods, display: "⌃⌥←"), // kVK_LeftArrow
            ],
            HotKeyAction.nextCue.rawValue: [
                KeyCombo(keyCode: 0x7D, modifiers: mods, display: "⌃⌥↓"), // kVK_DownArrow
                KeyCombo(keyCode: 0x7C, modifiers: mods, display: "⌃⌥→"), // kVK_RightArrow
            ],
            HotKeyAction.scrubBackward.rawValue: [
                KeyCombo(keyCode: 0x7E, modifiers: shifted, display: "⌃⌥⇧↑"),
            ],
            HotKeyAction.scrubForward.rawValue: [
                KeyCombo(keyCode: 0x7D, modifiers: shifted, display: "⌃⌥⇧↓"),
            ],
            HotKeyAction.playPause.rawValue: [
                KeyCombo(keyCode: 0x24, modifiers: mods, display: "⌃⌥⏎"), // kVK_Return
            ],
            HotKeyAction.announce.rawValue: [
                KeyCombo(keyCode: 0x04, modifiers: mods, display: "⌃⌥H"), // kVK_ANSI_H
            ],
        ])
    }()

    // MARK: Persistence

    /// Load the stored set, filling in any action introduced by a later
    /// version so an upgrade never leaves a control unreachable.
    public static func load(from defaults: UserDefaults = .standard) -> Keybindings {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Keybindings.self, from: data)
        else { return .default }
        return stored.completed()
    }

    public func completed() -> Keybindings {
        var merged = self
        for action in HotKeyAction.allCases where merged.combos[action.rawValue] == nil {
            merged.combos[action.rawValue] = Keybindings.default[action]
        }
        return merged
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: Conflicts

    /// The action that already owns `combo`, if any. `excluding` is the action
    /// currently being edited.
    public func conflict(for combo: KeyCombo, excluding action: HotKeyAction) -> HotKeyAction? {
        for candidate in HotKeyAction.allCases where candidate != action {
            if self[candidate].contains(where: { $0.conflicts(with: combo) }) {
                return candidate
            }
        }
        return nil
    }
}
