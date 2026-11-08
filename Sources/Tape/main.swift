import AppKit
import Foundation

// A menu bar accessory: no window, no Dock icon, never activates itself.
let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    exit(SelfTest.run(arguments: arguments))
}
if arguments.contains("--inspect") {
    exit(Inspector.run(arguments: arguments))
}
if arguments.contains("--help") {
    print("""
    TAPE — offline, screenless, archive-only audio recorder.

    Usage:
      Tape                     run as a menu bar app
      Tape --selftest [dir]    headless end-to-end check of the archive pipeline
      Tape --inspect [dir]     print what an archive contains (default ~/Documents/TAPE)

    Options:
      -libraryPath <dir>         use <dir> as the archive for this run only
    """)
    exit(0)
}

// Before the delegate exists: it reads preferences and the archive path in its
// property initialisers, and the rename migration has to land first.
Rename.migrate()

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
