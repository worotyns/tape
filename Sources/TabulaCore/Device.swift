// TABULA device domain model, ported from the JS simulator with the hardware
// removed. What is left is the concept:
//
//   * capture that never loses data (append-only, repairable, recoverable)
//   * navigation by cue points — recording starts and MEM markers — not files
//   * audition: moving the cursor immediately plays what you landed on
//   * MEM is a tape rewind outside recording, and a marker during it
//   * the archive is immutable: nothing deletes or overwrites a recording
//
// Time is injected and the state machine is driven only by `tick(dtMs)`, so it
// stays deterministic and testable without any audio hardware.

import Foundation

// MARK: - State

public final class ActiveRecording {
    public let id: String
    public let seq: Int
    public let wav: WavStream
    public let startMs: Double
    public let createdAtMs: Double
    public var samples: Int = 0
    public var peak: Double = 0
    public var markers: [Marker] = []
    public var lastSyncMs: Double

    init(id: String, seq: Int, wav: WavStream, startMs: Double) {
        self.id = id
        self.seq = seq
        self.wav = wav
        self.startMs = startMs
        self.createdAtMs = startMs
        self.lastSyncMs = startMs
    }
}

public struct PlaybackState: Sendable, Equatable {
    public var recordingId: String
    public var positionSamples: Int
    public var durationSamples: Int
    public var playing: Bool
}

// MARK: - Snapshot (what the host renders)

public struct MicSnapshot: Sendable {
    public var gainDb: Double
    public var preview: Bool
    public var level: Double
    public var rms: Double
    public var peakHold: Double
    public var clipping: Bool
}

public struct LibrarySnapshot: Sendable {
    public var present: Bool
    public var id: String?
    public var path: String?
    public var usedBytes: Int
}

public struct ActiveRecordingSnapshot: Sendable {
    public var id: String
    public var samples: Int
    public var markers: [Marker]
    public var level: Double
}

public struct PlaybackSnapshot: Sendable {
    public var id: String
    public var positionSamples: Int
    public var durationSamples: Int
    public var playing: Bool
    public var positionMs: Double
    public var durationMs: Double
}

public struct Stats: Sendable {
    public var recordings: Int
    public var totalDurationMs: Double
    public var totalMarkers: Int
    public var totalRecordedMs: Double
    public var rejected: Int
}

public struct Snapshot: Sendable {
    public var nowMs: Double
    public var activity: Activity
    public var recSwitch: Bool
    public var error: DeviceError?
    public var led: LedState
    public var mic: MicSnapshot
    public var volume: Double
    public var library: LibrarySnapshot
    public var recordings: [RecordingMeta]
    public var cueIndex: Int
    public var cueCount: Int
    public var cue: Cue?
    public var recording: ActiveRecordingSnapshot?
    public var playback: PlaybackSnapshot?
    public var stats: Stats
    public var feedback: Feedback?
    public var events: [Event]
}

// MARK: - Device

public final class Device {
    public let clock: Clock
    public let log: EventLog
    public let mic: MicSource
    public let sink: AudioSink
    public var cfg: Config

    public private(set) var library: Library?
    public private(set) var activity: Activity = .idle
    public private(set) var recSwitch = false
    public private(set) var error: DeviceError?
    public private(set) var recording: ActiveRecording?
    public private(set) var playback: PlaybackState?
    public private(set) var cueIndex = 0
    public private(set) var micGainDb: Double
    public private(set) var micPreview: Bool
    public private(set) var volume: Double

    private var meter = (level: 0.0, rms: 0.0, peakHold: 0.0, peakHoldAt: 0.0, clipping: false)
    private var ledPulse: (color: LedColor, reason: String, mode: LedMode, until: Double)?
    private var ledKey: String?

    /// Last sound pattern produced. Read by the host's tick loop, which must
    /// stay cheap — that is why it reads this instead of a full snapshot.
    public private(set) var lastFeedback: Feedback?

