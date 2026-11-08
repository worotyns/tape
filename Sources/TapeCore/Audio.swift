// PCM helpers, the streaming WAV writer and a deterministic synthetic mic.
//
// The WAV writer deliberately writes a placeholder header first and patches it
// on finalize, so a process killed mid-recording still leaves a repairable file.
// That property is the whole point of the archive and is what `Library.recover`
// relies on.

import Foundation

// MARK: - PCM

public struct PCMAnalysis: Sendable, Equatable {
    public var peak: Double
    public var rms: Double
    public var clipping: Bool

    public init(peak: Double, rms: Double, clipping: Bool) {
        self.peak = peak
        self.rms = rms
        self.clipping = clipping
    }
}

public enum PCM {
    public static func dbToGain(_ db: Double) -> Double {
        pow(10, db / 20)
    }

    public static func analyze(_ data: Data) -> PCMAnalysis {
        var peak = 0.0
        var sumSq = 0.0
        var count = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            count = raw.count / 2
            guard count > 0 else { return }
            for i in 0..<count {
                let u = UInt16(raw[i * 2]) | (UInt16(raw[i * 2 + 1]) << 8)
                let s = Double(Int16(bitPattern: u)) / 32768.0
                let a = abs(s)
                if a > peak { peak = a }
                sumSq += s * s
            }
        }
        guard count > 0 else {
            return PCMAnalysis(peak: 0, rms: 0, clipping: false)
        }
        return PCMAnalysis(
            peak: peak,
            rms: (sumSq / Double(count)).squareRoot(),
            clipping: peak >= 0.999
        )
    }

    public static func peak(_ data: Data) -> Double {
        analyze(data).peak
    }

    /// Gain in dB applied in software, clamped to int16 so clipping is visible.
    public static func applyGain(_ data: Data, gainDb: Double) -> Data {
        guard gainDb != 0 else { return data }
        let gain = dbToGain(gainDb)
        let usable = data.count - (data.count % 2)
        guard usable > 0 else { return Data() }
        var out = Data(count: usable)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                for i in stride(from: 0, to: usable, by: 2) {
                    let u = UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)
                    let s = Double(Int16(bitPattern: u)) * gain
                    let clamped = Int16(max(-32768, min(32767, s.rounded())))
                    let bits = UInt16(bitPattern: clamped)
                    dst[i] = UInt8(bits & 0xFF)
                    dst[i + 1] = UInt8(bits >> 8)
                }
            }
        }
        return out
    }
}

// MARK: - Streaming WAV writer

public final class WavStream {
    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let blockAlign: Int

    private var handle: FileHandle?
    private var dataBytes: Int = 0
    private var closed = false

    public static let headerBytes = 44

    public init(
        url: URL,
        sampleRate: Int = 16000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.blockAlign = channels * bitsPerSample / 8

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        self.handle = h
        // Placeholder header; patched by finalize().
        try h.write(contentsOf: WavStream.header(
            dataBytes: 0,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        ))
    }

    public var durationSamples: Int {
        blockAlign > 0 ? dataBytes / blockAlign : 0
    }

    public var sizeBytes: Int {
        WavStream.headerBytes + dataBytes
    }

    public func append(_ data: Data) throws {
        guard !closed, let handle else { throw WavError.closed }
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        dataBytes += data.count
    }

    /// Force the buffered bytes onto the platter (stronger than fsync).
    public func sync() {
        guard let fd = handle?.fileDescriptor else { return }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    @discardableResult
    public func finalize() throws -> Int {
        guard !closed else { return sizeBytes }
        guard let handle else { return sizeBytes }
        let header = WavStream.header(
            dataBytes: dataBytes,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        sync()
        try? handle.close()
        closed = true
        self.handle = nil
        return sizeBytes
    }

    /// Leave the partial file on disk for recovery (simulated power loss).
    public func abandon() {
        guard !closed else { return }
        try? handle?.close()
        closed = true
        self.handle = nil
    }

    static func header(
        dataBytes: Int,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> Data {
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        var b = Data(count: headerBytes)
        func u32(_ v: Int, _ at: Int) {
            let x = UInt32(truncatingIfNeeded: v)
            b[at] = UInt8(x & 0xFF)
            b[at + 1] = UInt8((x >> 8) & 0xFF)
            b[at + 2] = UInt8((x >> 16) & 0xFF)
            b[at + 3] = UInt8((x >> 24) & 0xFF)
        }
        func u16(_ v: Int, _ at: Int) {
            let x = UInt16(truncatingIfNeeded: v)
            b[at] = UInt8(x & 0xFF)
            b[at + 1] = UInt8((x >> 8) & 0xFF)
        }
        func ascii(_ s: String, _ at: Int) {
            for (i, byte) in Array(s.utf8).enumerated() { b[at + i] = byte }
        }
        ascii("RIFF", 0)
        u32(36 + dataBytes, 4)
        ascii("WAVE", 8)
        ascii("fmt ", 12)
        u32(16, 16)
        u16(1, 20) // PCM
        u16(channels, 22)
        u32(sampleRate, 24)
        u32(byteRate, 28)
        u16(blockAlign, 32)
        u16(bitsPerSample, 34)
        ascii("data", 36)
        u32(dataBytes, 40)
        return b
    }
}

public enum WavError: Error {
    case closed
}

// MARK: - Synthetic signal (deterministic, for tests and headless runs)

public struct SynthState: Sendable {
    public var sampleCount: Int = 0
    public var prev: Double = 0
    public var freq: Double = 0
    public var phase: Double = 0
    public var rng: UInt32 = 1

    public init() {}
}

public enum Synth {
    public static func render(
        samples: Int,
        seed: UInt32,
        amplitude: Double,
        state: inout SynthState,
        sampleRate: Double = 16000
    ) -> Data {
        guard samples > 0 else { return Data() }
        if state.freq == 0 {
            state.freq = 165 + Double(seed % 7) * 42
            state.phase = Double((seed >> 3) % 100) / 100 * Double.pi * 2
        }
        if state.rng == 1 { state.rng = seed == 0 ? 1 : seed }

        var out = Data(count: samples * 2)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            for i in 0..<samples {
                let t = Double(state.sampleCount + i) / sampleRate
                let tone = sin(2 * Double.pi * state.freq * t) * 0.5
                    + sin(2 * Double.pi * state.freq * 1.5 * t + state.phase) * 0.25
                let trem = 0.65 + 0.35 * sin(2 * Double.pi * 0.4 * t)
                state.rng = state.rng &* 1664525 &+ 1013904223
                let white = Double(state.rng) / 4294967296.0 * 2 - 1
                state.prev = state.prev * 0.9 + white * 0.1
                let v = (tone * trem * 0.35 + state.prev * 0.4) * amplitude
                let s = Int16(max(-32768, min(32767, (v * 32767).rounded())))
                let bits = UInt16(bitPattern: s)
                dst[i * 2] = UInt8(bits & 0xFF)
                dst[i * 2 + 1] = UInt8(bits >> 8)
            }
        }
        state.sampleCount += samples
        return out
    }
}
