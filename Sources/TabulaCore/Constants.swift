// Tabula domain constants and configuration.
//
// Ported from the JS simulator with the *hardware* parts removed: no battery,
// no card quota, no deep sleep, no deferred Opus compression. What remains is
// the part that is actually the product: capture that never loses data,
// navigation by cue points instead of files, and an immutable archive.

import Foundation

// MARK: - Activity

public enum Activity: String, Codable, Sendable {
    case idle = "IDLE"
    case recording = "RECORDING"
    case browsing = "BROWSING"
    case playing = "PLAYING"
    case paused = "PAUSED"
    case error = "ERROR"
}

// MARK: - Status LED
//
// The menu bar icon *is* the display: red = recording, green = playback,
// cyan flash = cue detent, magenta flash = fine scrub, red blink = error.

public enum LedColor: String, Codable, Sendable {
    case red, green, cyan, magenta
}

public enum LedMode: String, Codable, Sendable {
    case off, steady, flash, blink
}

public struct LedState: Codable, Sendable, Equatable {
    public var color: LedColor?
    public var mode: LedMode
    public var reason: String?

    public init(color: LedColor?, mode: LedMode, reason: String?) {
        self.color = color
        self.mode = mode
        self.reason = reason
    }

    public static let off = LedState(color: nil, mode: .off, reason: nil)
}

// MARK: - Events

public enum EventType: String, Codable, Sendable {
    case boot = "BOOT"
    case recOn = "REC_ON"
    case recOff = "REC_OFF"
    case recordingStarted = "RECORDING_STARTED"
    case recordingFinalized = "RECORDING_FINALIZED"
    case recordingRejected = "RECORDING_REJECTED"
    case markerAdded = "MARKER_ADDED"
    case markerNegative = "MARKER_NEGATIVE"
    case wheelCW = "WHEEL_CW"
    case wheelCCW = "WHEEL_CCW"
    case wheelClick = "WHEEL_CLICK"
    case wheelIgnored = "WHEEL_IGNORED"
    case memPress = "MEM_PRESS"
    case memRewind = "MEM_REWIND"
    case announce = "ANNOUNCE"
    case playbackStarted = "PLAYBACK_STARTED"
    case playbackPaused = "PLAYBACK_PAUSED"
    case playbackResumed = "PLAYBACK_RESUMED"
    case playbackStopped = "PLAYBACK_STOPPED"
    case playbackSeek = "PLAYBACK_SEEK"
    case scrub = "SCRUB"
    case micGain = "MIC_GAIN"
    case libraryOpened = "LIBRARY_OPENED"
    case libraryUnavailable = "LIBRARY_UNAVAILABLE"
    case ledChanged = "LED_CHANGED"
    case powerLoss = "POWER_LOSS"
    case recovery = "RECOVERY"
    case metadataQuarantined = "METADATA_QUARANTINED"
    case error = "ERROR"
}

/// A single JSON value, so the event log stays a faithful superset of the
/// simulator's `events.jsonl` (same archive, readable by both implementations).
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let v = try? c.decode(Bool.self) {
            self = .bool(v)
            return
        }
        if let v = try? c.decode(Int.self) {
            self = .int(v)
            return
        }
        if let v = try? c.decode(Double.self) {
            self = .double(v)
            return
        }
        if let v = try? c.decode(String.self) {
            self = .string(v)
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

public typealias EventData = [String: JSONValue]

// MARK: - Recording metadata (the archive format)

public struct Marker: Codable, Sendable, Equatable {
    public var id: Int
    public var sampleOffset: Int
    public var atSimMs: Double?

    public init(id: Int, sampleOffset: Int, atSimMs: Double? = nil) {
        self.id = id
        self.sampleOffset = sampleOffset
        self.atSimMs = atSimMs
    }
}

public struct RecordingMeta: Codable, Sendable, Equatable {
    public var id: String
    public var seq: Int
    public var format: String
    public var codec: String
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    public var durationSamples: Int
    public var sizeBytes: Int
    public var markers: [Marker]
    public var status: String
    public var createdAt: String?
    public var finalizedAt: String?
    public var finalizeReason: String?
    public var recovered: Bool?

    public init(
        id: String,
        seq: Int,
        format: String = "pcm",
        codec: String = "pcm_s16le",
        sampleRate: Int = 16000,
        channels: Int = 1,
        bitsPerSample: Int = 16,
        durationSamples: Int = 0,
        sizeBytes: Int = 44,
        markers: [Marker] = [],
        status: String = "finalized",
        createdAt: String? = nil,
        finalizedAt: String? = nil,
        finalizeReason: String? = nil,
        recovered: Bool? = nil
    ) {
        self.id = id
        self.seq = seq
        self.format = format
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.durationSamples = durationSamples
        self.sizeBytes = sizeBytes
        self.markers = markers
        self.status = status
        self.createdAt = createdAt
        self.finalizedAt = finalizedAt
        self.finalizeReason = finalizeReason
        self.recovered = recovered
    }

    enum CodingKeys: String, CodingKey {
        case id, seq, format, codec, sampleRate, channels, bitsPerSample
        case durationSamples, sizeBytes, markers, status
        case createdAt, finalizedAt, finalizeReason, recovered
    }

    // Tolerant decoding: metadata written by the JS simulator may omit fields,
    // and a missing field must never poison the archive.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        seq = (try? c.decode(Int.self, forKey: .seq)) ?? Library.parseRecSeq(id)
        format = (try? c.decode(String.self, forKey: .format)) ?? "pcm"
        codec = (try? c.decode(String.self, forKey: .codec)) ?? "pcm_s16le"
        sampleRate = (try? c.decode(Int.self, forKey: .sampleRate)) ?? 16000
        channels = (try? c.decode(Int.self, forKey: .channels)) ?? 1
        bitsPerSample = (try? c.decode(Int.self, forKey: .bitsPerSample)) ?? 16
        durationSamples = (try? c.decode(Int.self, forKey: .durationSamples)) ?? 0
        sizeBytes = (try? c.decode(Int.self, forKey: .sizeBytes)) ?? 44
        markers = (try? c.decode([Marker].self, forKey: .markers)) ?? []
        status = (try? c.decode(String.self, forKey: .status)) ?? "finalized"
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        finalizedAt = try? c.decodeIfPresent(String.self, forKey: .finalizedAt)
        finalizeReason = try? c.decodeIfPresent(String.self, forKey: .finalizeReason)
        recovered = try? c.decodeIfPresent(Bool.self, forKey: .recovered)
    }
}

