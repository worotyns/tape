// The archive. A plain folder on disk, same layout as the simulator's microSD
// card, so either implementation can read the other's recordings:
//
//   TABULA/
//     manifest.json
//     events.jsonl
//     recordings/rec_000001.wav
//     metadata/rec_000001.json
//
// Nothing here ever overwrites or deletes a recording. A process killed during
// a recording leaves a repairable partial WAV behind; `recover` finishes the job.

import Foundation

public struct LibraryManifest: Codable, Sendable {
    public var formatVersion: Int
    public var libraryId: String
    public var createdAt: String
    public var nextSeq: Int

    public init(
        formatVersion: Int = Library.formatVersion,
        libraryId: String,
        createdAt: String,
        nextSeq: Int = 1
    ) {
        self.formatVersion = formatVersion
        self.libraryId = libraryId
        self.createdAt = createdAt
        self.nextSeq = nextSeq
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, libraryId, cardId, createdAt, nextSeq
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? Library.formatVersion
        // The simulator calls this "cardId"; accept both spellings.
        libraryId = (try? c.decode(String.self, forKey: .libraryId))
            ?? (try? c.decode(String.self, forKey: .cardId))
            ?? "library"
        createdAt = (try? c.decode(String.self, forKey: .createdAt))
            ?? TabulaClockFormat.iso(Date().timeIntervalSince1970 * 1000)
        nextSeq = (try? c.decode(Int.self, forKey: .nextSeq)) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        // Written as "cardId" to stay byte-compatible with the simulator format.
        try c.encode(libraryId, forKey: .cardId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(nextSeq, forKey: .nextSeq)
    }
}

public enum LibraryError: Error {
    case newerFormatVersion(Int)
    case renameFailed(Int32)
}

public final class Library {
    public static let formatVersion = 1

    public let root: URL
    public private(set) var manifest: LibraryManifest
    public let recordingsDir: URL
    public let metadataDir: URL
    public let manifestURL: URL
    public let eventsURL: URL

    private var quarantined: [(file: String, error: String)] = []
    private let fm = FileManager.default
    private var lockFD: Int32?

    private init(root: URL, manifest: LibraryManifest) {
        self.root = root
        self.manifest = manifest
        self.recordingsDir = root.appendingPathComponent("recordings", isDirectory: true)
        self.metadataDir = root.appendingPathComponent("metadata", isDirectory: true)
        self.manifestURL = root.appendingPathComponent("manifest.json")
        self.eventsURL = root.appendingPathComponent("events.jsonl")
    }

    public var libraryId: String { manifest.libraryId }

    // MARK: - Exclusive use

