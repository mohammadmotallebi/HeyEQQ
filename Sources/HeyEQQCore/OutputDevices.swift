import CoreAudio
import Foundation

/// A physical (or user-created) audio device that can play sound.
public struct OutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    /// Total output channels across all output streams (2 for stereo, 6 for 5.1, 8 for 7.1 …).
    public let outputChannels: Int
    /// Channels of output stream 0, which a device-stream tap captures.
    public let firstStreamChannels: Int

    public var isMultichannel: Bool { firstStreamChannels > 2 }
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

    static func totalOutputChannels(_ id: AudioObjectID) -> Int {
        var addr = propertyAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size = id.dataSize(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        guard size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func firstStreamChannels(_ id: AudioObjectID) -> Int {
        var addr = propertyAddress(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size = id.dataSize(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return 0 }
        var streams = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr else { return 0 }
        let format = try? streams[0].read(kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
        return Int(format?.mChannelsPerFrame ?? 0)
    }

    private static func makeDevice(_ id: AudioObjectID) -> OutputDevice? {
        guard id.dataSize(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) > 0,
              let uid = try? id.readString(kAudioDevicePropertyDeviceUID),
              !uid.hasPrefix(ownAggregatePrefix) else { return nil }
        let name = (try? id.readString(kAudioObjectPropertyName)) ?? uid
        return OutputDevice(id: id, uid: uid, name: name,
                            outputChannels: totalOutputChannels(id), firstStreamChannels: firstStreamChannels(id))
    }
}
