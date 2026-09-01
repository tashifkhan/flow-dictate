# Flow

A local-first macOS dictation app inspired by Wispr Flow. Hold a key, speak, release it,
and Flow transcribes, cleans up, and inserts the text at your cursor using Apple's
on-device speech and language APIs. No account, API key, or audio upload is required.

## Install

Flow requires macOS 26 or newer and a Swift 6 toolchain. Run this single command:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/tashifkhan/flow-dictate/main/scripts/bootstrap.sh)
```

The command downloads `scripts/bootstrap.sh` from `main`, clones the repository, builds
the app, installs it in `/Applications`, and opens it. Read the script first if you do
not want to execute remote code directly.

From an existing checkout, run:

```sh
scripts/make-cert.sh
scripts/install.sh
```

The scripts create a stable local signing certificate, build a release app, replace
`/Applications/Flow.app`, verify its signature, and open it. macOS then asks for
Microphone and Accessibility access. Grant both permissions from Flow's setup window.

Use the same command after pulling a new version:

```sh
scripts/install.sh
```

Do not skip `scripts/make-cert.sh` on a development Mac. Without its stable local
certificate, macOS treats each build as a different app and the permission grants stop
working. See [Permissions that will not stick](#permissions-that-will-not-stick).

## Build and run

SwiftPM is the source of truth. The build script compiles the executable, assembles the
app bundle, and signs it:

```sh
scripts/run.sh               # debug build and launch
scripts/run.sh release       # release build and launch
scripts/build.sh debug       # build without launching
```

`scripts/build.sh` signs with the local `Flow Dev` identity created by
`scripts/make-cert.sh` (falling back to ad-hoc, with a warning,
if you have not run it).

Flow is an accessory app. It lives in the menu bar with no dock icon.

### Verification

```sh
scripts/check.sh
```

Checks covering the SQLite store, retention, search, record derivation, statistics,
daily aggregates, hotkey encoding, lexicon matching, app-aware dictation,
custom-model handling, and availability copy. Exits non-zero on failure.

## Where the app is

Flow is a menu bar accessory, so there is no dock icon. Until both permissions are
granted it opens its window at launch onto a Setup screen that shows exactly what is
missing, what the transcriber and speech model are doing, and a button to try a
dictation. Once setup is done the window stops appearing on its own; open it from the
menu bar waveform icon › Flow Window, or `flowclone://history`.

## Permissions that will not stick

If you grant Accessibility, quit, reopen, and Flow still says it does not have it, with
the toggle clearly on in System Settings, this is why.

An ad-hoc signature (`codesign -s -`) has a designated requirement of
`cdhash H"…"`, a hash of the binary's contents. Every rebuild changes it, so macOS
treats each build as a different app. The TCC grant is still pinned to the old hash, so
`AXIsProcessTrusted()` returns false while the switch sits there looking enabled.

`scripts/make-cert.sh` fixes it by creating a self-signed identity in its own keychain (no
login-keychain password needed). The requirement becomes:

```
identifier "sh.taf.flow" and certificate leaf = H"…"
```

which is keyed to the certificate, not the binary, so it survives rebuilds. After
switching, clear the stale entries once:

```sh
tccutil reset Accessibility sh.taf.flow
tccutil reset Microphone sh.taf.flow
```

Then grant them again. They stick from then on.

## Permissions

Flow asks for two things, once each. Both are required before it can do anything useful.

| Permission | Why | Where |
| --- | --- | --- |
| **Accessibility** | Watch the push-to-talk key, and type at your cursor | System Settings › Privacy & Security › Accessibility |
| **Microphone** | Capture audio while you hold the key | Prompted on first dictation |

Accessibility must be granted manually. macOS gives no way to script it. Flow triggers
the prompt on first launch and nags in the menu bar until it is granted. **After
granting it, quit and relaunch Flow.** Event taps are only installed at startup.

## Using it

- **Hold `fn`** anywhere in macOS, talk, let go. Settings › General › Hold to talk
  rebinds it. Pick a preset, or click the field and press any modifier (fn, right ⌥,
  right ⌃…) or any key with at least one modifier (⌃⌥Space). A bare letter is refused.
  It is a global watcher and would fire while you type.
- **Escape** while recording cancels without inserting
- **⇧⌘V** re-inserts the selected history entry at the cursor
- **⇧⌘N** new note, **⇧⌘D** start a dictation, both in-app
- `flowclone://toggle`, `flowclone://history`, `flowclone://note` for Raycast quicklinks

Optional, off by default: a dock icon, a notification when text lands, and a trained
custom speech model (Settings › Vocabulary).

Voice commands ride the same round trip as ordinary dictation: "scratch that",
"replace X with Y", "new paragraph".

If no editable text field has focus, Flow leaves the finished text on the clipboard
and says "Copied to clipboard" in the panel. It does not send a paste shortcut to the
frontmost window.

