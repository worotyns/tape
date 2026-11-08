import AppKit
import Carbon.HIToolbox
import TabulaCore

// MARK: - NSEvent → KeyCombo
//
// `RegisterEventHotKey` and `NSEvent` use different modifier vocabularies, so
// this is the one place that translates. The label is built from the same
// mapping the defaults use, which keeps the recorder honest about what it
// captured.

extension KeyCombo {
    init?(event: NSEvent) {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.control) { mods |= KeyModifier.control }
        if event.modifierFlags.contains(.option) { mods |= KeyModifier.option }
        if event.modifierFlags.contains(.shift) { mods |= KeyModifier.shift }
        if event.modifierFlags.contains(.command) { mods |= KeyModifier.command }
        // A global hot key *swallows* the keystroke, so a binding without a
        // real modifier would eat ordinary typing everywhere. Refuse it.
        guard mods & KeyModifier.required != 0 else { return nil }
        let display = KeyCombo.describe(
            keyCode: UInt32(event.keyCode),
            modifiers: mods,
            characters: event.charactersIgnoringModifiers
        )
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, display: display)
    }

    static func describe(keyCode: UInt32, modifiers: UInt32, characters: String?) -> String {
        var text = ""
        if modifiers & KeyModifier.control != 0 { text += "⌃" }
        if modifiers & KeyModifier.option != 0 { text += "⌥" }
        if modifiers & KeyModifier.shift != 0 { text += "⇧" }
        if modifiers & KeyModifier.command != 0 { text += "⌘" }
        return text + keyName(keyCode, characters: characters)
    }

    static func keyName(_ keyCode: UInt32, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "⏎"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            if let characters, let first = characters.first, !characters.isEmpty, first != " " {
                return String(first).uppercased()
            }
            return "key \(keyCode)"
        }
    }

    static func isModifierKey(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_Shift, kVK_CapsLock, kVK_Option, kVK_Control,
             kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl,
             kVK_Function:
            return true
        default:
            return false
        }
    }
}

// MARK: - Shortcut recorder

protocol ShortcutButtonDelegate: AnyObject {
    /// Called before the button starts listening, so the app can unregister
    /// the global hot keys — otherwise Carbon would swallow the very keys the
    /// user is trying to assign.
    func shortcutButtonWillRecord(_ button: ShortcutButton)
    func shortcutButton(_ button: ShortcutButton, didCapture combo: KeyCombo)
    func shortcutButtonDidCancel(_ button: ShortcutButton)
}

/// A button that, when clicked, captures the next key combination pressed.
///
/// It is a plain `NSButton` subclass rather than a text field because the
/// point is to read raw virtual key codes, not typed characters.
final class ShortcutButton: NSButton {
    weak var delegate: ShortcutButtonDelegate?

    var combo: KeyCombo? {
        didSet { updateTitle() }
    }

    private var recording = false
    private let placeholder: String

