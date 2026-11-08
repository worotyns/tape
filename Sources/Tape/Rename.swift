import Foundation

/// The app used to be called TABULA. Two things are filed under that name and
/// both have to survive the rename: **the archive** (the recordings, in
/// `~/Documents/TABULA`) and **the preferences** (shortcuts, mic gain, archive
/// path — they live in a `UserDefaults` domain named after the bundle
/// identifier, `local.tabula.recorder`).
///
/// So both are adopted once, at startup, before anything reads them. The point
/// is that nobody updating has to know this file exists: no second empty
/// archive appears, no shortcuts jump back to defaults, and the old folder does
/// not sit there half-forgotten.
///
/// This is deliberately the only place in the codebase that knows the old name.
/// When the last TABULA install is gone, deleting this file is the whole
/// cleanup.
enum Rename {
    /// Identifiers, not display names: these are what data is filed under.
    static let legacyBundleID = "local.tabula.recorder"
    static let legacyArchiveName = "TABULA"
    static let archiveName = "TAPE"

    private static let adoptedKey = "didAdoptTABULAName"

    /// Run once, before the app reads a preference or opens the archive.
    static func migrate() {
        adoptSettings()
        adoptArchive()
    }

    /// Where the archive lives when the user never chose a path: the new name
    /// if it is there, the old one if only that is. Read-only — this decides,
    /// it does not move anything.
    static func defaultArchiveURL() -> URL {
        let fm = FileManager.default
        guard let base = archiveParent() else {
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/\(archiveName)", isDirectory: true)
        }
        let current = base.appendingPathComponent(archiveName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyArchiveName, isDirectory: true)
        if fm.fileExists(atPath: current.path) || !fm.fileExists(atPath: legacy.path) {
            return current
        }
        return legacy
    }

    // MARK: - Settings

    /// Copy the old domain's keys into the current one, then repoint a
    /// remembered archive path at the renamed folder.
    private static func adoptSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: adoptedKey) else { return }
        // Set the flag first: a legacy domain that cannot be read must not make
        // this run again on every launch.
        defaults.set(true, forKey: adoptedKey)

        if let legacy = UserDefaults(suiteName: legacyBundleID) {
            for (key, value) in legacy.dictionaryRepresentation()
            where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        guard let path = defaults.string(forKey: "libraryPath") else { return }
        let remembered = URL(fileURLWithPath: path, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: remembered.path) else { return }

        let renamed = remembered.deletingLastPathComponent()
            .appendingPathComponent(archiveName, isDirectory: true)
        if remembered.lastPathComponent == legacyArchiveName,
           FileManager.default.fileExists(atPath: renamed.path) {
            defaults.set(renamed.path, forKey: "libraryPath")
        } else {
            // The folder is gone for some other reason. Forgetting the path
            // falls back to the default archive rather than recreating an
            // empty one wherever the stale path pointed.
            defaults.removeObject(forKey: "libraryPath")
        }
    }

    // MARK: - Archive

    /// Rename the *default* archive folder — nothing else — and only when the
    /// new name is still free, so a hand-picked archive elsewhere is never
    /// touched.
    ///
    /// It is a `moveItem`, not a copy and not a delete: either the whole
    /// archive arrives under the new name, or nothing happens and the app keeps
    /// reading it in place (`defaultArchiveURL`). There is no state in which
    /// half the recordings are here and half there.
    private static func adoptArchive() {
        let fm = FileManager.default
        guard let base = archiveParent() else { return }
        let legacy = base.appendingPathComponent(legacyArchiveName, isDirectory: true)
        let current = base.appendingPathComponent(archiveName, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: current.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
    }

    private static func archiveParent() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}
