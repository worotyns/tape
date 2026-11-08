# TAPE

[![ci](https://github.com/worotyns/tape/actions/workflows/ci.yml/badge.svg)](https://github.com/worotyns/tape/actions/workflows/ci.yml)

A recorder that never forgets. TAPE captures voice from the menu bar, and keeps
it as **continuous tape memory** rather than a folder of files: one growing line
that only ever gets written to, where every point you marked is somewhere you can
come back to.

It has no main window. The icon in the menu bar is the display, the interface is
global shortcuts and sound, and the only window is Preferences. Nothing is ever
deleted, overwritten, or renamed out from under you.

## What it does

Three gestures cover daily use:

- **`⌃⌥R`** — start / stop recording.
- **`⌃⌥M`** — mark this moment. While recording it drops a marker; while not
  recording it spools the tape back ~2.5 s and plays it, so you can hear again
  what just went past.
- **`⌃⌥↑` / `⌃⌥↓`** — walk the cues. Moving the cursor plays what it lands on.

## The concept: continuous tape memory

A recording is not a file you open, save and close. It is **tape**: a line that
is only ever appended to. A start, then every moment you marked, then another
start, and on. There is no file list, no folder tree to click through, and no
trash.

```
●━━━━━━━⚑━━━━━━⚑━━━━━━━●━━━━━━⚑━━━━━━━●

●  recording start       ⚑  marker (MEM)
```

That single line is the entire structure of the archive. A **cue** is any point
on it — a recording start or a marker — and the cursor walks cues instead of
files. Everything else in the app follows from that, including the things that
look like missing features:

1. **The tape only grows.** There is no delete, no overwrite, no "save as". A
   recording that exists, exists. This is a property, not a backlog item.
2. **The write is append-only and repairable.** Metadata lands through `.tmp` +
   `F_FULLFSYNC` + atomic `rename`, and every marker is also written to an event
   log. If the process dies mid-recording, `recover()` reconstructs it from the
   file length and the log — and it is idempotent, so running it twice is fine.
3. **Moving the cursor auditions.** It does not select a point and wait for
   play; it plays immediately. You find a moment in a recording by ear, not by
   eye.
4. **MEM spools the tape.** MEM carries no navigation of its own (it does not
   duplicate the cursor), which leaves it free to be a precision modifier: held
   down it scrubs seconds within a recording, and outside recording it rewinds
   2.5 s — the way you would push tape back with a thumb to hear something
   again.
5. **The head parks on what you just recorded.** After stopping, the cursor sits
   on the fresh recording, not the old one. It also remembers its position
   across launches, keyed by cue identity rather than index, so appending new
   recordings never shifts it.
6. **The tape is one folder of plain files.** The whole archive is
   `manifest.json` + an event log + WAVs. The format is versioned, markers are
   stored as sample offsets (not wall-clock times), and two copies of the app
   cannot corrupt it: only one writes at a time, guarded by `flock`.

## Requirements

- macOS 13 or later.
- To build: Xcode or the command line tools (Swift 5.9 or later). There are no
  package dependencies.

## Install

### From a release

Download the latest `Tape-x.y.dmg`, open it and drag **Tape.app** onto
Applications.

The build is ad-hoc signed rather than notarized, so a copy that arrived as a
download carries a quarantine flag and Gatekeeper refuses the first launch.
Right-click the app and choose *Open*, or clear the flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Tape.app
```

macOS will then ask twice: for access to your Documents folder (the archive
lives in `~/Documents/TAPE`) and for the microphone, on your first recording.
The app deliberately does not prompt for the microphone at launch — a recorder
should ask when you record, not while you are working.

### From source

```sh
./scripts/install.sh          # build and install to /Applications
```

Or, without a terminal: double-click **Install TAPE.command** in Finder.

Either way TAPE behaves like any other Mac app afterwards — launch it from
Finder, Spotlight or Launchpad. It has no Dock icon (it is an accessory,
`LSUIElement`) and never steals focus; you quit it from its own menu in the
menu bar.

| Flag | Effect |
|---|---|
| `--user` | install to `~/Applications` instead of `/Applications` |
| `--login` | add a `LaunchAgent` so it starts at login |
| `--dmg` | also build `dist/Tape-0.1.dmg` (drag-to-Applications) |
| `--no-launch` | install without launching |
| `--uninstall` | remove the app and the login item |

`--uninstall` **does not touch recordings** — they live in `~/Documents/TAPE`,
and neither installing nor uninstalling ever deletes one.

### Running from the build directory

```sh
./scripts/run.sh              # release build + .app + launch
./scripts/run.sh --log        # foreground, stderr visible
```

The `.app` is required, not cosmetic: TCC reads
`NSMicrophoneUsageDescription` from `Info.plist`, so a bare `swift run` is
denied microphone access **without even being asked**.

### Microphone permission across updates

macOS ties microphone consent to the code signature. Under an ad-hoc signature
every rebuild is a new cdhash, so TCC asks again — or, worse, denies silently.
A stable identity removes the problem permanently: create a self-signed code
signing certificate in Keychain Access, then

```sh
TAPE_SIGN_IDENTITY="TAPE Dev" ./scripts/install.sh
```

The installer warns when an update would change the signature.

## Shortcuts

Every shortcut is editable: **menu bar → Preferences… → Global shortcuts**. The
defaults:

| Shortcut | Action |
|---|---|
| `⌃⌥R` | recording on/off (asks for the microphone the first time) |
| `⌃⌥M` | **while recording:** marker · **while not:** rewind 2.5 s and play |
| `⌃⌥↑` or `⌃⌥←` | previous cue (auditioned) |
| `⌃⌥↓` or `⌃⌥→` | next cue (auditioned) |
| `⌃⌥⇧↑` / `⌃⌥⇧↓` | scrub ∓5 s within the current recording |
| `⌃⌥⏎` | play / pause at the cursor |
| `⌃⌥H` | "where am I" — the pitch of the tone encodes position in the archive |

**Cues on both axes.** Any arrow walks cues: up and left go back, down and right
go forward. `Shift` is the same axis at a finer grain — scrubbing inside the
current recording.

**The ends of the archive are audible.** At the first cue `⌃⌥↑` used to do
nothing at all: no sound, no blink, indistinguishable from a broken app. Both
ends now have their own low blip, once per hold rather than on repeat.

The cue map can be inspected without the GUI: `Tape --inspect` prints the whole
list in order.

Global shortcuts go through Carbon's `RegisterEventHotKey`, which needs **no**
Accessibility permission and **consumes** the key. `NSEvent.addGlobalMonitorForEvents`
would require Accessibility and would let the key through to the focused app —
so every shortcut would also type itself wherever you happen to be writing.

## Preferences

The menu bar menu is only the status line, **Preferences…** and **Quit**:
navigating the archive belongs to the shortcuts, so the menu does not carry a
second, drifting copy of it. Preferences hold what used to be submenus:

- **Global shortcuts** — click a shortcut and press the new keys; `Esc` cancels,
  `+` adds an alternative, `×` removes one. While a shortcut is being recorded,
  the global ones are temporarily unregistered, otherwise Carbon would swallow
  the very combination you are pressing. Conflicts are rejected with a message.
- **Launch TAPE at login** — the same `LaunchAgent` that `install.sh --login`
  writes, so the checkbox and the installer cannot disagree.
- **Archive** — the archive path, "Open recording folder" and "Change…".
- **Microphone** — input gain and a level preview.

## The icon is the only display

A single dot in the menu bar carries the state:

| Colour | Mode | Meaning |
|---|---|---|
| red | steady | recording |
| red | blinking | error (no microphone, archive unreachable) |
| green | steady / blinking | playing / paused |
| cyan | 250 ms flash | detent — a jump between cues |
| magenta | 250 ms flash | fine scrub |
| grey | dim | idle |

The dot is drawn as a non-template `NSImage` with a dark outline so it reads on
both light and dark menu bars. The 20 Hz tick loop animates the pulsing, so
there is no second timer.

An archive that cannot be opened is a **blinking red dot**, not a grey one, and
the app retries every two seconds instead of giving up until the next launch.

The same dot is the **app icon**, enlarged onto a flat graphite plate
(`scripts/make-icon.swift`). Flat throughout: no gradient, no shadow, no bevel,
no glow — two decisions, colour and dot size, both of which survive being scaled
to 16 px in a Finder list, because the icon is drawn as vectors at each size
rather than downsampled from 1024 px. Red is on the icon because it is the only
steady state; green, cyan and magenta live only in the menu bar. The `.icns` is
not in the repository — `make-app.sh` draws it.

## The archive on disk

`~/Documents/TAPE/` by default, or any other path chosen in Preferences → Archive
(remembered). The archive is ordinary files that outlive the app:

```
TAPE/
  manifest.json                 # formatVersion, cardId (archive identity), nextSeq
  events.jsonl                  # append-only event log
  recordings/rec_000001.wav     # PCM mono 16 kHz s16le
  metadata/rec_000001.json      # duration, markers (sample offsets)
```

The format is versioned: an archive written by a newer version is refused with a
message rather than guessed at. For a one-off test without touching your real
archive:

```sh
.build/Tape.app/Contents/MacOS/Tape -libraryPath /tmp/tape-test
```

## Durability: what is actually tested

| Property | How |
|---|---|
| process killed mid-write | the WAV header is written last, `recover()` takes the length from the file size |
| **markers survive a kill** | the event log holds every `MARKER_ADDED`, recovery replays them |
| metadata is never half-written | `.tmp` + `F_FULLFSYNC` + atomic `rename` |
| recovery is idempotent | the fact of recovery is itself logged as `RECORDING_FINALIZED` |
| corrupt metadata cannot poison the archive | the file is quarantined as `.corrupt` |
| nothing deletes a recording | there is no delete path; markers are trimmed to the repaired length, never the reverse |
| two copies of the app cannot destroy the archive | `flock` on `<archive>/.lock`, one writer at a time |

That last one matters only after installation: `open` reuses a running instance
of the *same* bundle, but the installed app and a freshly built one are two
different bundles. Without the lock both would read the same `nextSeq` and both
would create `rec_000006.wav` — and opening a file truncates it, so the first
recording is lost. The lock is advisory (`flock`), so the system releases it when
the process is killed; there is no stale lock after a crash.

## Verification

```sh
swift test                          # 37 domain and shortcut tests, headless
./scripts/run.sh --no-open
BIN="$(swift build -c release --show-bin-path)/Tape"
"$BIN" --selftest                   # end-to-end pipeline, real binary
"$BIN" --inspect                    # what is in the archive (default ~/Documents/TAPE)
```

`--selftest` walks the whole pipeline: record → mark → kill the process mid-write
→ recover → rebuild cues → spool back with MEM, and checks that the written WAV
is readable by CoreAudio and contains actual sound.

`--inspect` shows whether the microphone really captured sound or only silence:

```
rec_000002  0:13  ⚑2  406 KB   peak 37.7%  rms 2.52%  real audio
      ⚑1 @ 0:06  (92768 samples)
      ⚑2 @ 0:08  (121474 samples)
```

## Project layout

```
Sources/TapeCore/       the domain: no AppKit, no CoreAudio, no filesystem
  Device.swift          state machine, cues, markers, audition, MEM
  Library.swift         archive, manifest, event log, recovery, repairWav
  Audio.swift           streaming WAV writer, PCM analysis, synthetic signal
  Keybindings.swift     actions, combos, defaults, upgrade merge, conflicts
  Protocols.swift       MicSource / AudioSink / Clock — the replaceable edges
Sources/Tape/           AppKit + CoreAudio: StatusLED, HotKeys, MicCapture,
                        AudioPlayer, ToneFeedback, PreferencesWindow,
                        AppDelegate, SelfTest, Inspector
Tests/TapeCoreTests/    37 domain tests (state, cues, writing, recovery)
scripts/                install.sh · make-app.sh · make-dmg.sh · run.sh · make-icon.swift
```

The core knows nothing about AppKit or CoreAudio: the whole logic — state
machine, cursor over cues, writing and recovery — lives in `TapeCore` and is
tested without a UI. `Sources/Tape/` is only the edges: microphone, playback,
shortcuts, menu bar.

## Releasing

Tags are the trigger:

```sh
git tag v0.2 && git push origin v0.2
```

`.github/workflows/release.yml` runs the tests, builds the bundle, packs
`dist/Tape-0.2.dmg` (built by `scripts/make-dmg.sh`, the same script
`install.sh --dmg` uses), writes `SHA256SUMS`, and publishes a GitHub release
with the version stamped into the bundle from the tag. A manual run of the
workflow does the same from any branch and creates the tag itself.

Signing and notarization are not wired up: releases are ad-hoc signed, and the
release notes say so and explain how to open the app anyway. Wiring in a
Developer ID certificate and `notarytool` would go between build and publish.

`ci.yml` runs the same tests plus a bundle build on every push to `main` and
every pull request.

## Known limits and next steps

- **No compression** — files are PCM 16 kHz mono (~1.9 MB/min).
- **Playback position is modelled**, not read back from `AVAudioPlayerNode`.
  Drift is bounded because every cue starts afresh, but a long uninterrupted
  listen can wander. The natural next step.
- **Unsigned builds** — with an ad-hoc signature the cdhash changes on every
  rebuild, so TCC may ask for the microphone again. A free "Apple Development"
  certificate and `TAPE_SIGN_IDENTITY` fix it for good.
- **The login item is a `LaunchAgent`** — the Preferences checkbox (and
  `install.sh --login`) write a plist into `~/Library/LaunchAgents`;
  `SMAppService` would need a stable signature.
- **One audition at a time** — there is no playback queue, by design.

## License

MIT — see [LICENSE](LICENSE).
