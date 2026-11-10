# Intercept

**Record everything going in and out of your Mac.** One button. Intercept records
your microphone and every sound your Mac plays, and optionally the whole screen,
into a single file.

- **Audio** mode → `Intercept <date> at <time>.m4a` (AAC, 48 kHz stereo)
- **Screen + Audio** mode → `Intercept <date> at <time>.mp4` (HEVC video at native resolution, 30 fps, plus the same audio)
  - **Displays: Main** records the display with the menu bar.
  - **Displays: All** records every distinct display in one video, placed side by
    side the way they're arranged in System Settings › Displays. A display that
    mirrors another is skipped, because its picture is already in the video.

The microphone and the system sound are mixed into one audio track, so any player
hears both sides. Recordings go to `~/Movies/Intercept` by default; pick another
folder from the main window.

Menu-bar app with a main window, styled to match One Tap Transcribe.
**⇧⌘R** starts and stops recording while the window is focused.

## Requirements

- macOS 26 or later, Apple Silicon.

## Permissions

Intercept needs two macOS permissions. The main window shows both, with **Grant**
buttons:

1. **Microphone**: to record what goes in.
2. **Screen & System Audio Recording**: to record the screen and the sound the Mac
   plays. macOS only applies this one after the app restarts, so press **Relaunch**
   after you allow it.

## Build from source

```bash
./build_app.sh release install   # build, sign, copy to /Applications, launch
./build_app.sh release run       # build and launch from ./build
```

Signing reuses One Tap Transcribe's local self-signed identity
(`./setup_signing.sh` in that project) if it exists, so rebuilds keep their
permissions. Otherwise the script signs ad-hoc.

## How it works

ScreenCaptureKit delivers the screen, the system sound and the microphone on one
clock. Intercept writes them into a temporary `.mov` with one video track and two
lossless audio tracks. When you stop, it copies the video into the final file
without re-encoding and mixes the two audio tracks into one AAC track. If the
mixing step fails, Intercept keeps the un-mixed `.mov` so nothing is lost.

With **All** displays, each display gets its own capture stream. A 30 fps timer
pastes the newest frame from each one onto a single canvas, capped at 7680×4320
so the hardware encoder can handle it.

### Developer self-test

```bash
# kinds: audio | screen | screenall | screenall-double (main display twice, tests compositing)
open -n /Applications/Intercept.app --args --selftest screen 5 /tmp/test.mp4
cat /tmp/test.mp4.txt
```
