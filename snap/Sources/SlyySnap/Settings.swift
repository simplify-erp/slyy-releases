import Foundation

/// User preferences (UserDefaults domain ai.slyy.snap).
enum Settings {
    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            "copyToClipboard": true,
            "playSound": true,
            "autoUpdate": true,
            "openEditor": false,
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

    /// Open the editor right after each capture (otherwise: floating thumbnail
    /// with an Edit button).
    static var openEditor: Bool {
        get { d.bool(forKey: "openEditor") }
        set { d.set(newValue, forKey: "openEditor") }
    }

    static var autoUpdate: Bool {
        get { d.bool(forKey: "autoUpdate") }
        set { d.set(newValue, forKey: "autoUpdate") }
    }

    /// Screen Recording was granted at some point (detects a grant lost by an update).
    static var hadScreenAccess: Bool {
        get { d.bool(forKey: "hadScreenAccess") }
        set { d.set(newValue, forKey: "hadScreenAccess") }
    }

    /// Highest snap number used (slyy-NNNNN.png).
    static var lastSnapNumber: Int {
        get { d.integer(forKey: "lastSnapNumber") }
        set { d.set(newValue, forKey: "lastSnapNumber") }
    }

    static var skippedVersion: String? {
        get { d.string(forKey: "skippedVersion") }
        set { d.set(newValue, forKey: "skippedVersion") }
    }
}
