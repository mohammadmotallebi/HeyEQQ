# Changelog

All notable changes to HeyEQQ are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [0.4.1] - 2026-11-27

### Fixed
- The preamp slider had no effect while Sound Quality was set to Clean. Clean now lowers the level by the EQ's biggest boost
  and the preamp still applies on top.

## [0.4.0] - 2026-11-26

### Added
- **Built-in speaker protection.** HeyEQQ stays off the Mac's own speakers by default. When you allow it,
  bass below 250 Hz is limited to +6 dB and nothing plays louder than without the EQ.
- **Sound Quality settings:** Loud or Clean output, a smooth look-ahead limiter, Clarity, and Accurate treble.
- **Fix limiting:** one click lowers the preamp by the amount the limiter was reducing peaks.
- Liquid Glass design on macOS 26.
- Universal build (Apple Silicon and Intel).

## [0.3.0] - 2026-11-25

### Added
- Redesigned menu bar popover with a live spectrum "sound bar" and peak-hold caps.
- Advanced faders and an Expert band list in the popover.
- Redesigned Equalizer window with a Settings pane.
- Per-device presets in every mode.
- Custom global shortcuts for bypass and next/previous preset.
- Balance slider and mono.
- Headphone search and AutoEQ correction curves, with a suggestion when a matching device is connected.
- Per-app volume.
- Limiter indicator.
- Surround and multichannel output (up to 16 channels).

## [0.2.0] - 2026-11-25

### Added
- First version: Simple, Advanced and Expert modes.
- Per-app EQ.
- AutoEQ and Equalizer APO import/export.
- Bypass hotkey, spectrum analyzer and launch at login.

[0.4.0]: https://github.com/mohammadmotallebi/HeyEQQ/releases/tag/v0.4.0
[0.3.0]: https://github.com/mohammadmotallebi/HeyEQQ/releases/tag/v0.3.0
[0.2.0]: https://github.com/mohammadmotallebi/HeyEQQ/commit/f057c90