    init(combo: KeyCombo?, placeholder: String = "unbound") {
        self.combo = combo
        self.placeholder = placeholder
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    private func updateTitle() {
        title = recording ? "press keys…" : (combo?.display ?? placeholder)
    }

    @objc func beginRecording() {
        guard !recording else { return }
        recording = true
        updateTitle()
        delegate?.shortcutButtonWillRecord(self)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        // Escape abandons the edit; a bare modifier is not a shortcut.
        if Int(event.keyCode) == kVK_Escape {
            recording = false
            updateTitle()
            delegate?.shortcutButtonDidCancel(self)
            return
        }
        if KeyCombo.isModifierKey(UInt32(event.keyCode)) { return }
        guard let captured = KeyCombo(event: event) else {
            // Modifier-less keys are refused; keep listening.
            NSSound.beep()
            return
        }
        recording = false
        updateTitle()
        delegate?.shortcutButton(self, didCapture: captured)
    }

    override func resignFirstResponder() -> Bool {
        // Clicking another control mid-capture must not leave the app's global
        // hot keys unregistered, which is what `willRecord` suspended.
        if recording {
            recording = false
            updateTitle()
            delegate?.shortcutButtonDidCancel(self)
        }
        return true
    }
}

// MARK: - Launch at login
//
// Deliberately the same LaunchAgent the installer writes (`--login`) instead
// of `SMAppService`: one mechanism means the checkbox and the installer can
// never disagree, and it works for a locally built bundle too.

enum LoginItem {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "local.tabula.recorder" }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Returns a human-readable error, or nil on success.
    static func setEnabled(_ enabled: Bool) -> String? {
        if !enabled {
            _ = launchctl(["bootout", "gui/\(getuid())", url.path])
            _ = launchctl(["unload", url.path])
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let executable = Bundle.main.executableURL?.path
                ?? Bundle.main.bundlePath + "/Contents/MacOS/Tabula"
            let plist: [String: Any] = [
                "Label": bundleID,
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: url)
            _ = launchctl(["bootout", "gui/\(getuid())", url.path])
            let boot = launchctl(["bootstrap", "gui/\(getuid())", url.path])
            if boot != 0 {
                // Fallback for anything older than `bootstrap`.
                _ = launchctl(["load", "-w", url.path])
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

/// A document view that lays out from the top. Without this an unflipped
/// `NSScrollView` document sits at the bottom of its clip view and the window
/// opens scrolled to the end.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Preferences window

/// The one window the app has. Everything that used to be a submenu lives
/// here or is reachable only from its shortcut, so the menu bar menu stays a
/// status line plus Preferences and Quit.
final class PreferencesController: NSWindowController, NSWindowDelegate, ShortcutButtonDelegate {

    struct Handlers {
        var currentArchivePath: () -> String
        var openArchive: () -> Void
        var chooseArchive: () -> Void
        var suspendShortcuts: () -> Void
        var resumeShortcuts: () -> Void
        var applyShortcuts: (Keybindings) -> [String]
        var microphoneGain: () -> Double
        var setMicrophoneGain: (Double) -> Void
        var microphonePreview: () -> Bool
        var setMicrophonePreview: (Bool) -> Void
        var closed: () -> Void
    }

    private let handlers: Handlers
    private var editor: Keybindings
    private var pendingAdd: HotKeyAction?
    private var pendingButton: ShortcutButton?

    /// ObjectIdentifier → (action, slot) for the recorder buttons currently on
    /// screen. Rebuilt from scratch whenever the set changes.
    private var buttonMap: [ObjectIdentifier: (action: HotKeyAction, slot: Int)] = [:]
    private var removeMap: [ObjectIdentifier: (action: HotKeyAction, slot: Int)] = [:]
    private var addMap: [ObjectIdentifier: HotKeyAction] = [:]

    private var shortcutStack: NSStackView!
    private var warningLabel: NSTextField!
    private var archiveLabel: NSTextField!
    private var gainLabel: NSTextField!
    private var launchCheckbox: NSButton!
    private var previewCheckbox: NSButton!

    init(keybindings: Keybindings, handlers: Handlers) {
        self.editor = keybindings
        self.handlers = handlers

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TABULA Preferences"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        refreshDynamicLabels()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }

        // The content is taller than a comfortable window, so it scrolls
        // rather than being clipped on a short display.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        // The three help lines that used to sit in the menu: the app is
        // screenless, so this is the only place they can be read calmly.
        for line in [
            "TABULA records into a folder you choose and stays out of the way — the coloured dot in the menu bar is the only display while you work.",
            "Everything is done with the global shortcuts below. Nothing is overwritten: every recording stays in the archive for good.",
            "Red = recording, green = playback, cyan = cue change, magenta = fine scrub. The ends of the archive get their own low blip.",
        ] {
            stack.addArrangedSubview(wrapping(line, width: 592, secondary: true))
        }

        stack.addArrangedSubview(spacing(4))
        stack.addArrangedSubview(header("Global shortcuts"))
        stack.addArrangedSubview(wrapping(
            "Click a shortcut and press the new keys. Escape cancels, + adds an alternative, × removes one.",
            width: 592,
            secondary: true
        ))

        shortcutStack = NSStackView()
        shortcutStack.orientation = .vertical
        shortcutStack.alignment = .leading
        shortcutStack.spacing = 6
        stack.addArrangedSubview(shortcutStack)

        warningLabel = wrapping("", width: 592, secondary: false)
        warningLabel.textColor = .systemRed
        stack.addArrangedSubview(warningLabel)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(header("Startup"))
        launchCheckbox = NSButton(
            checkboxWithTitle: "Launch TABULA at login",
            target: self,
            action: #selector(toggleLaunchAtLogin(_:))
        )
        stack.addArrangedSubview(launchCheckbox)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(header("Archive"))
        archiveLabel = wrapping("", width: 592, secondary: true)
        stack.addArrangedSubview(archiveLabel)
        let archiveButtons = NSStackView(views: [
            NSButton(title: "Open recording folder", target: self, action: #selector(openArchive(_:))),
            NSButton(title: "Change…", target: self, action: #selector(chooseArchive(_:))),
        ])
        archiveButtons.orientation = .horizontal
        archiveButtons.spacing = 8
        stack.addArrangedSubview(archiveButtons)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(header("Microphone"))
        let gainRow = NSStackView()
        gainRow.orientation = .horizontal
        gainRow.alignment = .centerY
        gainRow.spacing = 8
        gainRow.addArrangedSubview(NSButton(title: "Gain −", target: self, action: #selector(gainDown(_:))))
        gainRow.addArrangedSubview(NSButton(title: "Gain +", target: self, action: #selector(gainUp(_:))))
        gainLabel = NSTextField(labelWithString: "")
        gainLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        gainLabel.textColor = .secondaryLabelColor
        gainRow.addArrangedSubview(gainLabel)
        stack.addArrangedSubview(gainRow)
        previewCheckbox = NSButton(
            checkboxWithTitle: "Live level preview",
            target: self,
            action: #selector(toggleMicrophonePreview(_:))
        )
        stack.addArrangedSubview(previewCheckbox)

        rebuildShortcutRows()
        refreshDynamicLabels()
    }

    private func wrapping(_ text: String, width: CGFloat, secondary: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = width
        label.font = .systemFont(ofSize: secondary ? 12 : 13)
        if secondary { label.textColor = .secondaryLabelColor }
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 596).isActive = true
        return box
    }

    private func spacing(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    // MARK: Shortcut rows

    private func rebuildShortcutRows() {
        guard shortcutStack != nil else { return }
        buttonMap.removeAll()
        removeMap.removeAll()
        addMap.removeAll()
        pendingButton = nil
        for view in shortcutStack.arrangedSubviews { view.removeFromSuperview() }
        for action in HotKeyAction.allCases {
            shortcutStack.addArrangedSubview(makeShortcutRow(for: action))
        }
        pendingButton?.beginRecording()
    }

    private func makeShortcutRow(for action: HotKeyAction) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        let label = NSTextField(labelWithString: action.title)
        label.font = .systemFont(ofSize: 13)
        label.toolTip = action.hint
        label.widthAnchor.constraint(equalToConstant: 178).isActive = true
        row.addArrangedSubview(label)

        let combos = editor[action]
        if combos.isEmpty && pendingAdd != action {
            let none = NSTextField(labelWithString: "—")
            none.textColor = .tertiaryLabelColor
            row.addArrangedSubview(none)
        }

        for (slot, combo) in combos.enumerated() {
            let button = ShortcutButton(combo: combo)
            button.delegate = self
            buttonMap[ObjectIdentifier(button)] = (action, slot)
            row.addArrangedSubview(button)

            if combos.count > 1 {
                let remove = NSButton(title: "×", target: self, action: #selector(removeCombo(_:)))
                remove.bezelStyle = .inline
                remove.font = .systemFont(ofSize: 12)
                remove.toolTip = "Remove this shortcut"
                removeMap[ObjectIdentifier(remove)] = (action, slot)
                row.addArrangedSubview(remove)
            }
        }

        if pendingAdd == action {
            let button = ShortcutButton(combo: nil, placeholder: "unbound")
            button.delegate = self
            buttonMap[ObjectIdentifier(button)] = (action, combos.count)
            pendingButton = button
            row.addArrangedSubview(button)
        }

        let add = NSButton(title: "+", target: self, action: #selector(addCombo(_:)))
        add.bezelStyle = .inline
        add.font = .systemFont(ofSize: 12)
        add.toolTip = "Add an alternative shortcut"
        addMap[ObjectIdentifier(add)] = action
        row.addArrangedSubview(add)

        return row
    }

    // MARK: Shortcut editing

    @objc private func addCombo(_ sender: NSButton) {
        guard let action = addMap[ObjectIdentifier(sender)] else { return }
        pendingAdd = action
        rebuildShortcutRows()
    }

    @objc private func removeCombo(_ sender: NSButton) {
        guard let (action, slot) = removeMap[ObjectIdentifier(sender)] else { return }
        var list = editor[action]
        guard slot < list.count else { return }
        list.remove(at: slot)
        editor[action] = list
        commit()
    }

    func shortcutButtonWillRecord(_ button: ShortcutButton) {
        handlers.suspendShortcuts()
    }

    func shortcutButton(_ button: ShortcutButton, didCapture combo: KeyCombo) {
        guard let (action, slot) = buttonMap[ObjectIdentifier(button)] else {
            handlers.resumeShortcuts()
            return
        }

        if let other = editor.conflict(for: combo, excluding: action) {
            warn("\(combo.display) is already used by “\(other.title)”.")
            pendingAdd = nil
            handlers.resumeShortcuts()
            rebuildShortcutRows()
            return
        }
        let list = editor[action]
        if list.contains(where: { $0.conflicts(with: combo) }) {
            warn("\(combo.display) is already bound to “\(action.title)”.")
            pendingAdd = nil
            handlers.resumeShortcuts()
            rebuildShortcutRows()
            return
        }

        var updated = list
        if slot < updated.count {
            updated[slot] = combo
        } else {
            updated.append(combo)
        }
        editor[action] = updated
        pendingAdd = nil
        commit()
    }

    func shortcutButtonDidCancel(_ button: ShortcutButton) {
        let hadPending = pendingAdd != nil
        pendingAdd = nil
        handlers.resumeShortcuts()
        // Cancelling an existing binding only needs the button's title reset
        // (done in the button); rebuilding would tear down whatever control
        // the user just clicked. A cancelled "+" does need a rebuild, but one
        // deferred past the current responder change.
        guard hadPending else { return }
        DispatchQueue.main.async { [weak self] in self?.rebuildShortcutRows() }
    }

    /// Save the edited set, re-register, and surface anything that would not
    /// register (usually another app already owning the combination).
    private func commit() {
        let problems = handlers.applyShortcuts(editor)
        if problems.isEmpty {
            warningLabel.stringValue = ""
        } else {
            warn("⚠︎ not registered: " + problems.joined(separator: ", "))
        }
        rebuildShortcutRows()
    }

    private func warn(_ message: String) {
        warningLabel.stringValue = message
    }

    // MARK: Buttons

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let wantsOn = sender.state == .on
        if let error = LoginItem.setEnabled(wantsOn) {
            warn("Could not update the login item: \(error)")
            sender.state = wantsOn ? .off : .on
            return
        }
        warningLabel.stringValue = ""
    }

    @objc private func openArchive(_ sender: Any?) {
        handlers.openArchive()
    }

    @objc private func chooseArchive(_ sender: Any?) {
        handlers.chooseArchive()
        refreshDynamicLabels()
    }

    @objc private func gainUp(_ sender: Any?) { stepGain(+1) }

    @objc private func gainDown(_ sender: Any?) { stepGain(-1) }

    private func stepGain(_ steps: Int) {
        let next = handlers.microphoneGain() + Double(steps) * 3
        let clamped = max(-24, min(24, next))
        handlers.setMicrophoneGain(clamped)
        refreshDynamicLabels()
    }

    @objc private func toggleMicrophonePreview(_ sender: NSButton) {
        handlers.setMicrophonePreview(sender.state == .on)
    }

    private func refreshDynamicLabels() {
        archiveLabel?.stringValue = handlers.currentArchivePath()
        gainLabel?.stringValue = String(format: "%+.0f dB", handlers.microphoneGain())
        launchCheckbox?.state = LoginItem.isEnabled ? .on : .off
        previewCheckbox?.state = handlers.microphonePreview() ? .on : .off
    }

    // MARK: Window delegate

    func windowWillClose(_ notification: Notification) {
        // The window's close button is a mode switch, not a save: edits are
        // applied as they are made. Hand the app back to accessory mode.
        handlers.resumeShortcuts()
        handlers.closed()
    }
}
