import Darwin
import Foundation
import HeyEQQCore

// HeyEQQ spike: system-wide 3-band EQ via Core Audio process tap.
// Keys: 1/2 bass -/+, 3/4 mid -/+, 5/6 treble -/+, 0 reset, space bypass, q quit.

setvbuf(stdout, nil, _IONBF, 0)

// Raw terminal mode for single-key controls.
var originalTermios = termios()
let isTTY = isatty(STDIN_FILENO) != 0
if isTTY {
    tcgetattr(STDIN_FILENO, &originalTermios)
    var raw = originalTermios
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}

nonisolated(unsafe) var tap: SystemAudioTap?

func shutdown(_ code: Int32 = 0) -> Never {
    tap?.stop()
    if isTTY { tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios) }
    print("\nHeyEQQ spike stopped. System audio restored.")
    exit(code)
}

// Signal handlers run on their own queue so Ctrl-C works even while start() is
// blocked waiting for the System Audio Recording permission prompt.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalQueue = DispatchQueue(label: "heyeqq.signals")
let signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    s.setEventHandler { shutdown() }
    s.resume()
    return s
}

let others = InstanceGuard.otherInstances()
if !others.isEmpty {
    print("❌ Another HeyEQQ is running: \(others.map(\.description).joined(separator: ", ")).")
    print("   Two copies capture each other's audio and feed back into silence. Quit it first.")
    shutdown(1)
}

print("Starting… if macOS asks for \"System Audio Recording\" permission, click Allow.")
do {
    let t = try SystemAudioTap()
    tap = t
    try t.start()
    print("Output device : \(t.outputDevice.name)")
    if let p = t.processor {
        print("Sample rate   : \(Int(p.sampleRate)) Hz, tap channels: \(p.tapChannelCount)")
    }
    if !t.excludedSelf { print("⚠️  Could not resolve own process object; feedback is possible.") }
} catch {
    print("❌ \(error)")
    shutdown(1)
}
let eq = tap!.processor!

// Bass / mid / treble in dB, mapped onto the Simple-mode 3-band curve.
nonisolated(unsafe) var gains: [Double] = [0, 0, 0]
func setGain(_ i: Int, _ db: Double) {
    gains[i] = min(max(db, EQCurve.gainRange.lowerBound), EQCurve.gainRange.upperBound)
    eq.setCurve(.simple(gains))
}

func fmt(_ db: Double) -> String { String(format: "%+5.1f", db) }

func render() {
    let peak = Double(eq.inputPeak.exchange(0, ordering: .relaxed)) / 1000
    let bars = Int((min(peak, 1) * 20).rounded())
    let meter = String(repeating: "█", count: bars) + String(repeating: "·", count: 20 - bars)
    let state = eq.bypass.load(ordering: .relaxed) ? "BYPASS" : "EQ ON "
    print("\r[\(state)] Bass \(fmt(gains[0])) | Mid \(fmt(gains[1])) | Treble \(fmt(gains[2])) dB  in \(meter) ",
          terminator: "")
}

print("""

Keys: 1/2 bass -/+   3/4 mid -/+   5/6 treble -/+   0 reset   space bypass   q quit
Play some music. If the meter stays at zero while audio plays, grant
"System Audio Recording" to your terminal app in System Settings › Privacy & Security.

""")

// Start with an obvious bass boost so the effect is audible immediately.
setGain(0, 6)

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(100))
timer.setEventHandler(handler: render)
timer.resume()

Thread.detachNewThread {
    var byte: UInt8 = 0
    while read(STDIN_FILENO, &byte, 1) == 1 {
        let key = Character(UnicodeScalar(byte))
        DispatchQueue.main.async {
            let step = 1.0
            switch key {
            case "1": setGain(0, gains[0] - step)
            case "2": setGain(0, gains[0] + step)
            case "3": setGain(1, gains[1] - step)
            case "4": setGain(1, gains[1] + step)
            case "5": setGain(2, gains[2] - step)
            case "6": setGain(2, gains[2] + step)
            case "0": (0..<3).forEach { setGain($0, 0) }
            case " ": eq.bypass.store(!eq.bypass.load(ordering: .relaxed), ordering: .relaxed)
            case "q", "Q": shutdown()
            default: break
            }
            render()
        }
    }
    // stdin closed (non-interactive run): keep running until a signal arrives.
}

withExtendedLifetime((signalSources, timer)) { dispatchMain() }
