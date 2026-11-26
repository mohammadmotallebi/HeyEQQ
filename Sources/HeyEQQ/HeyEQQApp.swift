import AppKit
import SwiftUI

@main
struct HeyEQQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(active: model.enabled && !model.bypassed && model.blockedDevice == nil)
        }
        .menuBarExtraStyle(.window)

        Window("HeyEQQ Equalizer", id: EqualizerWindow.windowID) {
            EqualizerWindow(model: model)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        // Restore normal system audio on logout/restart, not just via the Quit button.
        MainActor.assumeIsolated { Self.model?.shutdownEngine() }
    }
}

/// The equalizer glyph from Support/MenuBarIcon.png (template, so macOS tints it); dimmed when
/// off or bypassed. Falls back to an SF Symbol when run outside the app bundle.
private struct MenuBarLabel: View {
    let active: Bool

    private static let glyph: NSImage? = {
        guard let image = NSImage(named: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    var body: some View {
        Group {
            if let glyph = Self.glyph {
                Image(nsImage: glyph)
            } else {
                Image(systemName: "slider.vertical.3")
            }
        }
        .opacity(active ? 1 : 0.4)
        .accessibilityLabel(active ? "HeyEQQ (on)" : "HeyEQQ (off)")
    }
}
