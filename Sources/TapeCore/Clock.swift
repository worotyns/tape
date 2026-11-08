// Time is injected so the domain stays deterministic and testable: tests drive
// a SimClock by hand, the app uses the real wall clock.

import Foundation

public protocol Clock: AnyObject {
    var nowMs: Double { get }
    func advance(_ ms: Double)
    func iso(_ atMs: Double?) -> String
}

extension Clock {
    public func iso() -> String { iso(nil) }
}

/// Fixed-epoch deterministic clock, matching the JS simulator's SIM_EPOCH_MS.
public final class SimClock: Clock {
    /// 2024-01-01T00:00:00.000Z
    public static let simEpochMs: Double = 1_704_067_200_000

    private var now: Double

    public init(startMs: Double = SimClock.simEpochMs) {
        self.now = startMs
    }

    public var nowMs: Double { now }

    public func advance(_ ms: Double) {
        if ms > 0 { now += ms }
    }

    public func iso(_ atMs: Double? = nil) -> String {
        TapeClockFormat.iso(atMs ?? now)
    }
}

/// Wall clock for the real app. Time is never advanced by the domain, only read.
public final class RealClock: Clock {
    public init() {}

    public var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    public func advance(_ ms: Double) {
        // Real time cannot be advanced; the driver supplies dt to tick().
    }

    public func iso(_ atMs: Double? = nil) -> String {
        TapeClockFormat.iso(atMs ?? nowMs)
    }
}

enum TapeClockFormat {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func iso(_ ms: Double) -> String {
        formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
