import CoreAudio
import Foundation

/// A process connected to the audio system (Core Audio "process object").
public struct AudioProcess: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    /// Empty for processes without a bundle (command-line tools).
    public let bundleID: String
    /// Currently playing audio.
    public let isRunningOutput: Bool

    /// True if this process belongs to the app with `appBundleID`, including its helpers
    /// (e.g. `com.google.Chrome.helper` belongs to `com.google.Chrome`).
    public func belongs(to appBundleID: String) -> Bool {
        !bundleID.isEmpty && (bundleID == appBundleID || bundleID.hasPrefix(appBundleID + "."))
    }
}

public enum AudioProcessCatalog {
    public static func all() -> [AudioProcess] {
        var addr = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size = AudioObjectID.system.dataSize(kAudioHardwarePropertyProcessObjectList)
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(.system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { id in
            guard let pid = try? id.read(kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0, pid != me else { return nil }
            let bundleID = (try? id.readString(kAudioProcessPropertyBundleID)) ?? ""
            let running = ((try? id.read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running)
        }
    }

    /// Process objects belonging to each app bundle ID (apps with no audio process are omitted).
    public static func processes(for appBundleIDs: some Collection<String>,
                                 in processes: [AudioProcess] = all()) -> [String: [AudioObjectID]] {
        var result: [String: [AudioObjectID]] = [:]
        for app in appBundleIDs {
            // A process belongs to the most specific matching app (avoids double capture if rules nest).
            let ids = processes.filter { p in
                p.belongs(to: app) && !appBundleIDs.contains { other in
                    other != app && other.count > app.count && p.belongs(to: other)
                }
            }.map(\.objectID)
            if !ids.isEmpty { result[app] = ids.sorted() }
        }
        return result
    }
}