Only one Flow process may own the global hotkey. If the installed app is already
running and a second copy launches from a build directory, the newer copy exits before
it can record or insert anything.

Flow cleans the whole spoken thought after recording ends. It removes filler, false
starts, stutters, and accidental repetition; applies the speaker's latest explicit
correction; and turns clear spoken structure into paragraphs or lists. It keeps distinct
ideas, facts, names, numbers, examples, and constraints instead of summarizing them.

Cleanup and recognition also adapt to the destination. Chat apps keep a casual tone,
email gets complete polished sentences, and developer tools receive extra technical
vocabulary. This works for recognized sites inside a browser, including Gmail, Slack,
WhatsApp, GitHub, GitLab, Google Docs, and Notion. Flow classifies the site on your Mac
and discards the page title and URL; neither is added to dictation history or passed to
the language model.

Settings › General › Language also has a Hinglish mode. It listens with the Hindi
speech model, accepts Hindi mixed with English, and writes Hindi words in simple Roman
script instead of Devanagari. English product names and technical terms stay in English.
If Apple Intelligence cleanup is unavailable, a local transliteration fallback still
keeps the result in Latin characters.

## What's built

| Phase | State |
| --- | --- |
| **P0** menu bar skeleton, hotkey, capture, transcription | done |
| **P1** insertion at cursor, cleanup, command decisions | done |
| **P2** panel, waveform, liquid glass, three states | done |
| **P3** history, lexicon, AX direct-insert, retention | done |
| **P4** main window, list/grid, scratchpad, summaries | done |
| **P5** login item, URL scheme, DMG packaging | done |
| **P5** custom `SFSpeechLanguageModel` training | done, opt-in |
| **P5** notarization | scripted; needs your Developer ID to run |

### Layout

```
Sources/Flow/
  App/                   scenes, app delegate, commands
  Diagnostics/           application-level self-checks
  Dictation/             capture, speech pipeline, cleanup, lexicon, controller
  Insertion/             AX + paste inserter, front-app detection, permissions
  Hotkey/                push-to-talk event tap
  Panel/                 non-activating NSPanel, waveform, levels
  Store/                 records, HistoryStore protocol, SQLite + memory stores
  Window/                main window, browsers, note editor, settings, menu bar
  Support/               settings, login item, environment, local API

AppBundle/               Info.plist and signing entitlements
scripts/                 build, run, install, verification, certificate, and packaging tools
```

## Statistics

Sidebar › Statistics. **Overview** gives WPM, Time Saved, and Total Words over a
selectable window; **Activity** is a contribution graph of words dictated per day across
the trailing year, with a per-day hover readout.

Statistics are computed from a separate `daily_stat` aggregate table, not from the
transcripts. That matters. Retention deletes what you said, and it should not also
delete the fact that you said it. The aggregate holds no content, just a date, a word
count, a dictation count, and a duration, so a year of activity survives a 30-day
retention setting. Upgrading backfills the table from whatever transcripts you still
have.

Time Saved compares speaking against typing at 40 wpm. It is an estimate and the UI
says so.

The heatmap is a sequential one-hue ramp, light→dark, with absence encoded as neutral
gray rather than the palest blue. "Nothing happened" is not a small magnitude. Light
and dark steps were each chosen and validated against their own surface rather than one
being flipped for the other.

## Local API

Off by default. Settings › API turns it on. It binds to `127.0.0.1` only, so nothing off
this Mac can reach it, and every endpoint except `/v1/health` requires a bearer token
shown in that settings tab.

```sh
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/v1/stats
```

| Method | Endpoint | Does |
| --- | --- | --- |
| GET | `/v1/health` | Version and whether setup is complete. No token. |
| GET | `/v1/stats?range=` | `today`, `week`, `month`, `year`, `allTime` |
| GET | `/v1/activity` | Words per day, for your own charts |
| GET | `/v1/history?q=&limit=` | Dictations, raw and cleaned |
| GET | `/v1/notes` | Scratchpad notes |
| POST | `/v1/notes` | `{"text":"…"}` → new note |
| POST | `/v1/dictate` | `{"action":"start\|stop\|toggle\|cancel"}` |
| POST | `/v1/insert` | `{"text":"…"}` → type it at the cursor |

## Shipping

```sh
scripts/package.sh                                          # ad-hoc DMG, not notarized
DEVELOPER_ID="Developer ID Application: You (TEAM)" scripts/package.sh
DEVELOPER_ID=... NOTARY_PROFILE=flow scripts/package.sh     # sign, notarize, staple
```

Store the notary profile once:

```sh
xcrun notarytool store-credentials flow --apple-id you@example.com \
      --team-id TEAMID --password APP-SPECIFIC-PASSWORD
```

Without `DEVELOPER_ID` the DMG still builds and installs, but it keeps the ad-hoc
signature, so Gatekeeper warns on other Macs. There are no signing identities on this
machine, so the notarized path is written and wired but has not been executed here.

