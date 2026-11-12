# Intercept

**Record everything going in and out of your Mac.** One button. Tick any
combination of **Screen**, **Audio** and **Camera**, and Intercept records them
into a single file.

- **Screen** records the display at native resolution, 30 fps (HEVC).
  - **Displays: Main / All** (shown when more than one display is connected):
    the display with the menu bar, or every distinct display side by side, laid
    out like System Settings › Displays. Mirrored displays are skipped.
- **Audio** records a **microphone** (the system default, one you pick, or none)
  and/or **Mac sound** (everything the Mac plays).
- **Camera** records the camera you pick (built-in, external, or iPhone via
  Continuity Camera). With Screen it sits in a box in the bottom-right corner;
  on its own it fills the frame.

- **Transcribe** (under Audio) sends the sound to ElevenLabs Scribe v2 when a
  recording stops, and saves a transcript with speakers next to it as
  `<name>.transcript.json`. Add your ElevenLabs API key with **Add key…**; it's
  kept in the Keychain. Older recordings can be transcribed from the
  Recordings list.

The transcript window shows each turn tinted in the speaker's colour.
Double-click a speaker's name to give them a real name; double-click a
recording's name in the list to rename the file (its transcript follows).

Anything with Screen or Camera saves an `.mp4`; Audio alone saves an `.m4a`
(AAC, 48 kHz stereo). Files are named `Intercept <date> at <time>`.

The microphone and the system sound are mixed into one audio track, so any player
hears both sides. Recordings go to `~/Documents/Intercept` by default; pick another
folder from the main window.

A regular app (Dock and Cmd-Tab) with a menu-bar icon, styled to match One Tap Transcribe.
**⇧⌘R** starts and stops recording while the window is focused.

## Requirements

- macOS 26 or later, Apple Silicon.

## Permissions

Intercept asks only for what you've ticked:

1. **Microphone**: when Audio is ticked with a microphone chosen.
2. **Camera**: when Camera is ticked.
3. **Screen Recording**: when Screen is ticked. macOS only applies this one after
   the app restarts, so press **Relaunch** after you allow it.
4. **System audio**: to record Mac sound. macOS asks the first time.

The main window lists the first three, with **Grant** buttons.

## Build from source

```bash
./build_app.sh release install   # build, sign, copy to /Applications, launch
./build_app.sh release run       # build and launch from ./build
```

Intercept shares its "Graphite & Ember" theme, components and build scripts with
One Tap Transcribe through the
[GraphiteEmber](https://github.com/jammastergirish/GraphiteEmber) package, which
SwiftPM fetches. `build_app.sh`, `make_dmg.sh` and `release.sh` here are links to
`run_shared_script.sh`, which runs the matching script from the package's
`Scripts/` folder; this app's name and bundle ID live in `app.conf`.

Signing uses the local self-signed identity that the package's
`Scripts/setup_signing.sh` creates (the same one One Tap
Transcribe uses) if it exists, so rebuilds keep their permissions. Otherwise
the script signs ad-hoc.

### Public release (signed + notarized)

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="OneTapNotary" ./release.sh
```

This signs with Developer ID and the Hardened Runtime, builds
`build/Intercept-<version>.dmg` (plus a version-less `Intercept.dmg`), has Apple
notarize it, and staples the ticket so it opens without Gatekeeper warnings.

## How it works

Sound comes straight from Core Audio: a process tap records everything the Mac
plays, and the audio engine records the microphone. The screen comes from
ScreenCaptureKit. All three are stamped with the same host clock, and Intercept
writes them into a temporary `.mov` with one video track and two lossless audio
tracks. When you stop, it copies the video into the final file
without re-encoding and mixes the two audio tracks into one AAC track. If the
mixing step fails, Intercept keeps the un-mixed `.mov` so nothing is lost.

**Crash safety.** The temporary file is written in 10-second fragments, so if
the app crashes, is force-quit or the Mac loses power, everything up to the last
10-second mark still plays. Next time Intercept opens, it finishes any leftover
temporary file into `<name> (recovered).mp4` (or `.m4a`) and says so in the
window. It ignores temporary files written to in the last minute, in case another
copy of the app is still recording them.

**Locking and the display turning off.** Recording never stops on its own.
While recording, Intercept keeps the Mac from going to sleep when idle (the
display may still turn off). Sound keeps recording through a locked screen and a
dark display, because it doesn't depend on the screen. When macOS turns the
display off, the video holds its last picture and Intercept reconnects the
screen into the same file as soon as the display is back. Closing the lid or
choosing Sleep still sleeps the whole Mac; recording carries on in the same file
afterwards, with silence for the gap. Stopping from macOS's own screen-recording
menu ends the recording.

With **All** displays, each display gets its own capture stream. A 30 fps timer
pastes the newest frame from each one onto a single canvas, capped at 7680×4320
so the hardware encoder can handle it.

### Developer self-test

```bash
# kinds: audio | screen | screenall | screenall-double (main display twice, tests compositing)
open -n /Applications/Intercept.app --args --selftest screen 5 /tmp/test.mp4
cat /tmp/test.mp4.txt
# finish leftover temporary capture files in a folder
/Applications/Intercept.app/Contents/MacOS/Intercept --recover ~/Documents/Intercept
# drive the real app: start, wait N seconds, stop, list files
open -n /Applications/Intercept.app --args --apptest 120 /tmp/apptest
```
