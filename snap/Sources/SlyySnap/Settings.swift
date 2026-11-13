import Foundation

/// User preferences (UserDefaults domain ai.slyy.snap).
enum Settings {
    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            "copyToClipboard": true,
            "playSound": true,
            "autoUpdate": true,
        ])
    }

    /// Where snaps are saved. Default: ~/Pictures/Slyy Snap
    static var folder: URL {
        get {
            if let p = d.string(forKey: "folder"), !p.isEmpty {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
            return pictures.appendingPathComponent("Slyy Snap", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "folder") }
    }

    static var copyToClipboard: Bool {
        get { d.bool(forKey: "copyToClipboard") }
        set { d.set(newValue, forKey: "copyToClipboard") }
    }

    static var playSound: Bool {
        get { d.bool(forKey: "playSound") }
        set { d.set(newValue, forKey: "playSound") }
    }

    static var autoUpdate: Bool {
        get { d.bool(forKey: "autoUpdate") }
        set { d.set(newValue, forKey: "autoUpdate") }
    }

    static var skippedVersion: String? {
        get { d.string(forKey: "skippedVersion") }
        set { d.set(newValue, forKey: "skippedVersion") }
    }
}
