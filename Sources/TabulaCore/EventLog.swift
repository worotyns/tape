// Append-only event log. The domain emits; the archive mirrors to events.jsonl
// so state can be reconstructed, and never by replaying side effects.

import Foundation

public final class EventLog {
    public private(set) var events: [Event] = []
    /// Mirrors every event into the archive (events.jsonl).
    public var sink: ((Event) -> Void)?
    /// Notifies the host (used to drive sounds and the LED).
    public var onEmit: ((Event) -> Void)?

    public init() {}

    public func attach(_ sink: ((Event) -> Void)?) {
        self.sink = sink
    }

    @discardableResult
    public func emit(_ atMs: Double, _ type: EventType, _ data: EventData = [:]) -> Event {
        let event = Event(
            seq: events.count + 1,
            simMs: atMs,
            at: TabulaClockFormat.iso(atMs),
            type: type,
            data: data
        )
        events.append(event)
        // The archive mirror is non-throwing by contract: `Library.appendEvent`
        // contains its own I/O errors, so a failing archive never takes the
        // device down.
        sink?(event)
        onEmit?(event)
        return event
    }

    public func tail(_ n: Int = 10) -> [Event] {
        Array(events.suffix(n))
    }

    public func count(_ type: EventType) -> Int {
        events.reduce(0) { $0 + ($1.type == type ? 1 : 0) }
    }
}

public struct Event: Codable, Sendable, Equatable {
    public var seq: Int
    public var simMs: Double
    public var at: String
    public var type: EventType
    public var data: EventData

    public init(seq: Int, simMs: Double, at: String, type: EventType, data: EventData = [:]) {
        self.seq = seq
        self.simMs = simMs
        self.at = at
        self.type = type
        self.data = data
    }

    public subscript(_ key: String) -> JSONValue? {
        data[key]
    }

    enum CodingKeys: String, CodingKey {
        case seq, simMs, at, type
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // Event data is flattened into the same JSON object as the envelope, which
    // keeps the on-disk shape identical to the simulator's events.jsonl.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        simMs = try c.decode(Double.self, forKey: .simMs)
        at = try c.decode(String.self, forKey: .at)
        type = try c.decode(EventType.self, forKey: .type)
        var data: EventData = [:]
        let all = try decoder.container(keyedBy: AnyKey.self)
        let reserved = Set(["seq", "simMs", "at", "type"])
        for key in all.allKeys where !reserved.contains(key.stringValue) {
            if let value = try? all.decode(JSONValue.self, forKey: key) {
                data[key.stringValue] = value
            }
        }
        self.data = data
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(simMs, forKey: .simMs)
        try c.encode(at, forKey: .at)
        try c.encode(type, forKey: .type)
        var all = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in data.sorted(by: { $0.key < $1.key }) {
            try all.encode(value, forKey: AnyKey(stringValue: key))
        }
    }
}