    private var totalRecordedSamples = 0
    private var totalMarkers = 0
    private var rejected = 0
    private var lastEdgeFeedback: (reason: String, atMs: Double)?

    public init(
        clock: Clock,
        log: EventLog,
        library: Library? = nil,
        mic: MicSource,
        sink: AudioSink,
        config: Config = Config()
    ) {
        self.clock = clock
        self.log = log
        self.mic = mic
        self.sink = sink
        self.cfg = config
        self.micGainDb = config.micGainDb
        self.micPreview = config.micPreview
        self.volume = min(config.volume, config.volumeCap)
        if let library { mount(library) }
    }

    // MARK: - Mount / boot

    private func mount(_ library: Library) {
        self.library = library
        log.attach { [weak library] event in library?.appendEvent(event) }
        recover()
        clampSelection()
    }

    @discardableResult
    public func recover() -> [RecordingMeta] {
        guard let library else { return [] }
        let recovered = library.recover { [weak self] message in
            guard let self else { return }
            self.log.emit(self.clock.nowMs, .recovery, ["message": .string(message)])
        }
        for report in library.takeQuarantineReports() {
            log.emit(clock.nowMs, .metadataQuarantined, [
                "file": .string(report.file),
                "error": .string(report.error),
            ])
        }
        for meta in recovered {
            log.emit(clock.nowMs, .recovery, [
                "id": .string(meta.id),
                "durationSamples": .int(meta.durationSamples),
            ])
        }
        clampSelection()
        return recovered
    }

    public func boot() {
        activity = .idle
        log.emit(clock.nowMs, .boot, ["recSwitch": .bool(recSwitch)])
        if recSwitch { beginRecording() }
        syncLed()
    }

    // MARK: - Derived state

    public var recordingNow: Bool {
        activity == .recording && recording != nil
    }

    public var playingNow: Bool {
        (activity == .playing || activity == .paused) && playback != nil
    }

    // MARK: - LED

    private func pulseLed(_ color: LedColor, _ reason: String, mode: LedMode = .steady, ms: Double? = nil) {
        let duration = ms ?? cfg.ledFlashMs
        ledPulse = (color: color, reason: reason, mode: mode, until: clock.nowMs + duration)
    }

    private func flashLed(_ color: LedColor, _ reason: String) {
        pulseLed(color, reason, mode: .flash, ms: cfg.ledFlashMs)
    }

    /// The menu bar icon is the only display: one colour per state.
    public func ledState() -> LedState {
        let now = clock.nowMs
        if let error { return LedState(color: .red, mode: .blink, reason: error.reason) }
        if recordingNow { return LedState(color: .red, mode: .steady, reason: "recording") }
        if let p = ledPulse, now < p.until, p.mode == .flash {
            return LedState(color: p.color, mode: .flash, reason: p.reason)
        }
        if let p = ledPulse, now < p.until {
            return LedState(color: p.color, mode: p.mode, reason: p.reason)
        }
        if let pb = playback, playingNow {
            return LedState(
                color: .green,
                mode: pb.playing ? .steady : .blink,
                reason: pb.playing ? "playing" : "paused"
            )
        }
        return .off
    }

    private func syncLed() {
        let led = ledState()
        let key = "\(led.color?.rawValue ?? "-")|\(led.mode.rawValue)|\(led.reason ?? "-")"
        guard key != ledKey else { return }
        ledKey = key
        log.emit(clock.nowMs, .ledChanged, [
            "color": led.color.map { JSONValue.string($0.rawValue) } ?? .null,
            "mode": .string(led.mode.rawValue),
            "reason": led.reason.map { JSONValue.string($0) } ?? .null,
        ])
    }

    // MARK: - REC

    public func setRec(_ on: Bool) {
        guard recSwitch != on else { return }
        recSwitch = on
        log.emit(clock.nowMs, on ? .recOn : .recOff, ["physical": true])

        if on {
            // Recording takes priority over playback.
            if playback != nil { stopPlayback("rec_on") }
            error = nil
            if !recordingNow { beginRecording() }
        } else if recordingNow {
            finalizeRecording("rec_off")
            if !recordingNow {
                error = nil
                activity = .idle
            }
        } else if activity == .error {
            error = nil
            activity = .idle
        }
        refreshActivity()
        syncLed()
    }

