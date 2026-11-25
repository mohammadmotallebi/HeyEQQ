import AppKit
import Carbon.HIToolbox

/// A key combination for a system-wide shortcut. Modifiers use Carbon's flags (cmdKey, optionKey…).
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// What to show for the key itself: "E", "←", "F5".
    var keyLabel: String

    /// ⌥⌘E
    static let defaultBypass = Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(optionKey | cmdKey), keyLabel: "E")

    /// "⌃⌥⇧⌘E", in the order macOS menus use.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    private static let specialKeys: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// From a key-down event. Returns nil unless ⌘, ⌥ or ⌃ is held (function keys work alone), so a
    /// shortcut can never swallow ordinary typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = Int(event.keyCode)
        let isFunctionKey = Self.specialKeys[code]?.hasPrefix("F") == true
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 || isFunctionKey else { return nil }
        let label = Self.specialKeys[code]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: carbon, keyLabel: label)
    }
}

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey.
/// Unlike global key monitors, this needs no Accessibility permission. Main thread only.
@MainActor
final class GlobalHotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// Returns nil if the combination is already taken (by another app or another HeyEQQ shortcut).
    init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4845_5151), id: id) // 'HEQQ'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, hotKeyRef != nil else { return nil }
        Self.actions[id] = action
    }

    /// Stops listening. (Not done in deinit: deinit isn't main-actor isolated.)
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        Self.actions[id] = nil
    }

    /// One handler for all shortcuts; it looks the pressed one up by id.
    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let id = pressed.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
