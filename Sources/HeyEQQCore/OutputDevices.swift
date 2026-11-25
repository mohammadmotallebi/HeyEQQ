import CoreAudio
import Foundation

/// A physical (or user-created) audio device that can play sound.
public struct OutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
}

public enum OutputDeviceCatalog {
    /// UID prefix of our own private aggregate devices, which must never be offered as outputs.
    static let ownAggregatePrefix = "com.heyeqq.aggregate."

    public static func outputDevices() -> [OutputDevice] {
        let ids = (try? AudioObjectID.allDevices()) ?? []
        return ids.compactMap(makeDevice).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func device(uid: String) -> OutputDevice? {
        outputDevices().first { $0.uid == uid }
    }

    public static func defaultOutput() -> OutputDevice? {
        guard let id = try? AudioObjectID.defaultOutputDevice(), id != .unknown else { return nil }
        return makeDevice(id)
    }

    private static func makeDevice(_ id: AudioObjectID) -> OutputDevice? {
        guard id.dataSize(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) > 0,
              let uid = try? id.readString(kAudioDevicePropertyDeviceUID),
              !uid.hasPrefix(ownAggregatePrefix) else { return nil }
        let name = (try? id.readString(kAudioObjectPropertyName)) ?? uid
        return OutputDevice(id: id, uid: uid, name: name)
    }
}