    public func toggleRec() {
        setRec(!recSwitch)
    }

    private func beginRecording() {
        guard let library else { return rejectRecord("no_library") }
        guard let seq = try? library.nextSeq() else { return rejectRecord("library_unwritable") }
        let id = Library.recId(seq)
        let url = library.recordingURL(id, ext: "wav")

        let wav: WavStream
        do {
            wav = try WavStream(
                url: url,
                sampleRate: cfg.sampleRate,
                channels: cfg.channels,
                bitsPerSample: cfg.bitsPerSample
            )
        } catch {
            return rejectRecord("write_error", detail: String(describing: error))
        }

        // Distinct per recording, and deterministic.
        (mic as? SeededMicSource)?.setSeed(UInt32(truncatingIfNeeded: seq &* 2654435761))

        do {
            try mic.start()
        } catch {
            // No input device or permission denied: reject with the distinctive
            // error pattern instead of writing a silent file.
            wav.abandon()
            try? FileManager.default.removeItem(at: url)
            return rejectRecord("mic_unavailable", detail: String(describing: error))
        }

        recording = ActiveRecording(id: id, seq: seq, wav: wav, startMs: clock.nowMs)
        sink.stop()
        activity = .recording
        error = nil
        log.emit(clock.nowMs, .recordingStarted, [
            "id": .string(id),
            "seq": .int(seq),
            "path": .string(url.path),
        ])
    }

    private func rejectRecord(_ reason: String, detail: String? = nil) {
        rejected += 1
        // Distinctive error feedback: three long pulses.
        feedback(Feedback(kind: .error, pulses: [600, 200, 600, 200, 600], reason: reason, atMs: clock.nowMs))
        error = DeviceError(code: "REC_REJECTED", reason: reason, detail: detail)
        activity = .error
        log.emit(clock.nowMs, .recordingRejected, [
            "reason": .string(reason),
            "detail": detail.map { JSONValue.string($0) } ?? .null,
        ])
        log.emit(clock.nowMs, .error, [
            "code": "REC_REJECTED",
            "reason": .string(reason),
            "detail": detail.map { JSONValue.string($0) } ?? .null,
        ])
    }

    /// Returns false when the bytes could not be made durable.
    private func writeRaw(_ rec: ActiveRecording, _ raw: Data) -> Bool {
        let usable = raw.count - (raw.count % 2)
        guard usable > 0 else { return true }
        let gained = micGainDb != 0 ? PCM.applyGain(raw, gainDb: micGainDb) : raw
        do {
            try rec.wav.append(gained)
        } catch {
            log.emit(clock.nowMs, .error, [
                "code": "WRITE_FAILED",
                "id": .string(rec.id),
                "detail": .string(String(describing: error)),
            ])
            return false
        }
        rec.samples += gained.count / 2
        totalRecordedSamples += gained.count / 2
        let analysis = PCM.analyze(gained)
        rec.peak = max(rec.peak, analysis.peak)
        applyMeter(analysis)
        return true
    }

    private func updateRecording() {
        guard let rec = recording else { return }
        let maxSamples = cfg.maxRecordingSeconds * cfg.sampleRate

        if let raw = mic.read(), raw.count >= 2 {
            if !writeRaw(rec, raw) {
                finalizeRecording("write_error")
                return
            }
        }
        if rec.samples >= maxSamples {
            finalizeRecording("max_duration")
            return
        }
        if clock.nowMs - rec.lastSyncMs >= cfg.syncIntervalMs {
            rec.wav.sync()
            rec.lastSyncMs = clock.nowMs
        }
    }

