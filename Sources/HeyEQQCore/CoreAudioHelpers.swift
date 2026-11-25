import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let what: String
    public init(status: OSStatus, what: String) { self.status = status; self.what = what }
    public var description: String {
        // Many Core Audio errors are four-char codes.
        let n = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
        return "\(what) failed: OSStatus \(status)\(fourCC)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status: status, what: what()) }
}

func propertyAddress(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

extension AudioObjectID {
    public static let system = AudioObjectID(kAudioObjectSystemObject)
    public static let unknown = AudioObjectID(kAudioObjectUnknown)

    /// Reads a fixed-size (POD) property.
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 initial: T) throws -> T {
        var addr = propertyAddress(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try withUnsafeMutableBytes(of: &value) {
            try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0.baseAddress!), "read property \(selector)")
        }
        return value
    }

    /// Reads a CFString property.
    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var addr = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try withUnsafeMutablePointer(to: &value) {
            try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0), "read string \(selector)")
        }
        guard let value else { throw CoreAudioError(status: -1, what: "nil string for \(selector)") }
        return value.takeRetainedValue() as String
    }

    /// Byte size of a variable-length property (0 on error).
    func dataSize(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var addr = propertyAddress(selector, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr ? size : 0
    }

    static func allDevices() throws -> [AudioObjectID] {
        var addr = propertyAddress(kAudioHardwarePropertyDevices)
        var size = AudioObjectID.system.dataSize(kAudioHardwarePropertyDevices)
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(.system, &addr, 0, nil, &size, &ids), "list devices")
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown)
    }

    /// Maps a Unix PID to its Core Audio process object (unknown if the process has no audio client).
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(.system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "translate PID to process object")
        return object
    }
}

/// Registers a Core Audio property listener for its lifetime.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    // Stored as the block type so add/remove see the *same* block object.
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue, handler: @escaping () -> Void) throws {
        self.object = object
        self.address = propertyAddress(selector, scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "add listener \(selector)")
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
