import AVFoundation
import Foundation
import TabulaCore

/// Print what an archive actually contains, without the GUI — including whether
/// the microphone really captured sound rather than silence.
///
///     ./Tabula --inspect [folder]
///
/// Defaults to ~/Documents/TABULA.
enum Inspector {
    static func run(arguments: [String]) -> Int32 {
        let root: URL
        if let path = arguments.dropFirst().first, !path.hasPrefix("-") {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            root = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/TABULA", isDirectory: true)
        }

        guard let library = try? Library.open(at: root) else {
            print("cannot open archive at \(root.path)")
            return 1
        }

        let recordings = library.listRecordings()
        let events = library.readEvents()
        let formatter = ByteCountFormatter()

        print("archive:  \(root.path)")
        print("id:       \(library.libraryId)   next recording: \(Library.recId(library.manifest.nextSeq))")
        print("contents: \(recordings.count) recording(s), \(formatter.string(fromByteCount: Int64(library.totalBytes()))), \(events.count) events")
        print("")

        if recordings.isEmpty {
            print("no recordings yet — press ⌃⌥R and say something")
            return 0
        }

        for meta in recordings {
            let url = library.recordingURL(meta.id, ext: "wav")
            let seconds = Double(meta.durationSamples) / Double(meta.sampleRate)
            var note = meta.recovered == true ? "  (recovered after a kill)" : ""
            if let audio = analyse(url) {
                note += String(format: "   peak %.1f%%  rms %.2f%%  %@",
                               audio.peak * 100, audio.rms * 100,
                               audio.rms > 0.001 ? "real audio" : "SILENCE — microphone denied?")
            } else {
                note += "   unreadable by CoreAudio"
            }
            print(String(format: "%@  %@  ⚑%d  %@%@",
                         meta.id, format(seconds), meta.markers.count,
                         formatter.string(fromByteCount: Int64(meta.sizeBytes)), note))
            for marker in meta.markers.sorted(by: { $0.sampleOffset < $1.sampleOffset }) {
                let at = Double(marker.sampleOffset) / Double(meta.sampleRate)
                print("      ⚑\(marker.id) @ \(format(at))  (\(marker.sampleOffset) samples)")
            }
        }

        // The cue map: exactly what the wheel walks, in order. Pressing ⌃⌥↓
        // should visit these lines one by one, and ⌃⌥H should sound like the
        // last column.
        var cueList: [(recording: String, kind: Cue.Kind, marker: Int?, offset: Int, rate: Double)] = []
        for meta in recordings {
            let rate = Double(meta.sampleRate)
            cueList.append((meta.id, .start, nil, 0, rate))
            for marker in meta.markers.sorted(by: { $0.sampleOffset < $1.sampleOffset }) {
                cueList.append((meta.id, .marker, marker.id, marker.sampleOffset, rate))
            }
        }

        print("")
        print("cues — ⌃⌥↓ next, ⌃⌥↑ previous, ⌃⌥H announces:")
        for (index, cue) in cueList.enumerated() {
            let frequency = 440 * pow(2, Announcement.semitones(cueIndex: index, cueCount: cueList.count) / 12)
            let blips = cue.kind == .start ? "•" : "••"
            let what = cue.kind == .start ? "start" : "marker \(cue.marker ?? 0)"
            let at = format(Double(cue.offset) / cue.rate)
            print("  " + String(format: "%2d", index + 1) + "  "
                  + cue.recording.padding(toLength: 11, withPad: " ", startingAt: 0)
                  + what.padding(toLength: 9, withPad: " ", startingAt: 0)
                  + at.padding(toLength: 7, withPad: " ", startingAt: 0)
                  + "⌃⌥H: " + blips.padding(toLength: 3, withPad: " ", startingAt: 0)
                  + String(format: "%.0f Hz", frequency))
        }
        return 0
    }

    private struct Level {
        var peak: Double
        var rms: Double
    }

