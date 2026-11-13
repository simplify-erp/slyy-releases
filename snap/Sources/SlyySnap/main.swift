import AppKit

// Menu bar only (LSUIElement + accessory policy): no Dock icon, no main window.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
