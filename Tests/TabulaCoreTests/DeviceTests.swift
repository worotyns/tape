import XCTest
@testable import TabulaCore

/// A mic that cannot start, to exercise the rejection path.
final class FailingMic: MicSource {
    var isRunning = false
    func start() throws { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input device"]) }
    func stop() {}
    func read() -> Data? { nil }
}

/// Scenarios ported from the simulator's device.test.js, minus everything that
/// only made sense with hardware (card quota, battery, deep sleep, Opus).
final class DeviceTests: XCTestCase {

    // MARK: - Harness

    final class Harness {
        let dir: URL
        let library: Library?
        let clock: SimClock
        let log: EventLog
        let mic: SyntheticMic
        let sink: NullAudioSink
        let device: Device

        init(config: Config = Config(), withLibrary: Bool = true, failingMic: Bool = false) throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tabula-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            library = withLibrary ? try Library.create(at: dir, id: "test-library") : nil
            clock = SimClock()
            log = EventLog()
            mic = SyntheticMic(clock: clock)
            sink = NullAudioSink()
            let source: MicSource = failingMic ? FailingMic() : mic
            device = Device(
                clock: clock,
                log: log,
                library: library,
                mic: source,
                sink: sink,
                config: config
            )
            device.boot()
        }

        func tick(ms: Double, step: Double = 50) {
            var left = ms
            while left > 0 {
                let dt = min(step, left)
                clock.advance(dt)
                device.tick(dt)
                left -= dt
            }
        }

