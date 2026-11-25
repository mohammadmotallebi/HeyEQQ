# HeyEQQ

System-wide equalizer for macOS (14.2+, built for 15+). Lives in the menu bar; no audio driver to install.
It uses a Core Audio process tap to capture every app's sound, EQs it, and plays it to your speakers or headphones.

## Build & run

```sh
scripts/build-app.sh --install  # builds, signs, installs to /Applications/HeyEQQ.app, launches it
scripts/build-app.sh --open     # builds build/HeyEQQ.app and launches it from there
swift scripts/make-icons.swift  # regenerates Support/AppIcon.icns + menu-bar icon
swift test                      # DSP tests
swift run HeyEQQSpike           # terminal test tool (see Spike/README.md)
```

On first launch macOS asks for **System Audio Recording** permission — click Allow.
If you missed it: System Settings › Privacy & Security › Screen & System Audio Recording › enable HeyEQQ.

## Modes

| Mode | Status |
|---|---|
| Simple: on/off, 7 presets, Bass/Mid/Treble, level meter, output picker | ✅ |
| Advanced: 10-band graphic EQ window, preamp, response curve, 12 built-in + user presets, per-device presets | ✅ |
| Expert: parametric editor (≤32 bands, 7 filter types, draggable graph), auto preamp, AutoEQ / Equalizer APO import & export, saved curves | ✅ |
| Expert: per-app EQ (own curve or no EQ per app, helpers grouped, auto-follows app launch/quit) | ✅ |

## Extras

- **Bypass** (A/B compare): ⌥⌘E from anywhere, or the checkbox in the popover / button in the window
- **Launch at login**: checkbox in the popover (works best from /Applications)
- **Spectrum analyzer**: live output spectrum behind the EQ graph in the Equalizer window (waveform button)
- Icon: SVG Repo #141491 “equalizer” (`Support/Icon/equalizer.svg`); license not verified — check before distributing

## Surround / multichannel

When the output device is the system default and its first output stream has more than 2 channels
(5.1, 7.1, 7.1.4 …), HeyEQQ captures that stream at full channel count instead of a stereo mixdown,
equalizes every channel (incl. LFE) with the same curve, and uses one limiter linked across all
channels. Stereo content plays on the front pair, as macOS does. No upmixing.
Limits: up to 16 channels; devices that split channels over several 2-channel streams stay on the
stereo path. Debug: `defaults write com.heyeqq.app forceDeviceStreamTap -bool YES` forces the
device-stream capture on any default device.

## Layout

- `Sources/HeyEQQCore/` — `EQCurve`/`EQBand` (N-band model), `Biquad` (filter math + response), `EqualizerAPO` (AutoEQ import/export), `AudioProcesses` (per-app routing),
  `EQProcessor` (real-time DSP, limiter), `SystemAudioTap` (tap + aggregate device),
  `EQEngine` (lifecycle, device changes, diagnostics), `OutputDevices`, `InstanceGuard`, Core Audio helpers
- `Sources/HeyEQQ/` — SwiftUI `MenuBarExtra` popover + Equalizer window, `AppModel` (UserDefaults),
  presets (user presets in `~/Library/Application Support/HeyEQQ/presets.json`, Expert curves in `expert-presets.json`)
- `Support/Info.plist` — app bundle plist (`LSUIElement`, `NSAudioCaptureUsageDescription`)
- `scripts/build-app.sh` — packages and signs the .app
