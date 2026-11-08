import XCTest
@testable import TapeCore

/// The shortcuts are the only interface the app has, so the parts that are easy
/// to get silently wrong — the defaults, surviving an upgrade, and refusing a
/// combination that is already taken — are pinned down here.
final class KeybindingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "tape.keybindings.tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultsBindEveryAction() {
        for action in HotKeyAction.allCases {
            XCTAssertFalse(
                Keybindings.default[action].isEmpty,
                "\(action) has no default shortcut"
            )
        }
    }

    func testDefaultHasNoSelfConflict() {
        let bindings = Keybindings.default
        for action in HotKeyAction.allCases {
            for combo in bindings[action] {
                XCTAssertNil(
                    bindings.conflict(for: combo, excluding: action),
                    "\(combo.display) is bound to more than one action"
                )
            }
        }
    }

    func testCueNavigationKeepsBothAxes() {
        let bindings = Keybindings.default
        XCTAssertEqual(bindings[.previousCue].map(\.display), ["⌃⌥↑", "⌃⌥←"])
        XCTAssertEqual(bindings[.nextCue].map(\.display), ["⌃⌥↓", "⌃⌥→"])
    }

    func testRoundTripThroughUserDefaults() {
        var edited = Keybindings.default
        edited[.record] = [KeyCombo(keyCode: 0x00, modifiers: KeyModifier.command, display: "⌘A")]
        edited.save(to: defaults)

        let loaded = Keybindings.load(from: defaults)
        XCTAssertEqual(loaded[.record], edited[.record])
        XCTAssertEqual(loaded[.mem], Keybindings.default[.mem])
    }

    func testMissingActionIsFilledInOnLoad() {
        // Simulate an archive written by an older version that only knew about
        // recording: the other actions must not become unreachable.
        let old = Keybindings(combos: [
            HotKeyAction.record.rawValue: [
                KeyCombo(keyCode: 0x0F, modifiers: KeyModifier.control, display: "⌃R"),
            ],
        ])
        old.save(to: defaults)

        let loaded = Keybindings.load(from: defaults)
        XCTAssertEqual(loaded[.record].first?.display, "⌃R")
        XCTAssertFalse(loaded[.announce].isEmpty)
    }

    func testEmptyBindingSurvivesLoad() {
        // An action deliberately unbound must stay unbound; only *missing*
        // actions are refilled from the defaults.
        var edited = Keybindings.default
        edited[.announce] = []
        edited.save(to: defaults)

        XCTAssertTrue(Keybindings.load(from: defaults)[.announce].isEmpty)
    }

    func testCorruptDataFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: Keybindings.storageKey)
        XCTAssertEqual(Keybindings.load(from: defaults), Keybindings.default)
    }

    func testConflictIgnoresTheEditedActionButCatchesOthers() {
        let bindings = Keybindings.default
        let r = bindings[.record][0]
        XCTAssertNil(bindings.conflict(for: r, excluding: .record))
        XCTAssertEqual(bindings.conflict(for: r, excluding: .mem), .record)
    }

    func testConflictComparesShortcutNotLabel() {
        var bindings = Keybindings.default
        // Same keys, different label — still a conflict.
        bindings[.mem] = [KeyCombo(keyCode: 0x0F, modifiers: KeyModifier.control | KeyModifier.option, display: "whatever")]
        XCTAssertEqual(bindings.conflict(for: bindings[.record][0], excluding: .record), .mem)
    }
}
