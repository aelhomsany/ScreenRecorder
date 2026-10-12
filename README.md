# Screen Recorder

A lightweight macOS menu bar screen recorder built on ScreenCaptureKit (macOS 15+).

- Record the entire screen (any display), a single window, or a dragged-out area
- 3-second on-screen countdown (cancel with ⌃⌥⌘R)
- Draggable round webcam bubble (S/M/L, any camera incl. Continuity Camera), recorded in Screen and Area modes
- System audio and microphone, mixed into one MP4 (H.264 + AAC)
- 30 or 60 fps, at native resolution (scaled down to fit inside H.264's 4096×2304 limit)
- Area picker: hover highlights the window or popup under the pointer (click to pick it), or drag
  any area; move/resize handles, arrow-key nudging, a floating Record button, and an option to
  start from the last area
- With Accessibility access, the picker also highlights parts of windows (sidebars, toolbars,
  panes…); scroll to step between smaller and bigger parts
- Floating control bar while recording (timer, Pause/Resume, Stop, Discard), never captured in the video
- Pause and resume: each stretch is recorded as its own segment, and the segments are joined
  losslessly into one MP4 when you stop
- Global hotkeys: **⌃⌥⌘R** start/stop, **⌃⌥⌘A** select an area and record, **⌃⌥⌘P** pause/resume
- Recordings are saved to `~/Movies/ScreenRecorder`

## Build & run

```bash
./build.sh --run
```

On first use, macOS asks for **Screen & System Audio Recording** permission (and Microphone, if enabled).
Detecting parts of windows in the area picker also needs **Accessibility** (Area mode → “Allow…”).
After granting it, quit the app and open it again.

### Keeping permissions across rebuilds

With ad-hoc signing, macOS treats every build as a new app, so the Screen Recording toggle
stays on but stops working. Create a stable local signing identity once:

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Name `ScreenRecorder Dev`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**.

`build.sh` picks it up automatically (or set `CODESIGN_IDENTITY` to any other identity).
After switching identities, reset the old grant once:
`tccutil reset ScreenCapture com.aelhomsany.ScreenRecorder`.

## Layout

| File | Purpose |
|------|---------|
| `Sources/ScreenRecorder/ScreenRecorderApp.swift` | App entry point and menu bar icon |
| `Sources/ScreenRecorder/MenuView.swift` | The menu bar panel UI |
| `Sources/ScreenRecorder/Recorder.swift` | Capture and recording logic (SCStream + SCRecordingOutput) |
| `Sources/ScreenRecorder/HotKey.swift` | Global hotkey (Carbon) |
| `Resources/Info.plist` | Bundle config (menu bar only, mic usage text) |