        func record(_ seconds: Double) {
            device.setRec(true)
            tick(ms: seconds * 1000)
            device.setRec(false)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private var harnesses: [Harness] = []

    private func harness(
        config: Config = Config(),
        withLibrary: Bool = true,
        failingMic: Bool = false
    ) throws -> Harness {
        let h = try Harness(config: config, withLibrary: withLibrary, failingMic: failingMic)
        harnesses.append(h)
        return h
    }

    override func tearDown() {
        harnesses.forEach { $0.cleanup() }
        harnesses.removeAll()
        super.tearDown()
    }

    private let rate = 16000

    // MARK: - Recording

    func testRecOffFinalizesRecording() throws {
        let h = try harness()
        h.device.setRec(true)
        h.tick(ms: 2000)
        h.device.setRec(false)

        XCTAssertNil(h.device.recording)
        XCTAssertEqual(h.device.activity, .idle)

        let recs = try XCTUnwrap(h.library).listRecordings()
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].status, "finalized")
        XCTAssertEqual(recs[0].durationSamples, rate * 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(h.library).recordingURL(recs[0].id, ext: "wav").path
            )
        )
    }

    func testMEMCreatesSampleAccurateMarkers() throws {
        let h = try harness()
        h.device.setRec(true)
        h.tick(ms: 4000)
        let m1 = try XCTUnwrap(h.device.memPress())
        h.tick(ms: 2000)
        let m2 = try XCTUnwrap(h.device.memPress())
        h.device.setRec(false)

        XCTAssertEqual(m1.sampleOffset, rate * 4)
        XCTAssertEqual(m2.sampleOffset, rate * 6)

        let rec = try XCTUnwrap(h.library).listRecordings()[0]
        XCTAssertEqual(rec.markers.count, 2)
        XCTAssertEqual(rec.markers[1].sampleOffset, rate * 6)
    }

    func testMEMOnlyMarksWhileRecording() throws {
        let h = try harness()
        h.device.setRec(true)
        h.tick(ms: 3000)
        h.device.memPress() // marker @ 48000
        h.tick(ms: 3000)
        h.device.memPress() // marker @ 96000
        h.tick(ms: 3000)
        h.device.setRec(false)

        XCTAssertEqual(h.device.cues().count, 3) // start + 2 markers

        // Outside recording MEM does not add markers; it rewinds.
        XCTAssertNil(h.device.memPress())
        XCTAssertEqual(h.device.recordings().first?.markers.count, 2)
    }

    // MARK: - Cue navigation

    func testWheelAuditionsCuesAndClickTogglesInPlace() throws {
        let h = try harness()
        h.device.setRec(true)
        h.tick(ms: 3000)
        h.device.memPress()
        h.tick(ms: 3000)
        h.device.memPress()
        h.tick(ms: 3000)
        h.device.setRec(false)

        // cues: start(0), marker1(48000), marker2(96000)
        XCTAssertEqual(h.device.cues().count, 3)

        h.device.wheel(1) // -> marker1, autoplayed
        XCTAssertEqual(h.device.currentCue()?.sampleOffset, rate * 3)
        XCTAssertEqual(h.device.activity, .playing)
        XCTAssertEqual(h.device.playback?.positionSamples, rate * 3)

        // wheel click toggles pause/play in place (no jump back to the cue)
        h.device.wheelClick()
        XCTAssertEqual(h.device.activity, .paused)
        XCTAssertEqual(h.device.playback?.positionSamples, rate * 3)
        h.device.wheelClick()
        XCTAssertEqual(h.device.activity, .playing)
        XCTAssertTrue(h.sink.calls.contains("resume"))

        h.device.wheel(-1)
        XCTAssertEqual(h.device.currentCue()?.sampleOffset, 0)
        XCTAssertEqual(h.device.playback?.positionSamples, 0)
    }

    func testFinalizeParksTheCursorOnTheNewRecording() throws {
        let h = try harness()
        h.record(1)
        // Like a tape recorder: after recording, the head is on what you just made.
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000001")

        h.record(1)
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000002",
                       "a new recording must not leave the cursor on an old clip")

        h.record(1)
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000003")
        XCTAssertEqual(h.device.cueIndex, h.device.cues().count - 1)
    }

    func testWheelWalksCuesInBothDirections() throws {
        let h = try harness()
        h.record(1)
        h.record(1)
        h.record(1)
        XCTAssertEqual(h.device.recordings().count, 3)
        XCTAssertEqual(h.device.cues().count, 3) // one cue per recording

        // The cursor starts parked on the last recording.
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000003")
        h.device.wheel(1) // clamped at the end
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000003")

        h.device.wheel(-1)
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000002")
        h.device.wheel(-1)
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000001")
        h.device.wheel(-1) // clamped at the start
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000001")

        h.device.wheel(1, step: 10)
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000003")
        h.device.jumpTo(.start)
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000001")
        h.device.jumpTo(.end)
        XCTAssertEqual(h.device.selectedRecording()?.id, "rec_000003")
    }

    func testWalkingBackwardsThroughMarkers() throws {
        let h = try harness()
        h.record(1)                       // rec_000001: start only
        h.device.setRec(true)
        h.tick(ms: 2000)
        h.device.memPress()               // @ 32000
        h.tick(ms: 2000)
        h.device.memPress()               // @ 64000
        h.tick(ms: 2000)
        h.device.setRec(false)            // rec_000002

        // cues: 0 rec1 start, 1 rec2 start, 2 rec2 marker1, 3 rec2 marker2
        XCTAssertEqual(h.device.cues().map(\.sampleOffset), [0, 0, 32000, 64000])
        // The cursor is parked on the recording that was just made.
        XCTAssertEqual(h.device.cueIndex, 1)
        XCTAssertEqual(h.device.currentCue()?.recordingId, "rec_000002")

        // Forward to each marker, then all the way back, checking every step.
        h.device.wheel(1)
        XCTAssertEqual(h.device.currentCue()?.sampleOffset, 32000)
        XCTAssertEqual(h.device.playback?.positionSamples, 32000)
        h.device.wheel(1)
        XCTAssertEqual(h.device.currentCue()?.sampleOffset, 64000)

        h.device.wheel(-1)
        XCTAssertEqual(h.device.currentCue()?.sampleOffset, 32000)
        h.device.wheel(-1)
        XCTAssertEqual(h.device.currentCue()?.markerId, nil)
        XCTAssertEqual(h.device.currentCue()?.kind, Cue.Kind.start)
        XCTAssertEqual(h.device.currentCue()?.recordingId, "rec_000002")
        h.device.wheel(-1)
        XCTAssertEqual(h.device.currentCue()?.recordingId, "rec_000001")
        h.device.wheel(-1) // the wall
        XCTAssertEqual(h.device.currentCue()?.recordingId, "rec_000001")
    }

    func testHittingTheEndOfTheArchiveIsAudible() throws {
        let h = try harness()
        h.record(1)

        // At the only cue, walking forward cannot move.
        h.device.wheel(1)
        XCTAssertEqual(h.device.lastFeedback?.kind, .negative)
        XCTAssertEqual(h.device.lastFeedback?.reason, "end_of_archive")

        h.device.wheel(-1)
        XCTAssertEqual(h.device.lastFeedback?.reason, "start_of_archive",
                       "a silent wall is indistinguishable from broken navigation")
    }

    func testHeldKeyAtTheWallDoesNotMachineGunFeedback() throws {
        let h = try harness()
        h.record(1)

        h.device.wheel(1) // the wall, first blip
        let first = try XCTUnwrap(h.device.lastFeedback)
        XCTAssertEqual(first.reason, "end_of_archive")

        // Auto-repeat: 20 presses over 400 ms must not produce 20 blips.
        for _ in 0..<20 {
            h.clock.advance(20)
            h.device.wheel(1)
        }
        XCTAssertEqual(h.device.lastFeedback?.atMs, first.atMs,
                       "a held key must not re-fire the edge blip")

        // ...but after a pause it speaks again.
        h.clock.advance(h.device.cfg.edgeFeedbackMs + 1)
        h.device.wheel(1)
        XCTAssertGreaterThan(try XCTUnwrap(h.device.lastFeedback?.atMs), first.atMs)
    }

    func testSelectCueIndexClampsAndDoesNotAudition() throws {
        let h = try harness()
        h.record(1)
        h.record(1)

        h.device.selectCueIndex(1)
        XCTAssertEqual(h.device.cueIndex, 1)
        XCTAssertNil(h.device.playback, "restoring a position must not start playing")

        h.device.selectCueIndex(99)
        XCTAssertEqual(h.device.cueIndex, 1)
        h.device.selectCueIndex(-5)
        XCTAssertEqual(h.device.cueIndex, 0)
    }

    func testScrubSeeksWithinRecordingAndAuditions() throws {
        let h = try harness()
        h.record(30)
        let id = try XCTUnwrap(h.library).listRecordings()[0].id

        h.device.seekBy(5)
        XCTAssertEqual(h.device.activity, .playing)
        XCTAssertEqual(h.device.playback?.positionSamples, rate * 5)

        h.device.seekBy(5)
        XCTAssertEqual(h.device.playback?.positionSamples, rate * 10)

        h.device.seekBy(-5)
        XCTAssertEqual(h.device.playback?.positionSamples, rate * 5)

        h.device.seekBy(-1000) // clamp at the beginning
        XCTAssertEqual(h.device.playback?.positionSamples, 0)

        h.device.seekBy(1000) // clamp at the end
        XCTAssertEqual(h.device.playback?.positionSamples, rate * 30)
        XCTAssertEqual(h.device.playback?.recordingId, id)
    }

    // MARK: - MEM as tape rewind

    func testMEMRewindsTwoAndAHalfSecondsOutsideRecording() throws {
        let h = try harness()
        h.record(30)

        h.device.wheelClick() // audition from the first cue
        h.device.seekBy(10)
        XCTAssertEqual(h.device.playback?.positionSamples, rate * 10)

        let marker = h.device.memPress() // rewind, not a marker
        XCTAssertNil(marker)
        XCTAssertEqual(h.device.playback?.positionSamples, rate * 10 - Int(h.device.cfg.memRewindSeconds * 16000))
        XCTAssertEqual(h.device.activity, .playing)
        XCTAssertTrue(h.log.events.contains { $0.type == .memRewind })
    }

    func testMEMRewindClampsAtTheStart() throws {
        let h = try harness()
        h.record(30)

        h.device.seekBy(1) // 1s in, less than the rewind distance
        XCTAssertEqual(h.device.playback?.positionSamples, rate * 1)

        h.device.memPress()
        XCTAssertEqual(h.device.playback?.positionSamples, 0)
    }

    // MARK: - Playback

    func testPlaybackStopsAtEndOfRecording() throws {
        let h = try harness()
        h.record(2)
        h.device.wheelClick()
        XCTAssertEqual(h.device.activity, .playing)

        h.tick(ms: 5000)
        XCTAssertNil(h.device.playback)
        XCTAssertEqual(h.device.activity, .browsing)
    }

    func testRecordingTakesPriorityOverPlayback() throws {
        let h = try harness()
        h.record(30)
        h.device.wheelClick()
        XCTAssertEqual(h.device.activity, .playing)

        h.device.setRec(true)
        XCTAssertEqual(h.device.activity, .recording)
        XCTAssertNil(h.device.playback)
    }

    // MARK: - Failure paths

    func testMissingLibraryRejectsRecording() throws {
        let h = try harness(withLibrary: false)
        h.device.setRec(true)
        XCTAssertEqual(h.device.activity, .error)
        XCTAssertEqual(h.device.error?.reason, "no_library")
        XCTAssertNil(h.device.recording)
        XCTAssertEqual(h.device.ledState().mode, .blink)
    }

    func testMicFailureRejectsRecordingAndLeavesNoFile() throws {
        let h = try harness(failingMic: true)
        h.device.setRec(true)

        XCTAssertEqual(h.device.error?.reason, "mic_unavailable")
        XCTAssertNil(h.device.recording)
        XCTAssertEqual(try XCTUnwrap(h.library).listRecordings().count, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: try XCTUnwrap(h.library).recordingsDir.path
        )
        XCTAssertTrue(leftovers.isEmpty, "a rejected recording must leave nothing behind")
    }

    func testCorruptedMetadataIsQuarantined() throws {
        let h = try harness()
        h.record(1)
        let good = try XCTUnwrap(h.library).listRecordings()[0]

        try Data("{ not json".utf8).write(
            to: try XCTUnwrap(h.library).metadataDir.appendingPathComponent("rec_999999.json")
        )
        let list = try XCTUnwrap(h.library).listRecordings()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, good.id)
        XCTAssertEqual(try XCTUnwrap(h.library).takeQuarantineReports().count, 1)
    }

    func testMaxDurationRollsOverToANewRecording() throws {
        var config = Config()
        config.maxRecordingSeconds = 1
        let h = try harness(config: config)

        h.device.setRec(true)
        h.tick(ms: 2500)
        // Still recording: the guard rail rolls over instead of stopping.
        XCTAssertTrue(h.device.recSwitch)
        XCTAssertNotNil(h.device.recording)
        h.device.setRec(false)

        let recs = try XCTUnwrap(h.library).listRecordings()
        XCTAssertGreaterThanOrEqual(recs.count, 3)
        XCTAssertEqual(Set(recs.map(\.id)).count, recs.count, "ids must be unique")
    }

    // MARK: - Durability (the heart of the concept)

    func testUnexpectedPowerLossRecoversRecordedData() throws {
        let h = try harness()
        h.device.setRec(true)
        h.tick(ms: 5000)
        h.device.powerLoss()
        XCTAssertNil(h.device.recording)

        let reopened = try Library.open(at: h.dir)
        let recovered = reopened.recover()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].recovered, true)
        XCTAssertEqual(recovered[0].durationSamples, rate * 5)
        XCTAssertEqual(recovered[0].status, "finalized")

        let stats = Library.repairWav(reopened.recordingURL(recovered[0].id, ext: "wav"))
        XCTAssertEqual(stats.durationSamples, rate * 5)
    }

    func testMarkersSurvivePowerLoss() throws {
        let h = try harness()
        h.device.setRec(true)
        h.tick(ms: 2000)
        h.device.memPress() // marker @ 2 s
        h.tick(ms: 2000)
        h.device.memPress() // marker @ 4 s
        h.tick(ms: 2000)
        h.device.powerLoss()

        let reopened = try Library.open(at: h.dir)
        let recovered = reopened.recover()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].markers.map(\.sampleOffset), [rate * 2, rate * 4])
        XCTAssertEqual(recovered[0].durationSamples, rate * 6)

        // ...and the cues are usable again, not just present in metadata.
        let clock = SimClock()
        let device = Device(
            clock: clock,
            log: EventLog(),
            library: reopened,
            mic: SyntheticMic(clock: clock),
            sink: NullAudioSink()
        )
        device.boot()
        XCTAssertEqual(device.cues().map(\.sampleOffset), [0, rate * 2, rate * 4])
    }

    func testRecoveryDropsMarkersPastTheRepairedEnd() throws {
        let h = try harness()
        h.device.setRec(true)
        h.tick(ms: 2000)
        h.device.memPress()
        h.tick(ms: 2000)
        h.device.powerLoss()

        // Simulate the tail never reaching disk: truncate the file after the
        // first marker, then recover.
        let library = try XCTUnwrap(h.library)
        let id = library.listRecordings().isEmpty
            ? Library.recId(1)
            : library.listRecordings()[0].id
        let wav = library.recordingURL(id, ext: "wav")
        let handle = try FileHandle(forWritingTo: wav)
        try handle.truncate(atOffset: UInt64(WavStream.headerBytes + rate * 2 * 2))
        try handle.close()

        let reopened = try Library.open(at: h.dir)
        let recovered = reopened.recover()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].durationSamples, rate * 2)
        XCTAssertEqual(recovered[0].markers.map(\.sampleOffset), [rate * 2])
    }

    // MARK: - Exclusive archive access

    func testArchiveLockIsExclusive() throws {
        let h = try harness()
        let first = try XCTUnwrap(h.library)
        XCTAssertTrue(first.acquireLock())

        let second = try Library.open(at: h.dir)
        XCTAssertFalse(second.acquireLock(), "a second process must not get the archive")

        first.releaseLock()
        XCTAssertTrue(second.acquireLock(), "the lock must be released with the process")
        second.releaseLock()
    }

    /// Why the lock exists, demonstrated rather than asserted in prose: two
    /// writers that do not hold it hand out the *same* recording id.
    func testTwoUnlockedWritersCollideOnRecordingIDs() throws {
        let h = try harness()
        let a = try XCTUnwrap(h.library)
        let b = try Library.open(at: h.dir)
        XCTAssertEqual(try a.nextSeq(), 1)
        XCTAssertEqual(try b.nextSeq(), 1, "second writer reads a stale manifest and collides")

        // And the collision is destructive: opening the same path truncates.
        let url = a.recordingURL("rec_000001", ext: "wav")
        let first = try WavStream(url: url, sampleRate: 8000, channels: 1, bitsPerSample: 16)
        try first.append(Data(repeating: 0x7f, count: 2000))
        try first.finalize()
        let sizeAfterFirst = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        )

        let second = try WavStream(url: url, sampleRate: 8000, channels: 1, bitsPerSample: 16)
        try second.append(Data(repeating: 0x11, count: 200))
        try second.finalize()
        let sizeAfterSecond = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        )
        XCTAssertLessThan(sizeAfterSecond, sizeAfterFirst, "the first recording was destroyed")
    }

    func testRecoveryIsIdempotent() throws {
        let h = try harness()
        h.device.setRec(true)
        h.tick(ms: 3000)
        h.device.powerLoss()

        let reopened = try Library.open(at: h.dir)
        XCTAssertEqual(reopened.recover().count, 1)
        XCTAssertEqual(reopened.recover().count, 0, "a finalized recording must not be recovered twice")
        XCTAssertEqual(reopened.listRecordings().count, 1)
    }

    func testNoUserActionDeletesOrOverwritesAFinalizedRecording() throws {
        let h = try harness()
        h.record(2)
        let library = try XCTUnwrap(h.library)
        let first = library.listRecordings()[0]
        let file = library.recordingURL(first.id, ext: "wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Everything a user can reach, including MEM's new rewind behaviour.
        h.device.wheel(1)
        h.device.wheel(-1)
        h.device.wheelClick()
        h.device.memPress()
        h.device.memPress()
        h.device.wheelClick()
        h.device.jumpTo(.start)
        h.device.jumpTo(.end)
        h.device.recover()
        h.record(1)
        h.tick(ms: 2000)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "a finalized recording file must still exist"
        )
        let still = library.listRecordings().first { $0.id == first.id }
        XCTAssertNotNil(still)
        XCTAssertEqual(still?.durationSamples, first.durationSamples)
        XCTAssertEqual(library.listRecordings().count, 2)
        XCTAssertNotEqual(library.listRecordings()[1].id, first.id)
    }

    // MARK: - LED (the only display)

    func testLEDReflectsRecordingCueScrubAndError() throws {
        let h = try harness()
        XCTAssertEqual(h.device.ledState().mode, .off)

        h.device.setRec(true)
        XCTAssertEqual(h.device.ledState().color, .red)
        XCTAssertEqual(h.device.ledState().mode, .steady)
        h.tick(ms: 3000)
        h.device.memPress()
        h.device.setRec(false)

        XCTAssertEqual(h.device.ledState().mode, .off)

        h.device.wheel(1) // cue detent
        XCTAssertEqual(h.device.ledState().color, .cyan)
        XCTAssertEqual(h.device.ledState().mode, .flash)

        h.tick(ms: 10000) // flash expires
        h.device.seekBy(1)
        XCTAssertEqual(h.device.ledState().color, .magenta)
        XCTAssertEqual(h.device.ledState().mode, .flash)

        h.tick(ms: 10000)
        XCTAssertEqual(h.device.ledState().mode, .off)

        h.device.wheelClick()
        XCTAssertEqual(h.device.ledState().color, .green)
        XCTAssertEqual(h.device.ledState().mode, .steady)
    }

    // MARK: - Screenless position announcement

    func testAnnounceEncodesPositionAsPitch() throws {
        let h = try harness()
        h.record(1)
        h.record(1)
        h.record(1)

        h.device.jumpTo(.start)
        let first = try XCTUnwrap(h.device.announce())
        XCTAssertEqual(first.cueIndex, 0)
        XCTAssertEqual(first.cueCount, 3)
        XCTAssertEqual(first.semitones, -12, accuracy: 0.001)

        h.device.jumpTo(.end)
        let last = try XCTUnwrap(h.device.announce())
        XCTAssertEqual(last.semitones, 12, accuracy: 0.001)
    }
}