    @discardableResult
    private func finalizeRecording(_ reason: String) -> RecordingMeta? {
        guard let rec = recording else { return nil }

        var sizeBytes = rec.wav.sizeBytes
        var durationSamples = rec.wav.durationSamples
        do {
            sizeBytes = try rec.wav.finalize()
            durationSamples = rec.wav.durationSamples
        } catch {
            rec.wav.abandon()
            durationSamples = rec.samples
            sizeBytes = WavStream.headerBytes + rec.samples * 2
        }

        let meta = RecordingMeta(
            id: rec.id,
            seq: rec.seq,
            format: "pcm",
            codec: "pcm_s16le",
            sampleRate: cfg.sampleRate,
            channels: cfg.channels,
            bitsPerSample: cfg.bitsPerSample,
            durationSamples: durationSamples,
            sizeBytes: sizeBytes,
            markers: rec.markers,
            status: "finalized",
            createdAt: clock.iso(rec.createdAtMs),
            finalizedAt: clock.iso(),
            finalizeReason: reason
        )
        recording = nil
        if let library {
            do {
                try library.writeMetadata(meta)
            } catch {
                log.emit(clock.nowMs, .error, [
                    "code": "METADATA_WRITE_FAILED",
                    "id": .string(rec.id),
                    "detail": .string(String(describing: error)),
                ])
            }
        }

        syncMic()
        log.emit(clock.nowMs, .recordingFinalized, [
            "id": .string(meta.id),
            "durationSamples": .int(durationSamples),
            "sizeBytes": .int(sizeBytes),
            "reason": .string(reason),
            "markers": .int(meta.markers.count),
        ])

        if reason == "write_error" {
            error = DeviceError(code: "WRITE_ERROR", reason: reason)
            activity = .error
        } else if recSwitch && reason == "max_duration" {
            // Roll over to a new immutable recording.
            beginRecording()
        } else {
            activity = .idle
        }
        clampSelection()
        // A tape recorder parks its head on the tape you just made. Staying put
        // meant that after recording you would audition an old clip and
        // conclude the navigation was broken.
        if let index = cueIndexForRecordingStart(meta.id) {
            cueIndex = index
        }
        syncLed()
        return meta
    }

    // MARK: - Cues
    //
    // A cue is a navigation point: the start of a recording, or a MEM marker.
    // The wheel walks this flat, ordered list across all recordings.

    public func cues() -> [Cue] {
        var out: [Cue] = []
        for r in recordings() {
            out.append(Cue(recordingId: r.id, kind: .start, sampleOffset: 0, markerId: nil))
            for m in r.markers.sorted(by: { $0.sampleOffset < $1.sampleOffset }) {
                out.append(Cue(recordingId: r.id, kind: .marker, sampleOffset: m.sampleOffset, markerId: m.id))
            }
        }
        return out
    }

    public func currentCue() -> Cue? {
        let list = cues()
        guard !list.isEmpty else { return nil }
        return list[max(0, min(cueIndex, list.count - 1))]
    }

    @discardableResult
    private func playCue(_ cue: Cue, playing: Bool) -> PlaybackState? {
        guard let meta = recordingMeta(cue.recordingId) else { return nil }
        let position = max(0, min(cue.sampleOffset, meta.durationSamples))
        playback = PlaybackState(
            recordingId: cue.recordingId,
            positionSamples: position,
            durationSamples: meta.durationSamples,
            playing: playing
        )
        activity = playing ? .playing : .paused
        if playing {
            sink.setVolume(volume)
            sink.play(url: fileURL(for: meta), atSample: position)
        } else {
            sink.pause()
        }
        log.emit(clock.nowMs, .playbackSeek, [
            "id": .string(cue.recordingId),
            "cue": .string(cue.kind.rawValue),
            "marker": cue.markerId.map { JSONValue.int($0) } ?? .null,
            "sampleOffset": .int(position),
        ])
        return playback
    }