## Custom speech model

The heavier custom-vocabulary option, in Settings › Vocabulary. It trains an
`SFCustomLanguageModelData` model from your word list and past corrections.

It carries a real cost, and the settings window says so. A custom model can only be
attached to `DictationTranscriber`, not to `SpeechTranscriber`, so turning it on trades
the better transcriber for the fallback. Try the word list alone first. It is fed to
the recogniser as contextual strings and to the cleanup prompt, and that is most of the
win. Hence opt-in, with a discard button.

## Where the toolchain changed the design

The first implementation used Command Line Tools on macOS 26.5. The repository still
avoids Xcode-only project files so command-line and Xcode builds share the same package.

**SwiftData → SQLite.** `@Model` is a macro whose plugin ships with Xcode, not with the
Command Line Tools, so it cannot compile here. Persistence sits behind the
`HistoryStore` protocol with a SQLite implementation; adding a SwiftData conformance
later means one new file and one changed line in `Library.make()`.

**`@Generable` → `DynamicGenerationSchema`.** Same missing plugin. The cleanup pass
builds its `Decision` schema through Foundation Models' dynamic schema API instead,
which gives identical constrained decoding without the macro.

**`CaptureInputSequenceProvider` → a hand-rolled tap.** The original sketch uses this
type; it does not exist in the macOS 26.5 SDK. `AudioCapture` does the same job
directly: an `AVAudioEngine` input tap, an `AVAudioConverter` into the analyzer's
preferred format, and an `AsyncStream<AnalyzerInput>`. The same tap computes RMS for
the waveform, so there is exactly one mic session.

**`preset: .dictation` → `.progressiveTranscription`.** No `.dictation` preset exists.
Progressive is the one that emits volatile results, which is what makes it feel live.

**KeyboardShortcuts (SPM) → a CGEvent tap.** Push-to-talk needs both key edges; a
registered hotkey only reports that it fired. The tap also drops a network dependency.

**Application self-checks.** The original Command Line Tools environment lacked the
XCTest and Swift Testing runtimes, so the checks live behind the app's `--self-check`
flag. `scripts/check.sh` builds the app and runs that suite.

## Fixed since the first build

**The processing hang.** Holding the key worked, but releasing it left the panel stuck
on "Cleaning up…" forever. Root cause: when the analyzer receives *zero* input buffers,
`finalizeAndFinishThroughEndOfInput()` returns normally but `SpeechTranscriber.results`
never terminates, and it does not honour cancellation, so awaiting it wedged the app.
Racing it against a timeout in a task group does not help either, because a task group
cannot return until every child finishes. The fix is to never await it: finalizing
already guarantees delivery, so `finish()` cancels the results task and yields once to
let queued results land. Reproduced and verified with a file-fed analyzer harness.

**No visible GUI.** See [Where the app is](#where-the-app-is).

**Permission grants silently not applying.** See
[Permissions that will not stick](#permissions-that-will-not-stick). This was the cause
of "I granted it, I quit the app, no difference" and of dictation refusing to start.

**The panel never went away.** After a failed dictation the error timed out back to
idle, but nothing hid the panel, so it sat on screen reading "Hold fn to talk"
indefinitely. The panel now follows the dictation: when the phase returns to idle, it
hides.

**Cleanup status was frozen at whatever it was on launch.** `SystemLanguageModel`
availability is not observable and flips without warning. The model finishes preparing,
or you switch Apple Intelligence on. Flow now polls while it is unavailable and starts
using cleanup on its own, no relaunch. The "model still downloading" wording was also
overconfident: `.modelNotReady` is macOS reporting that Apple Intelligence is not ready
yet, which is not always a download, so the copy now says so and points at the right
settings pane.

**In-note dictation demanded Accessibility.** Dictating into a Flow note never types
into another app, so it no longer requires the permission that only exists for typing.

**Silent failure when the mic delivered nothing.** Flow now distinguishes "you said
nothing" from "no sound reached the microphone" and says which.

## Known limitations

- **Cleanup depends on Apple Intelligence.** If `SystemLanguageModel.availability`
  reports that Apple Intelligence is disabled or not ready, Flow inserts raw
  transcripts and reports the reason in the menu bar and panel.
- **Clipboard restore window.** The paste path holds your clipboard for ~600 ms. Copy
  something in exactly that window and you lose it. Acceptable.
- **Notarization is unexecuted.** `notarytool` and `stapler` are present, but this Mac
  has no Developer ID identity, so `scripts/package.sh`'s notarize path has never run.
  The DMG mounts, and the app inside it validates.
- **The dictation loop is unverified end to end.** Transcription, insertion, and the
  panel all need Microphone and Accessibility grants, which only you can give. What has
  been verified: the app builds, launches, stays resident, creates its database, and
  passes all 94 self-checks; `SpeechTranscriber` reports available with `en_IN`
  resolved and nine installed locales.