    /// Streamed, so a half-hour recording does not have to fit in memory.
    private static func analyse(_ url: URL) -> Level? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let chunk: AVAudioFrameCount = 16000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
            return nil
        }
        var peak = 0.0
        var sumSquares = 0.0
        var count = 0
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0,
                  let channels = buffer.floatChannelData else { break }
            for i in 0..<Int(buffer.frameLength) {
                let value = Double(channels[0][i])
                peak = max(peak, abs(value))
                sumSquares += value * value
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return Level(peak: peak, rms: (sumSquares / Double(count)).squareRoot())
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Headless end-to-end check of the real binary, without the menu bar, the
/// microphone or TCC. Useful for CI and for verifying that recovery of a
/// killed recording really works.
///
///     ./Tabula --selftest [folder]
enum SelfTest {
    static func run(arguments: [String]) -> Int32 {
        let root: URL
        if let path = arguments.dropFirst().first, !path.hasPrefix("-") {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tabula-selftest-\(UUID().uuidString)", isDirectory: true)
        }

        var failures: [String] = []
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "  ok  " : "FAIL  ")\(description)")
            if !condition { failures.append(description) }
        }

        do {
            let library = try Library.create(at: root, id: "selftest")
            let clock = SimClock()
            let log = EventLog()
            let mic = SyntheticMic(clock: clock)
            let sink = NullAudioSink()
            let device = Device(
                clock: clock,
                log: log,
                library: library,
                mic: mic,
                sink: sink,
                config: Config()
            )
            device.boot()

            // 2 s of audio, a marker, then 1 s more, then the power dies.
            device.setRec(true)
            tick(device, clock, ms: 2000)
            device.memPress()
            tick(device, clock, ms: 1000)
            device.powerLoss()

            let wavPath = library.recordingURL("rec_000001", ext: "wav").path
            check(FileManager.default.fileExists(atPath: wavPath), "partial WAV left on disk")

            // A fresh process would re-open the archive and recover.
            let reopened = try Library.open(at: root)
            let recovered = reopened.recover()
            check(recovered.count == 1, "recovery finalized exactly one recording")
            check(recovered.first?.durationSamples == 16000 * 3, "3 s of audio recovered")
            check(recovered.first?.markers.count == 1, "the marker survived the kill")
            check(recovered.first?.markers.first?.sampleOffset == 16000 * 2, "marker offset is exact")
            check(reopened.recover().isEmpty, "recovery is idempotent")

            let header = (try? Data(contentsOf: URL(fileURLWithPath: wavPath)))?.prefix(4)
            check(header.map { String(decoding: $0, as: UTF8.self) } == "RIFF", "WAV header repaired")

            // The playback path is CoreAudio reading this file. A hand-written
            // header on a byte plan CoreAudio disagrees with would be silent and
            // confusing, so verify it here rather than at 2 a.m.
            let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
            check(audioFile.fileFormat.sampleRate == 16000, "CoreAudio reads 16 kHz")
            check(audioFile.fileFormat.channelCount == 1, "CoreAudio reads mono")
            check(audioFile.length == 16000 * 3, "CoreAudio agrees on the length")
            if let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) {
                try audioFile.read(into: buffer)
                let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { partial, i in
                    guard let channels = buffer.floatChannelData else { return partial }
                    return max(partial, abs(channels[0][i]))
                }
                check(peak > 0.001, "the recording contains actual audio (peak \(String(format: "%.3f", peak)))")
            } else {
                check(false, "could not allocate a read buffer")
            }

            let events = reopened.readEvents()
            check(events.contains { $0.type == .recordingStarted }, "event journal written")
            check(events.contains { $0.type == .markerAdded }, "marker journaled")
            check(!events.contains { $0.type == .recordingFinalized && $0["recovered"] == nil },
                  "no false finalize recorded before the kill")

            // Cues must be rebuilt from the archive, not from memory.
            let replayClock = SimClock()
            let replay = Device(
                clock: replayClock,
                log: EventLog(),
                library: reopened,
                mic: SyntheticMic(clock: replayClock),
                sink: NullAudioSink()
            )
            replay.boot()
            check(replay.cues().count == 2, "cues rebuilt: recording start + marker")
            check(replay.cues().map(\.sampleOffset) == [0, 16000 * 2], "cue offsets rebuilt exactly")

            // And the rewind gesture works on the recovered recording.
            replay.wheelClick()
            replay.seekBy(3)
            replay.memPress()
            check(replay.playback?.positionSamples == 16000 * 3 - 40000,
                  "MEM rewinds 2.5 s on the recovered recording")
        } catch {
            print("FAIL  \(error)")
            failures.append(String(describing: error))
        }

        print("")
        print("archive: \(root.path)")
        if failures.isEmpty {
            print("selftest: all checks passed")
            try? FileManager.default.removeItem(at: root)
            return 0
        }
        print("selftest: \(failures.count) check(s) failed — archive left in place for inspection")
        return 1
    }

    private static func tick(_ device: Device, _ clock: SimClock, ms: Double, step: Double = 50) {
        var left = ms
        while left > 0 {
            let dt = min(step, left)
            clock.advance(dt)
            device.tick(dt)
            left -= dt
        }
    }
}
