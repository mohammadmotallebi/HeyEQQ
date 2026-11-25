import AppKit
import HeyEQQCore

/// A user-facing app that is (or was) using audio, for the per-app EQ list.
struct AudioApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let icon: NSImage?
    let isPlaying: Bool
    let isRunning: Bool

    /// Groups Core Audio processes (incl. helpers like "…Chrome.helper") under their running app.
    static func current() -> [AudioApp] {
        let me = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != me
        }
        var playing: [String: Bool] = [:]
        for process in AudioProcessCatalog.all() {
            // Most specific running app this process belongs to.
            guard let owner = apps
                .compactMap(\.bundleIdentifier)
                .filter({ process.belongs(to: $0) })
                .max(by: { $0.count < $1.count }) else { continue }
            playing[owner] = (playing[owner] ?? false) || process.isRunningOutput
        }
        return playing.compactMap { bundleID, isPlaying in
            guard let app = apps.first(where: { $0.bundleIdentifier == bundleID }) else { return nil }
            return AudioApp(bundleID: bundleID, name: app.localizedName ?? bundleID, icon: app.icon,
                            isPlaying: isPlaying, isRunning: true)
        }
    }
}