    @discardableResult
    private func moveCue(
        _ delta: Int,
        forcePlay: Bool = false,
        quiet: Bool = false,
        clamp: Bool = false
    ) -> Cue? {
        let list = cues()
        guard !list.isEmpty else {
            if !quiet { negativeFeedback("no_cues") }
            return nil
        }
        var next = cueIndex + delta
        if next < 0 || next >= list.count {
            if !clamp {
                if !quiet { negativeFeedback(delta > 0 ? "no_next_cue" : "no_prev_cue") }
                return nil
            }
            next = max(0, min(list.count - 1, next))
        }
        let moved = next != cueIndex
        cueIndex = next
        let cue = list[next]
        if moved { flashLed(.cyan, "cue") }
        guard moved else {
            // Hitting the end of the archive used to be a completely silent
            // no-op — indistinguishable from broken navigation on a device with
            // no screen. Make the wall audible, but once per burst and per wall:
            // a held key auto-repeats every ~20 ms, while walking from one wall
            // to the other should still speak.
            let reason = delta > 0 ? "end_of_archive" : "start_of_archive"
            let repeated = lastEdgeFeedback.map {
                $0.reason == reason && clock.nowMs - $0.atMs < cfg.edgeFeedbackMs
            } ?? false
            if !quiet, !repeated {
                lastEdgeFeedback = (reason: reason, atMs: clock.nowMs)
                negativeFeedback(reason)
            }
            return cue
        }
        if playback != nil || forcePlay {
            let playing = playback.map { $0.playing || forcePlay } ?? true
            playCue(cue, playing: playing)
        } else {
            activity = .browsing
        }
        return cue
    }

    /// Fine seek within the current recording (jog/scrub). The cue cursor stays
    /// where it is; the playback position moves and auditions what it lands on.
    @discardableResult
    public func seekBy(_ seconds: Double) -> Int? {
        log.emit(clock.nowMs, .scrub, ["seconds": .double(seconds)])
        if recordingNow { return nil }

        guard let cue = currentCue() else {
            negativeFeedback("no_cues")
            return nil
        }
        guard let meta = recordingMeta(cue.recordingId) else { return nil }

        let rate = Double(cfg.sampleRate)
        let duration = meta.durationSamples
        let from = playback?.positionSamples ?? cue.sampleOffset
        let to = max(0, min(duration, from + Int((seconds * rate).rounded())))

        let playing = cfg.scrubAutoplay ? true : (playback?.playing ?? true)
        playback = PlaybackState(
            recordingId: cue.recordingId,
            positionSamples: to,
            durationSamples: duration,
            playing: playing
        )
        activity = playing ? .playing : .paused
        if playing {
            sink.setVolume(volume)
            sink.play(url: fileURL(for: meta), atSample: to)
        } else {
            sink.pause()
        }
        log.emit(clock.nowMs, .playbackSeek, [
            "id": .string(cue.recordingId),
            "cue": "scrub",
            "deltaSeconds": .double(seconds),
            "sampleOffset": .int(to),
        ])
        flashLed(.magenta, "scrub")
        feedback(Feedback(kind: .ok, pulses: [40], reason: nil, atMs: clock.nowMs))
        syncLed()
        return to
    }

    public enum JumpTarget: Sendable {
        case start, end
    }

    @discardableResult
    public func jumpTo(_ target: JumpTarget) -> Cue? {
        let list = cues()
        guard !list.isEmpty else {
            negativeFeedback("no_cues")
            return nil
        }
        cueIndex = target == .end ? list.count - 1 : 0
        let cue = list[cueIndex]
        if let pb = playback { playCue(cue, playing: pb.playing) } else { activity = .browsing }
        syncLed()
        return cue
    }

    // MARK: - MEM
    //
    // During recording: a sample-accurate marker.
    // Outside recording: a tape rewind — step back a couple of seconds and
    // audition, so you can re-hear what you just missed.

