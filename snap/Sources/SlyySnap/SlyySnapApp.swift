import AppKit

// Menu bar only (LSUIElement + accessory policy): no Dock icon, no main window.
@main
enum SlyySnapApp {
    @MainActor
    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
