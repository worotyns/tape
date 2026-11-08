// Narrow, replaceable hardware boundaries. The domain never talks to CoreAudio,
// AppKit or the file system directly — only through these protocols, which is
// what keeps it testable and portable (the same shape as the simulator's HAL).

import Foundation

/// Microphone capture: 16 kHz mono signed 16-bit little-endian PCM.
public protocol MicSource: AnyObject {
    func start() throws
    func stop()
    /// Everything captured since the last call, or nil when nothing is pending.
    func read() -> Data?
    var isRunning: Bool { get }
}

/// Lets the domain make the synthetic mic sound distinct per recording.
public protocol SeededMicSource: MicSource {
    func setSeed(_ seed: UInt32)
}

/// Bone-conduction transducer stand-in: the Mac's normal audio output.
public protocol AudioSink: AnyObject {
    /// Start (or re-start) playback of `url` from a sample offset — the audit
    /// gesture: moving the cursor immediately plays what you landed on.
    func play(url: URL, atSample: Int)
    func pause()
    /// Continue where `pause` left off; no-op if nothing is loaded.
    func resume()
    func stop()
    func setVolume(_ v: Double)
}

// MARK: - Headless defaults

public final class NullMic: MicSource, SeededMicSource {
    public private(set) var isRunning = false
    public var pending: Data?

    public init() {}

    public func setSeed(_ seed: UInt32) {}

    public func start() throws { isRunning = true }
    public func stop() { isRunning = false }

    public func read() -> Data? {
        defer { pending = nil }
        return pending
    }
}

/// Deterministic mic driven by the injected clock: generates exactly as many
/// samples as the elapsed simulated time calls for. Used by tests and headless
/// runs so recording is fully reproducible.
public final class SyntheticMic: MicSource, SeededMicSource {
    private let clock: Clock
    private let sampleRate: Double
    private let amplitude: Double
    private var seed: UInt32
    private var produced = 0
    private var startMs: Double = 0
    private var state = SynthState()

    public private(set) var isRunning = false

    public init(
        clock: Clock,
        sampleRate: Double = 16000,
        amplitude: Double = 0.45,
        seed: UInt32 = 1
    ) {
        self.clock = clock
        self.sampleRate = sampleRate
        self.amplitude = amplitude
        self.seed = seed
    }

    public func setSeed(_ seed: UInt32) {
        self.seed = seed == 0 ? 1 : seed
    }

    public func start() throws {
        produced = 0
        startMs = clock.nowMs
        isRunning = true
    }

    public func stop() {
        isRunning = false
    }

    public func read() -> Data? {
        guard isRunning else { return nil }
        let elapsed = clock.nowMs - startMs
        let target = Int((elapsed * sampleRate / 1000).rounded(.down))
        let n = target - produced
        guard n > 0 else { return nil }
        produced = target
        return Synth.render(
            samples: n,
            seed: seed,
            amplitude: amplitude,
            state: &state,
            sampleRate: sampleRate
        )
    }
}

public final class NullAudioSink: AudioSink {
    public private(set) var calls: [String] = []
    public var lastURL: URL?
    public var lastSample: Int = 0
    public var volume: Double = 1

    public init() {}

    public func play(url: URL, atSample: Int) {
        calls.append("play")
        lastURL = url
        lastSample = atSample
    }

    public func pause() { calls.append("pause") }
    public func resume() { calls.append("resume") }
    public func stop() { calls.append("stop") }
    public func setVolume(_ v: Double) { volume = v }
}