    @discardableResult
    public func memPress() -> Marker? {
        log.emit(clock.nowMs, .memPress, [:])

        if recordingNow, let rec = recording {
            let marker = Marker(id: rec.markers.count + 1, sampleOffset: rec.samples, atSimMs: clock.nowMs)
            rec.markers.append(marker)
            totalMarkers += 1
            log.emit(clock.nowMs, .markerAdded, [
                "id": .string(rec.id),
                "marker": .int(marker.id),
                "sampleOffset": .int(marker.sampleOffset),
            ])
            feedback(Feedback(kind: .marker, pulses: [80], reason: nil, atMs: clock.nowMs))
            return marker
        }

        rewind(cfg.memRewindSeconds)
        return nil
    }

    /// Jump back by `seconds` within the current recording (auditions).
    @discardableResult
    public func rewind(_ seconds: Double) -> Int? {
        guard currentCue() != nil else {
            negativeFeedback("nothing_to_rewind")
            return nil
        }
        log.emit(clock.nowMs, .memRewind, ["seconds": .double(abs(seconds))])
        return seekBy(-abs(seconds))
    }

    /// Screenless "where am I": pitch encodes the position in the archive.
    @discardableResult
    public func announce() -> Announcement? {
        let list = cues()
        guard !list.isEmpty else {
            negativeFeedback("no_cues")
            return nil
        }
        let cue = currentCue()!
        let info = Announcement(
            cueIndex: cueIndex,
            cueCount: list.count,
            kind: cue.kind,
            recordingId: cue.recordingId,
            sampleOffset: cue.sampleOffset
        )
        log.emit(clock.nowMs, .announce, [
            "cueIndex": .int(cueIndex),
            "cueCount": .int(list.count),
            "kind": .string(cue.kind.rawValue),
            "id": .string(cue.recordingId),
        ])
        return info
    }

    // MARK: - Microphone chain

    public func setMicGainDb(_ db: Double) -> Double {
        let clamped = max(cfg.micGainMinDb, min(cfg.micGainMaxDb, db))
        micGainDb = clamped
        log.emit(clock.nowMs, .micGain, ["gainDb": .double(clamped)])
        return clamped
    }

    @discardableResult
    public func adjustMicGain(_ steps: Int = 1) -> Double {
        setMicGainDb(micGainDb + Double(steps) * cfg.micGainStepDb)
    }

    @discardableResult
    public func setMicPreview(_ on: Bool) -> Bool {
        micPreview = on
        syncMic()
        return micPreview
    }

    public func setVolume(_ v: Double) {
        volume = max(0, min(cfg.volumeCap, v))
        sink.setVolume(volume)
    }

    public func adjustVolume(_ delta: Double) {
        setVolume(volume + delta)
    }

    private func applyMeter(_ analysis: PCMAnalysis) {
        meter.level = analysis.peak
        meter.rms = analysis.rms
        meter.clipping = analysis.clipping
        let now = clock.nowMs
        if analysis.peak >= meter.peakHold || now - meter.peakHoldAt > cfg.micPeakHoldMs {
            meter.peakHold = analysis.peak
            meter.peakHoldAt = now
        }
    }

    /// Start the mic when it is needed (recording or preview), stop it otherwise.
    private func syncMic() {
        let want = recording != nil || micPreview
        if want, !mic.isRunning {
            try? mic.start()
        } else if !want, mic.isRunning {
            mic.stop()
        }
    }

    private func updateMic() {
        if recordingNow { return } // recording chunks drive the meter
        guard micPreview else {
            meter.level = 0
            meter.rms = 0
            meter.clipping = false
            syncMic()
            return
        }
        syncMic()
        if let raw = mic.read(), raw.count >= 2 {
            let gained = micGainDb != 0 ? PCM.applyGain(raw, gainDb: micGainDb) : raw
            applyMeter(PCM.analyze(gained))
        } else {
            meter.level *= 0.6
            meter.rms *= 0.6
            meter.clipping = false
        }
    }

    // MARK: - Wheel

