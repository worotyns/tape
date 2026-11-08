import AVFoundation
import Foundation
import TabulaCore

/// Real microphone capture, downsampled to the device's 16 kHz mono s16le.
///
/// `AVAudioEngine`'s tap hands us whatever the hardware is running at (often
/// 48 kHz float32 stereo), so an `AVAudioConverter` does the format change. The
/// input format can change under us — plugging in AirPods, switching devices —
/// hence the configuration-change notification and the converter cache keyed on
/// the incoming format.
final class MicCapture: MicSource {
    private let engine = AVAudioEngine()
    private let target: AVAudioFormat
    private let lock = NSLock()

    private var pending = Data()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var tapInstalled = false
    private var observing = false

    private(set) var isRunning = false

    /// Hard cap on the backlog, so a stalled consumer can never grow unbounded.
    private let maxPendingBytes = 16000 * 2 * 60

    init(sampleRate: Double = 16000) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("could not construct the 16 kHz mono target format")
        }
        target = format
    }

    /// TCC: without `NSMicrophoneUsageDescription` in the bundle's Info.plist
    /// the process is denied with no prompt at all.
    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static var permissionDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(
                domain: "Tabula",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no audio input device available"]
            )
        }
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.handle(buffer)
            }
            tapInstalled = true
        }
        if !observing {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(configurationChanged),
                name: .AVAudioEngineConfigurationChange,
                object: engine
            )
            observing = true
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isRunning = false
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    func read() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }

    /// The hardware format changed: drop the cached converter so the next buffer
    /// rebuilds it, and restart the engine if we were running.
    @objc private func configurationChanged(_ note: Notification) {
        converter = nil
        converterInputFormat = nil
        if isRunning {
            engine.stop()
            try? engine.start()
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let source = buffer.format
        let avConverter: AVAudioConverter
        if let cached = converter, let cachedFormat = converterInputFormat, cachedFormat.isEqual(source) {
            avConverter = cached
        } else if let fresh = AVAudioConverter(from: source, to: target) {
            converter = fresh
            converterInputFormat = source
            avConverter = fresh
        } else {
            return
        }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var provided = false
        var conversionError: NSError?
        avConverter.convert(to: out, error: &conversionError) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, out.frameLength > 0, let channels = out.int16ChannelData else {
            return
        }

        let data = Data(bytes: channels[0], count: Int(out.frameLength) * 2)
        lock.lock()
        pending.append(data)
        if pending.count > maxPendingBytes {
            pending.removeFirst(pending.count - maxPendingBytes)
        }
        lock.unlock()
    }
}
