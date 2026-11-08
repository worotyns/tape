import AppKit
import AVFoundation
import TapeCore

/// The whole app: a status item, a minimal menu, a handful of global hot keys,
/// and a 20 Hz tick that drives the domain. There is no main window and the app
/// never activates itself, so it can never steal focus from what you are doing;
/// the only window is Preferences, opened deliberately from the menu.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let clock = RealClock()
    private let log = EventLog()
    private let mic = MicCapture()
    private let sink = AudioPlayer()
    private let tones = ToneFeedback()
    private let led = StatusLED()

    private var hotKeys: HotKeyCenter?
    private var device: Device?
    private var library: Library?
    private var libraryURL = AppDelegate.defaultLibraryURL()
    private var keybindings = Keybindings.load()
    private var preferences: PreferencesController?

    private var timer: DispatchSourceTimer?
    private var lastTickMs: Double = 0
    private var recordingAssertion: NSObjectProtocol?
    private var lastFeedbackAt: Double = -1
    private var statusNote: String?
    private var hotKeyProblems: [String] = []
    /// Change detector for the remembered cursor. Deliberately an Int: reading
    /// the current cue touches the disk, and the tick runs 20 times a second.
    private var lastCursorIndex: Int = -1

    private var micStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: - Lifecycle

    private static func defaultLibraryURL() -> URL {
        if let saved = UserDefaults.standard.string(forKey: "libraryPath") {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return Rename.defaultArchiveURL()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        led.menu = menu
        buildMainMenu()

        // Deliberately no microphone prompt at launch: an audio recorder should
        // ask the first time you actually record, not while you are working.
        // The prompt is raised by `recAction()` instead.
        openLibrary(at: libraryURL)
        registerHotKeys()
        startTicking()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finalize anything in flight so quitting never truncates a recording.
        if let device, device.recordingNow { device.setRec(false) }
        endRecordingAssertion()
    }

    // MARK: - Library

    private func openLibrary(at url: URL) {
        // Re-selecting the archive we already hold would deadlock against our
        // own lock, and there is nothing to do anyway.
        if let existing = library, existing.root.path == url.path { return }

        do {
            let lib = try Library.open(at: url)
            // One writer per archive. LaunchServices reuses a running instance of
            // the *same* bundle, but the installed copy and a freshly built one
            // are two bundles: without this they collide on recording ids.
            guard lib.acquireLock() else {
                statusNote = "another TAPE is already using \(url.path)"
                note(statusNote!)
                return
            }
            let dev = Device(
                clock: clock,
                log: log,
                library: lib,
                mic: mic,
                sink: sink,
                config: configuration()
            )
            dev.boot()
            let previous = library
            library = lib
            device = dev
            libraryURL = url
            previous?.releaseLock()
            statusNote = nil
            restoreCursor(dev)
            let recovered = lib.listRecordings().filter { $0.recovered == true }.count
            if recovered > 0 {
                statusNote = "recovered \(recovered) interrupted recording\(recovered == 1 ? "" : "s")"
            }
        } catch {
            library = nil
            device = nil
            statusNote = "cannot open archive: \(error)"
            note(statusNote!)
        }
    }

    // MARK: - Remembered cursor
    //
    // Without this the cursor starts at the very beginning of the archive on
    // every launch, which reads as "navigation always starts from the top".
    // Stored as a cue identity rather than an index, so it survives new
    // recordings being appended.

    private func cursorKey() -> String? {
        library.map { "cursor.\($0.libraryId)" }
    }

    private func restoreCursor(_ device: Device) {
        guard let key = cursorKey(),
              let token = UserDefaults.standard.string(forKey: key) else { return }
        let parts = token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return }
        let recordingId = String(parts[0])
        let kind = String(parts[1])
        let markerId = Int(parts[2]) ?? 0
        guard let index = device.cues().firstIndex(where: {
            $0.recordingId == recordingId && $0.kind.rawValue == kind && ($0.markerId ?? 0) == markerId
        }) else { return }
        device.selectCueIndex(index)
        lastCursorIndex = device.cueIndex
    }

    private func saveCursorIfMoved(_ device: Device) {
        guard device.cueIndex != lastCursorIndex else { return }
        lastCursorIndex = device.cueIndex
        guard let key = cursorKey(), let cue = device.currentCue() else { return }
        UserDefaults.standard.set(
            "\(cue.recordingId)|\(cue.kind.rawValue)|\(cue.markerId ?? 0)",
            forKey: key
        )
    }

    private func configuration() -> Config {
        var config = Config()
        config.micPreview = false
        if let saved = UserDefaults.standard.object(forKey: "micGainDb") as? Double {
            config.micGainDb = saved
        }
        return config
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as archive"
        panel.message = "Pick the folder TAPE should use as its archive."
        panel.directoryURL = libraryURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Finalize anything in flight before switching archives.
        if let device, device.recordingNow { device.setRec(false) }
        // Only an explicit choice is remembered; the default is never written
        // into preferences.
        UserDefaults.standard.set(url.path, forKey: "libraryPath")
        openLibrary(at: url)
    }

    /// REC, but permission-aware: the microphone prompt is raised here, on the
    /// first attempt to record, and a granted prompt continues into recording.
    private func recAction() {
        guard let device else { return }
        if device.recordingNow {
            device.setRec(false)
            return
        }
        switch micStatus {
        case .authorized:
            device.setRec(true)
        case .notDetermined:
            statusNote = "waiting for microphone permission…"
            MicCapture.requestPermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.statusNote = nil
                    self.device?.setRec(true)
                } else {
                    self.statusNote = "microphone denied — System Settings › Privacy & Security › Microphone"
                }
            }
        default:
            statusNote = "microphone denied — System Settings › Privacy & Security › Microphone"
            device.setRec(true) // rejects with mic_unavailable: red blinking LED
        }
    }

    // MARK: - Hot keys
    //
    // Control-Option is the namespace: rarely taken by other apps, and the whole
    // device is three controls, so six shortcuts cover it.

    private func registerHotKeys() {
        // Release the previous centre *first*. Its hot keys are still live, and
        // Carbon refuses a duplicate with eventHotKeyExistsErr — so registering
        // before letting go would make every shortcut fail on any second pass
        // (closing Preferences, for instance). On the very first call `hotKeys`
        // is already nil and this is a no-op.
        hotKeys = nil
        let center = HotKeyCenter()
        hotKeyProblems = []

        // Ids only have to be unique within a registration pass; the action is
        // captured by the closure, so a rebind is just a fresh pass.
        var id: UInt32 = 1
        for action in HotKeyAction.allCases {
            for combo in keybindings[action] {
                let thisID = id
                id += 1
                let registered = center.register(
                    key: Int(combo.keyCode),
                    modifiers: Int(combo.modifiers),
                    id: thisID,
                    handler: { [weak self] in self?.perform(action) }
                )
                if !registered {
                    hotKeyProblems.append("\(action.title) \(combo.display)")
                }
            }
        }
        hotKeys = center
    }

    /// The single dispatch point behind every binding, so what an action *does*
    /// lives in one place no matter which keys point at it.
    private func perform(_ action: HotKeyAction) {
        switch action {
        case .record:
            recAction()
        case .mem:
            // During recording: a marker. Outside it: rewind ~2.5 s and audition.
            device?.memPress()
        case .previousCue:
            device?.wheel(-1)
        case .nextCue:
            device?.wheel(1)
        case .scrubBackward:
            if let device { device.seekBy(-device.cfg.scrubSeconds) }
        case .scrubForward:
            if let device { device.seekBy(device.cfg.scrubSeconds) }
        case .playPause:
            device?.wheelClick()
        case .announce:
            announce()
        }
    }

    /// Drop the global hot keys while a shortcut is being recorded — Carbon
    /// would otherwise swallow the very keystroke the user is pressing.
    private func suspendHotKeys() {
        hotKeys = nil
    }

    private func announce() {
        guard let info = device?.announce() else { return }
        tones.announce(info)
    }

    // MARK: - Tick loop

    private func startTicking() {
        lastTickMs = ProcessInfo.processInfo.systemUptime * 1000
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + .milliseconds(50),
            repeating: .milliseconds(50),
            leeway: .milliseconds(10)
        )
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime * 1000
        let dt = min(250, max(0, now - lastTickMs))
        lastTickMs = now

        guard let device else { return }

        // Deliberately NOT a full snapshot: that would re-read and decode every
        // metadata file 20 times a second. The tick only needs the LED and the
        // sound pattern; the menu builds a snapshot when it is opened.
        device.tick(dt)
        led.update(device.ledState(), dtMs: dt)

        if let feedback = device.lastFeedback, feedback.atMs != lastFeedbackAt {
            lastFeedbackAt = feedback.atMs
            tones.play(feedback)
        }

        saveCursorIfMoved(device)
        updateRecordingAssertion(isRecording: device.activity == .recording)
    }

    /// App Nap would otherwise throttle a background recorder.
    private func updateRecordingAssertion(isRecording: Bool) {
        if isRecording {
            if recordingAssertion == nil {
                recordingAssertion = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "TAPE is recording"
                )
            }
        } else {
            endRecordingAssertion()
        }
    }

    private func endRecordingAssertion() {
        if let token = recordingAssertion {
            ProcessInfo.processInfo.endActivity(token)
            recordingAssertion = nil
        }
    }

    // MARK: - Menu

    /// A real main menu, so that when the preferences window makes the app
    /// "regular" for a moment there is an app menu and working Edit commands.
    /// While the app is an accessory this is never shown.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(action("Preferences…", #selector(menuPreferences), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(action("Quit TAPE", #selector(menuQuit), key: "q"))
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // The menu is a status line plus two actions, deliberately: the app is
        // driven entirely by global shortcuts, so there is no navigation to do
        // from a context menu and nothing that could drift out of sync with the
        // bindings. Everything else lives in Preferences.
        if let device {
            menu.addItem(disabled(statusLine(device.snapshot())))
        } else {
            menu.addItem(disabled("no archive open"))
        }
        if let note = statusNote { menu.addItem(disabled(note)) }
        // A shortcut that failed to register is otherwise invisible: the key
        // simply does nothing, which is indistinguishable from a broken app.
        // Derived from live state rather than parked in `statusNote`, so it
        // disappears the moment registration succeeds.
        if !hotKeyProblems.isEmpty {
            menu.addItem(disabled("⚠︎ not registered: \(hotKeyProblems.joined(separator: ", "))"))
        }
        menu.addItem(.separator())
        menu.addItem(action("Preferences…", #selector(menuPreferences), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit TAPE", #selector(menuQuit), key: "q"))
    }

    private func statusLine(_ snapshot: Snapshot) -> String {
        var parts: [String] = []
        switch snapshot.activity {
        case .recording:
            let samples = snapshot.recording?.samples ?? 0
            parts.append("● REC \(formatSeconds(Double(samples) / 16000))")
            let markers = snapshot.recording?.markers.count ?? 0
            if markers > 0 { parts.append("⚑\(markers)") }
        case .playing, .paused:
            if let pb = snapshot.playback {
                parts.append("\(snapshot.activity == .playing ? "▸" : "‖") \(pb.id) \(formatSeconds(pb.positionMs / 1000)) / \(formatSeconds(pb.durationMs / 1000))")
            }
        case .error:
            parts.append("⚠︎ \(snapshot.error?.reason ?? "error")")
        default:
            parts.append("idle")
            parts.append("\(snapshot.stats.recordings) rec · \(formatSeconds(snapshot.stats.totalDurationMs / 1000)) · ⚑\(snapshot.stats.totalMarkers)")
        }
        return parts.joined(separator: "  ")
    }

    // MARK: - Preferences

    @objc private func menuPreferences(_ sender: Any?) { showPreferences() }

    private func showPreferences() {
        if preferences == nil {
            let handlers = PreferencesController.Handlers(
                currentArchivePath: { [weak self] in self?.libraryURL.path ?? "—" },
                openArchive: { [weak self] in
                    guard let self else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([self.libraryURL])
                },
                chooseArchive: { [weak self] in self?.chooseLibrary() },
                suspendShortcuts: { [weak self] in self?.suspendHotKeys() },
                resumeShortcuts: { [weak self] in self?.registerHotKeys() },
                applyShortcuts: { [weak self] bindings in
                    guard let self else { return [] }
                    bindings.save()
                    self.keybindings = bindings
                    self.registerHotKeys()
                    return self.hotKeyProblems
                },
                microphoneGain: { [weak self] in self?.device?.micGainDb ?? 0 },
                setMicrophoneGain: { [weak self] db in self?.applyMicGain(db) },
                microphonePreview: { [weak self] in self?.device?.micPreview ?? false },
                setMicrophonePreview: { [weak self] on in self?.device?.setMicPreview(on) },
                closed: { [weak self] in
                    // Deferred: this fires from inside the controller's own
                    // `windowWillClose`, and clearing the reference would free
                    // it mid-call.
                    DispatchQueue.main.async {
                        self?.preferences = nil
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            )
            preferences = PreferencesController(keybindings: keybindings, handlers: handlers)
        }
        // A preferences window needs focus; the app is normally an accessory,
        // so borrow regular mode until the window closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        preferences?.show()
    }

    /// Absolute gain, in dB, remembered for the next launch.
    private func applyMicGain(_ db: Double) {
        guard let device else { return }
        let gain = device.setMicGainDb(db)
        UserDefaults.standard.set(gain, forKey: "micGainDb")
    }

    @objc private func menuQuit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Menu helpers

    private func action(
        _ title: String,
        _ selector: Selector,
        key: String = "",
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.tag = tag
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("tape: \(message)\n".utf8))
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

}