    public func wheel(_ direction: Int, step: Int = 1) {
        let magnitude = max(1, abs(step))
        let delta = (direction < 0 ? -1 : 1) * magnitude
        let type: EventType = delta > 0 ? .wheelCW : .wheelCCW

        if recordingNow {
            log.emit(clock.nowMs, .wheelIgnored, [
                "direction": .int(delta),
                "activity": .string(activity.rawValue),
            ])
            return
        }

        // quiet: false, so hitting the end of the archive is audible instead of
        // being an invisible no-op.
        let cue = moveCue(delta, forcePlay: cfg.wheelAutoplay, quiet: false, clamp: true)
        log.emit(clock.nowMs, type, [
            "direction": .int(delta > 0 ? 1 : -1),
            "step": .int(magnitude),
            "selected": cue.map { JSONValue.string($0.recordingId) } ?? .null,
            "cue": cue.map { JSONValue.string($0.kind.rawValue) } ?? .null,
            "sampleOffset": cue.map { JSONValue.int($0.sampleOffset) } ?? .null,
            "cueIndex": .int(cueIndex),
        ])
        syncLed()
    }

    public func wheelClick() {
        log.emit(clock.nowMs, .wheelClick, [:])
        if recordingNow { return }

        if let pb = playback, playingNow {
            var next = pb
            next.playing.toggle()
            playback = next
            activity = next.playing ? .playing : .paused
            if next.playing {
                sink.setVolume(volume)
                sink.resume()
            } else {
                sink.pause()
            }
            log.emit(clock.nowMs, next.playing ? .playbackResumed : .playbackPaused, [
                "id": .string(next.recordingId),
                "positionSamples": .int(next.positionSamples),
            ])
            syncLed()
            return
        }

        guard let cue = currentCue() else { return }
        startPlayback(cue.recordingId, atSample: cue.sampleOffset)
        syncLed()
    }

    // MARK: - Playback

    private func recordingMeta(_ id: String) -> RecordingMeta? {
        recordings().first { $0.id == id }
    }

    private func fileURL(for meta: RecordingMeta) -> URL {
        library?.recordingURL(meta.id, ext: "wav") ?? URL(fileURLWithPath: "/dev/null")
    }

    @discardableResult
    public func startPlayback(_ recordingId: String, atSample: Int = 0) -> PlaybackState? {
        guard let meta = recordingMeta(recordingId) else { return nil }
        let position = max(0, min(atSample, meta.durationSamples))
        playback = PlaybackState(
            recordingId: recordingId,
            positionSamples: position,
            durationSamples: meta.durationSamples,
            playing: true
        )
        activity = .playing
        sink.setVolume(volume)
        sink.play(url: fileURL(for: meta), atSample: position)
        log.emit(clock.nowMs, .playbackStarted, [
            "id": .string(recordingId),
            "positionSamples": .int(position),
            "durationSamples": .int(meta.durationSamples),
        ])
        syncLed()
        return playback
    }

    private func stopPlayback(_ reason: String) {
        guard let pb = playback else { return }
        sink.stop()
        log.emit(clock.nowMs, .playbackStopped, [
            "id": .string(pb.recordingId),
            "positionSamples": .int(pb.positionSamples),
            "reason": .string(reason),
        ])
        playback = nil
        refreshActivity()
        syncLed()
    }

    private func updatePlayback(_ dtMs: Double) {
        guard var pb = playback, pb.playing else { return }
        pb.positionSamples += Int(dtMs * Double(cfg.sampleRate) / 1000)
        if pb.positionSamples >= pb.durationSamples {
            pb.positionSamples = pb.durationSamples
            playback = pb
            stopPlayback("end")
            return
        }
        playback = pb
    }

    private func refreshActivity() {
        if recordingNow { activity = .recording; return }
        if let pb = playback {
            activity = pb.playing ? .playing : .paused
            return
        }
        if error != nil { activity = .error; return }
        if activity == .recording || activity == .playing || activity == .paused {
            activity = .browsing
        }
    }

    // MARK: - Feedback

    private func feedback(_ pattern: Feedback) {
        lastFeedback = pattern
    }

