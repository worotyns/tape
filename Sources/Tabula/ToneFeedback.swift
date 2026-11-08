import AVFoundation
import Foundation
import TabulaCore

/// Every audible signal the app makes. Since there is no window, sound is the
/// interface: marker confirmations, refusals, errors, and the screenless
/// "where am I" announcement whose pitch encodes the position in the archive.
final class ToneFeedback {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init() {
        // Render internally at 44.1 kHz stereo; the mixer converts to whatever
        // the output device actually runs at.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else {
            fatalError("could not construct the feedback render format")
        }
        self.format = format
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(_ feedback: Feedback) {
        let frequency: Double
        switch feedback.kind {
        case .ok: frequency = 880
        case .marker: frequency = 1320
        case .negative: frequency = 220
        case .error: frequency = 165
        }
        emit(pulses: feedback.pulses, frequency: frequency)
    }

    /// Pitch rises with the cue index, so "where am I in the archive" is
    /// audible without a screen. One blip for a recording start, two for a
    /// marker.
    func announce(_ info: Announcement) {
        let frequency = 440 * pow(2, info.semitones / 12)
        let pulses = info.kind == .start ? [90] : [70, 50, 70]
        emit(pulses: pulses, frequency: frequency)
    }

    private func emit(pulses: [Int], frequency: Double) {
        guard !pulses.isEmpty else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        guard let buffer = render(pulses: pulses, frequency: frequency) else { return }
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()
    }

    private func render(pulses: [Int], frequency: Double) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        // Alternating tone/silence, starting with a tone, plus a little tail.
        let frames = pulses.reduce(0) { $0 + Int(Double($1) / 1000 * sampleRate) } + 64
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channels = buffer.floatChannelData else { return nil }

        let channelCount = Int(format.channelCount)
        var frame = 0
        for (index, ms) in pulses.enumerated() {
            let count = Int(Double(ms) / 1000 * sampleRate)
            let isTone = index % 2 == 0
            for i in 0..<count where frame < frames {
                var value: Float = 0
                if isTone {
                    // Short attack and release, so blips do not click.
                    let attack = min(1, Double(i) / (sampleRate * 0.004))
                    let release = min(1, Double(count - i) / (sampleRate * 0.012))
                    let envelope = max(0, min(attack, release))
                    value = Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate) * 0.20 * envelope)
                }
                for channel in 0..<channelCount { channels[channel][frame] = value }
                frame += 1
            }
        }
        while frame < frames {
            for channel in 0..<channelCount { channels[channel][frame] = 0 }
            frame += 1
        }
        return buffer
    }
}