// MARK: - Cues

/// A navigation point: the start of a recording, or a MEM marker.
public struct Cue: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case start, marker
    }

    public var recordingId: String
    public var kind: Kind
    public var sampleOffset: Int
    public var markerId: Int?
}

// MARK: - Feedback

public enum FeedbackKind: String, Sendable {
    case ok
    case marker
    case negative
    case error
}

/// A sound pattern the host should play. The device has no screen, so audio
/// feedback is the entire user interface.
public struct Feedback: Sendable, Equatable {
    public var kind: FeedbackKind
    /// Alternating tone/silence durations in milliseconds, starting with a tone.
    public var pulses: [Int]
    public var reason: String?
    public var atMs: Double
}

/// Screenless position announcement: pitch encodes the position in the archive.
public struct Announcement: Sendable, Equatable {
    public var cueIndex: Int
    public var cueCount: Int
    public var kind: Cue.Kind
    public var recordingId: String
    public var sampleOffset: Int

    public init(
        cueIndex: Int,
        cueCount: Int,
        kind: Cue.Kind,
        recordingId: String,
        sampleOffset: Int
    ) {
        self.cueIndex = cueIndex
        self.cueCount = cueCount
        self.kind = kind
        self.recordingId = recordingId
        self.sampleOffset = sampleOffset
    }

    /// -12..+12 semitones across the whole cue list, so "where am I" is audible:
    /// low = beginning of the archive, high = end.
    public static func semitones(cueIndex: Int, cueCount: Int) -> Double {
        guard cueCount > 1 else { return 0 }
        let t = Double(cueIndex) / Double(cueCount - 1)
        return -12 + 24 * t
    }

    public var semitones: Double {
        Announcement.semitones(cueIndex: cueIndex, cueCount: cueCount)
    }

    /// The pitch the host will actually play.
    public var frequency: Double {
        440 * pow(2, semitones / 12)
    }
}

// MARK: - Errors

public struct DeviceError: Codable, Sendable, Equatable {
    public var code: String
    public var reason: String
    public var detail: String?

    public init(code: String, reason: String, detail: String? = nil) {
        self.code = code
        self.reason = reason
        self.detail = detail
    }
}

// MARK: - Configuration

public struct Config: Sendable {
    // Audio
    public var sampleRate: Int = 16000
    public var channels: Int = 1
    public var bitsPerSample: Int = 16
    /// Guard rail; when hit, the device rolls over to a new immutable recording.
    public var maxRecordingSeconds: Int = 1800
    /// How often the in-flight recording is fsync'd to disk.
    public var syncIntervalMs: Double = 5000

    // Microphone
    public var micGainDb: Double = 0
    public var micGainStepDb: Double = 3
    public var micGainMinDb: Double = -24
    public var micGainMaxDb: Double = 24
    public var micPeakHoldMs: Double = 1500
    public var micPreview: Bool = false

    // Navigation
    public var wheelAutoplay: Bool = true
    public var scrubSeconds: Double = 5
    public var scrubSecondsCoarse: Double = 30
    public var scrubAutoplay: Bool = true
    public var ledFlashMs: Double = 250
    /// MEM outside recording is a tape rewind: jump back this far and audition.
    public var memRewindSeconds: Double = 2.5
    /// Minimum gap between two "end of archive" blips, so a held key does not
    /// machine-gun the same refusal.
    public var edgeFeedbackMs: Double = 700

    // Playback
    public var volume: Double = 1.0
    public var volumeCap: Double = 1.0

    public init() {}

    public var bytesPerSecond: Int {
        sampleRate * (bitsPerSample / 8) * channels
    }
}