    private func negativeFeedback(_ reason: String) {
        feedback(Feedback(kind: .negative, pulses: [120], reason: reason, atMs: clock.nowMs))
        log.emit(clock.nowMs, .markerNegative, ["reason": .string(reason)])
    }

    // MARK: - Fault injection

    /// Simulated unexpected power loss: no time to finalize. The partial WAV
    /// stays on disk for `recover()` to finish. Also used by tests.
    public func powerLoss() {
        if let rec = recording {
            rec.wav.abandon()
            recording = nil
        }
        log.emit(clock.nowMs, .powerLoss, [:])
        playback = nil
        sink.stop()
        mic.stop()
        error = nil
        activity = .idle
        recSwitch = false
        syncLed()
    }

    // MARK: - Tick

    public func tick(_ dtMs: Double) {
        guard dtMs > 0 else { return }
        syncLed()
        if recordingNow { updateRecording() }
        updateMic()
        updatePlayback(dtMs)
    }

    // MARK: - Queries

    public func recordings() -> [RecordingMeta] {
        guard let library else { return [] }
        return library.listRecordings().filter { $0.status == "finalized" }
    }

    public func selectedRecording() -> RecordingMeta? {
        guard let cue = currentCue() else { return nil }
        return recordings().first { $0.id == cue.recordingId }
    }

    /// Move the cursor without auditioning (used to restore a remembered
    /// position, and by the host's menu).
    public func selectCueIndex(_ index: Int, flash: Bool = false) {
        let count = cues().count
        guard count > 0 else { return }
        let next = max(0, min(index, count - 1))
        guard next != cueIndex else { return }
        cueIndex = next
        if flash { flashLed(.cyan, "cue") }
        syncLed()
    }

    /// Index of a recording's start cue, or nil when it has no cues yet.
    public func cueIndexForRecordingStart(_ recordingId: String) -> Int? {
        cues().firstIndex { $0.recordingId == recordingId && $0.kind == .start }
    }

    private func clampSelection() {
        let n = cues().count
        cueIndex = n > 0 ? max(0, min(cueIndex, n - 1)) : 0
    }

    public func snapshot() -> Snapshot {
        let list = recordings()
        let totalDurationSamples = list.reduce(0) { $0 + $1.durationSamples }
        let totalMarkerCount = list.reduce(0) { $0 + $1.markers.count }
        let cue = currentCue()

        return Snapshot(
            nowMs: clock.nowMs,
            activity: activity,
            recSwitch: recSwitch,
            error: error,
            led: ledState(),
            mic: MicSnapshot(
                gainDb: micGainDb,
                preview: micPreview,
                level: meter.level,
                rms: meter.rms,
                peakHold: meter.peakHold,
                clipping: meter.clipping
            ),
            volume: volume,
            library: LibrarySnapshot(
                present: library != nil,
                id: library?.libraryId,
                path: library?.root.path,
                usedBytes: library?.totalBytes() ?? 0
            ),
            recordings: list,
            cueIndex: cueIndex,
            cueCount: cues().count,
            cue: cue,
            recording: recording.map {
                ActiveRecordingSnapshot(id: $0.id, samples: $0.samples, markers: $0.markers, level: $0.peak)
            },
            playback: playback.map {
                PlaybackSnapshot(
                    id: $0.recordingId,
                    positionSamples: $0.positionSamples,
                    durationSamples: $0.durationSamples,
                    playing: $0.playing,
                    positionMs: Double($0.positionSamples) / Double(cfg.sampleRate) * 1000,
                    durationMs: Double($0.durationSamples) / Double(cfg.sampleRate) * 1000
                )
            },
            stats: Stats(
                recordings: list.count,
                totalDurationMs: Double(totalDurationSamples) / Double(cfg.sampleRate) * 1000,
                totalMarkers: totalMarkerCount,
                totalRecordedMs: Double(totalRecordedSamples) / Double(cfg.sampleRate) * 1000,
                rejected: rejected
            ),
            feedback: lastFeedback,
            events: log.tail(12)
        )
    }
}
