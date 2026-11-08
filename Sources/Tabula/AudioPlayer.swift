import AVFoundation
import Foundation
import TabulaCore

/// Playback through the Mac's normal output, standing in for the bone
/// conduction transducer. Sample-accurate seeking is the whole point: moving
/// the cursor must audition the fragment you landed on.
final class AudioPlayer: AudioSink {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    private var connectedFormat: AVAudioFormat?
    private var hasLoadedFile = false
    private var volume: Double = 1.0

    init() {
        engine.attach(node)
    }

    func play(url: URL, atSample: Int) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            log("cannot read \(url.lastPathComponent): \(error)")
            return
        }

        // Our recordings are always 16 kHz mono PCM, so this connects once.
        let format = file.processingFormat
        if connectedFormat == nil || !format.isEqual(connectedFormat!) {
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                log("audio engine could not start: \(error)")
                return
            }
        }

        node.stop()
        let total = file.length
        let start = max(0, min(Int64(atSample), total))
        let remaining = total - start
        guard remaining > 0 else {
            hasLoadedFile = false
            return
        }
        node.scheduleSegment(
            file,
            startingFrame: start,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionHandler: nil
        )
        node.volume = Float(volume)
        node.play()
        hasLoadedFile = true
    }

    /// Continue where `pause()` left off — no re-scheduling, so the position
    /// does not jump (this is what keeps wheel-click a true play/pause).
    func resume() {
        guard hasLoadedFile else { return }
        if !engine.isRunning { try? engine.start() }
        node.play()
    }

    func pause() {
        node.pause()
    }

    func stop() {
        node.stop()
        hasLoadedFile = false
    }

    func setVolume(_ v: Double) {
        volume = max(0, min(1, v))
        node.volume = Float(volume)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("tabula: \(message)\n".utf8))
    }
}
