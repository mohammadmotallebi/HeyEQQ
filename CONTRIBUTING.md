# Contributing to HeyEQQ

Thanks for your interest in improving HeyEQQ! Bug reports, ideas and pull requests are all welcome.

## Reporting bugs

Open an [issue](../../issues/new/choose) using the bug report form. Please include:
- your macOS version and Mac model (Apple Silicon or Intel)
- the output device (built-in speakers, AirPods, USB DAC, …)
- the steps to reproduce the problem

Log output helps a lot. Run this, reproduce the problem, then paste the result:
```sh
log stream --predicate 'subsystem == "com.heyeqq.app"' --level debug
```

## Development setup

Requirements: macOS 15 or newer and Xcode 26 or newer (the Liquid Glass UI needs the macOS 26 SDK).

```sh
git clone https://github.com/mohammadmotallebi/HeyEQQ.git
cd HeyEQQ
swift test                     # run the test suite
scripts/build-app.sh --open    # build build/HeyEQQ.app and launch it
```

The first launch asks for **System Audio Recording** permission. Builds are signed with your first
"Apple Development" identity, so the permission stays granted across rebuilds. Without one, the app is
signed ad hoc and macOS asks again after every build.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep changes focused: one feature or fix per pull request.
3. Add or update tests in `Tests/HeyEQQCoreTests` for DSP or model changes.
4. Make sure `swift test` passes and the app builds with `scripts/build-app.sh`.
5. Describe what you changed and how you tested it (especially by ear, for audio changes).

### Code guidelines

- The audio callback in `EQProcessor` runs on a real-time thread. Don't allocate, lock or call
  Objective-C/Swift runtime APIs there; pass parameters through the existing atomics and try-lock handoff.
- Pipeline and DSP code goes in `Sources/HeyEQQCore`; the UI goes in `Sources/HeyEQQ`.
- Keep the deployment target at macOS 15. Put newer APIs behind `if #available`.
- Follow the existing style: Swift 5 language mode, 4-space indentation, and doc comments on public API.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