    /// An archive may only be written by one process at a time. Without this a
    /// second copy of the app — the installed one and a freshly built one, say —
    /// would hand out the same `rec_000001` twice and shred the archive.
    ///
    /// Advisory `flock`, held for the lifetime of the process.
    @discardableResult
    public func acquireLock() -> Bool {
        if lockFD != nil { return true }
        let path = root.appendingPathComponent(".lock").path
        // `Darwin.` is required: the static `Library.open` shadows `open(2)` here.
        let fd = Darwin.open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    public func releaseLock() {
        guard let fd = lockFD else { return }
        flock(fd, LOCK_UN)
        close(fd)
        lockFD = nil
    }

    deinit {
        releaseLock()
    }

    // MARK: - Opening

    public static func create(at root: URL, id: String? = nil) throws -> Library {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("recordings", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("metadata", isDirectory: true),
                               withIntermediateDirectories: true)
        let manifest = LibraryManifest(
            libraryId: id ?? "library-\(Int(Date().timeIntervalSince1970 * 1000))",
            createdAt: TabulaClockFormat.iso(Date().timeIntervalSince1970 * 1000),
            nextSeq: 1
        )
        let lib = Library(root: root, manifest: manifest)
        try lib.persistManifest()
        if !fm.fileExists(atPath: lib.eventsURL.path) {
            fm.createFile(atPath: lib.eventsURL.path, contents: nil)
        }
        return lib
    }

    /// Open an existing archive; create an empty one when the folder is new.
    public static func open(at root: URL) throws -> Library {
        let fm = FileManager.default
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            return try create(at: root)
        }
        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)
            if manifest.formatVersion > Library.formatVersion {
                throw LibraryError.newerFormatVersion(manifest.formatVersion)
            }
            let lib = Library(root: root, manifest: manifest)
            try fm.createDirectory(at: lib.recordingsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: lib.metadataDir, withIntermediateDirectories: true)
            return lib
        } catch let e as LibraryError {
            throw e
        } catch {
            // A corrupt manifest must not lose the recordings already on disk.
            let backup = root.appendingPathComponent("manifest.json.corrupt")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: manifestURL, to: backup)
            let lib = try create(at: root)
            lib.manifest.nextSeq = lib.maxSeqOnDisk() + 1
            try? lib.persistManifest()
            return lib
        }
    }

    private func maxSeqOnDisk() -> Int {
        listRecordings().map(\.seq).max() ?? 0
    }

    // MARK: - Manifest

    public func nextSeq() throws -> Int {
        let seq = max(1, manifest.nextSeq)
        manifest.nextSeq = seq + 1
        try persistManifest()
        return seq
    }

    private func persistManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(try encoder.encode(manifest), to: manifestURL)
    }

    // MARK: - Recordings

    public func recordingURL(_ id: String, ext: String) -> URL {
        recordingsDir.appendingPathComponent("\(id).\(ext)")
    }

    public func metadataURL(_ id: String) -> URL {
        metadataDir.appendingPathComponent("\(id).json")
    }

    public func listRecordings() -> [RecordingMeta] {
        try? fm.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        guard let files = try? fm.contentsOfDirectory(atPath: metadataDir.path) else { return [] }
        var out: [RecordingMeta] = []
        for file in files where file.hasSuffix(".json") {
            let url = metadataDir.appendingPathComponent(file)
            do {
                let data = try Data(contentsOf: url)
                out.append(try JSONDecoder().decode(RecordingMeta.self, from: data))
            } catch {
                // Corrupted metadata must not poison the archive: quarantine it
                // and keep going.
                let quarantine = metadataDir.appendingPathComponent(file + ".corrupt")
                try? fm.removeItem(at: quarantine)
                if (try? fm.moveItem(at: url, to: quarantine)) != nil {
                    quarantined.append((file: file, error: String(describing: error)))
                }
            }
        }
        out.sort { $0.seq < $1.seq }
        return out
    }

    public func takeQuarantineReports() -> [(file: String, error: String)] {
        defer { quarantined = [] }
        return quarantined
    }

    public func writeMetadata(_ meta: RecordingMeta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(try encoder.encode(meta), to: metadataURL(meta.id))
    }

    public func readMetadata(_ id: String) throws -> RecordingMeta {
        try JSONDecoder().decode(RecordingMeta.self, from: Data(contentsOf: metadataURL(id)))
    }

    public func totalBytes() -> Int {
        guard let files = try? fm.contentsOfDirectory(atPath: recordingsDir.path) else { return 0 }
        var total = 0
        for f in files {
            let url = recordingsDir.appendingPathComponent(f)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                total += size.intValue
            }
        }
        return total
    }

    // MARK: - Event log

    public func appendEvent(_ event: Event) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        var line = data
        line.append(0x0A)
        if !fm.fileExists(atPath: eventsURL.path) {
            fm.createFile(atPath: eventsURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: eventsURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    public func readEvents() -> [Event] {
        guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(Event.self, from: data)
        }
    }

    // MARK: - Recovery

    /// Called on open. Finalizes recordings that were in flight when the process
    /// died and drops abandoned temporaries. NEVER deletes a file that holds the
    /// only valid copy of a recording.
    @discardableResult
    public func recover(_ log: ((String) -> Void)? = nil) -> [RecordingMeta] {
        var started: [String: Event] = [:]
        var finalized = Set<String>()
        for e in readEvents() {
            switch e.type {
            case .recordingStarted:
                if let id = e["id"]?.stringValue { started[id] = e }
            case .recordingFinalized:
                if let id = e["id"]?.stringValue { finalized.insert(id) }
            default:
                break
            }
        }

        // Markers are the user's most valuable data, and they normally only
        // reach disk at finalize. The event journal already has them, so a
        // killed recording can still come back with its markers intact.
        var journaledMarkers: [String: [Marker]] = [:]
        for e in readEvents() where e.type == .markerAdded {
            guard let id = e["id"]?.stringValue,
                  let number = e["marker"]?.intValue,
                  let offset = e["sampleOffset"]?.intValue else { continue }
            journaledMarkers[id, default: []].append(
                Marker(id: number, sampleOffset: offset, atSimMs: e.simMs)
            )
        }

        var recovered: [RecordingMeta] = []
        let existing = listRecordings()
        for id in started.keys.sorted() where !finalized.contains(id) {
            let wavURL = recordingURL(id, ext: "wav")
            guard fm.fileExists(atPath: wavURL.path) else {
                log?("recovery: recording \(id) has no data on disk (lost)")
                continue
            }
            let stats = Library.repairWav(wavURL)
            var meta = existing.first { $0.id == id } ?? RecordingMeta(
                id: id,
                seq: Library.parseRecSeq(id),
                createdAt: started[id]?["at"]?.stringValue
                    ?? TabulaClockFormat.iso(started[id]?.simMs ?? Date().timeIntervalSince1970 * 1000)
            )
            meta.durationSamples = stats.durationSamples
            meta.sizeBytes = stats.sizeBytes
            meta.status = "finalized"
            meta.finalizedAt = TabulaClockFormat.iso(Date().timeIntervalSince1970 * 1000)
            meta.recovered = true
            if meta.markers.isEmpty, let journaled = journaledMarkers[id] {
                // A marker past the repaired end cannot exist (those bytes were
                // never flushed), so drop it rather than point at nothing.
                meta.markers = journaled
                    .filter { $0.sampleOffset <= stats.durationSamples }
                    .sorted { $0.sampleOffset < $1.sampleOffset }
            }
            try? writeMetadata(meta)
            // Record the fact in the log too, so recovery is idempotent and the
            // archive stays self-describing across sessions.
            let now = Date().timeIntervalSince1970 * 1000
            appendEvent(Event(
                seq: readEvents().count + 1,
                simMs: now,
                at: TabulaClockFormat.iso(now),
                type: .recordingFinalized,
                data: [
                    "id": .string(id),
                    "reason": "recovered",
                    "durationSamples": .int(stats.durationSamples),
                    "markers": .int(meta.markers.count),
                    "recovered": true,
                ]
            ))
            recovered.append(meta)
            log?("recovery: finalized \(id) (\(stats.durationSamples) samples)")
        }

        // Abandoned temporaries are never a committed representation.
        if let files = try? fm.contentsOfDirectory(atPath: recordingsDir.path) {
            for f in files where f.hasSuffix(".tmp") {
                try? fm.removeItem(at: recordingsDir.appendingPathComponent(f))
            }
        }
        return recovered
    }

    /// Recompute a WAV header from the real file length (after a hard kill).
    @discardableResult
    public static func repairWav(
        _ url: URL,
        sampleRate: Int = 16000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> (sizeBytes: Int, dataBytes: Int, durationSamples: Int) {
        let blockAlign = max(1, channels * bitsPerSample / 8)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeNumber = attrs[.size] as? NSNumber else {
            return (0, 0, 0)
        }
        let size = sizeNumber.intValue
        let dataBytes = max(0, size - WavStream.headerBytes)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return (size, dataBytes, dataBytes / blockAlign)
        }
        defer { try? handle.close() }
        let header = WavStream.header(
            dataBytes: dataBytes,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: header)
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        return (size, dataBytes, dataBytes / blockAlign)
    }

    // MARK: - Atomic, durable writes

    /// Write to a sibling temporary, force it to disk, then rename over the
    /// destination so a reader never sees a half-written file.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: tmp)
        if let handle = try? FileHandle(forWritingTo: tmp) {
            _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
            try? handle.close()
        }
        if rename(tmp.path, url.path) != 0 {
            throw LibraryError.renameFailed(errno)
        }
    }
}

// MARK: - Identifiers

extension Library {
    public static func recId(_ seq: Int) -> String {
        String(format: "rec_%06d", seq)
    }

    public static func parseRecSeq(_ id: String) -> Int {
        guard id.hasPrefix("rec_") else { return 0 }
        return Int(id.dropFirst(4)) ?? 0
    }
}
