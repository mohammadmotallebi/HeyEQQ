# HeyEQQ Spike — system-wide EQ via Core Audio Process Tap

Proves the Option A pipeline before building the real app:

```
all apps ──► CATapDescription (global, muted-when-tapped, excludes self)
                 │
                 ▼
   private aggregate device  [clock = real output device, tap = input w/ drift comp]
                 │  IO proc
                 ▼
   EQProcessor (bass 100 Hz shelf · mid 1 kHz peak · treble 8 kHz shelf, auto-preamp)
                 │
                 ▼
         real speakers / headphones
```

## Run

```sh
# from the repo root
swift run HeyEQQSpike
```

Run it in a normal Terminal/iTerm window (it needs single-key input).
On first run macOS asks for **System Audio Recording** permission for your terminal app — click Allow.
If you missed it: System Settings › Privacy & Security › Screen & System Audio Recording.

Keys: `1/2` bass −/+ · `3/4` mid −/+ · `5/6` treble −/+ · `0` reset · `space` bypass (A/B) · `q` quit

It starts with Bass +6 dB so the effect is obvious. The meter shows tapped input level; if it stays empty
while music plays, the permission was not granted.

## Files

The pipeline and DSP now live in the shared `Sources/HeyEQQCore` library (also used by the app).
This folder only holds the terminal front-end (`Sources/HeyEQQSpike/main.swift`) and its
`Info.plist`, which is embedded into the binary (`NSAudioCaptureUsageDescription`).

## Known spike limitations

- The spike uses the output device at launch (the app's `EQEngine` follows device changes).
- Only first two output channels are driven.
- Runs continuously even during silence (battery).
