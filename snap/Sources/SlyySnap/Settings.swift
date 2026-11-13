import Foundation

/// User preferences (UserDefaults domain ai.slyy.snap).
enum Settings {
    private static var d: UserDefaults { .standard }

    /// Where snaps are saved. Default: ~/Pictures/Slyy Shot
    static var folder: URL {
        get {
            if let p = d.string(forKey: "folder"), !p.isEmpty {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
            return pictures.appendingPathComponent("Slyy Shot", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "folder") }
    }

    @Pref("copyToClipboard", true) static var copyToClipboard: Bool
    @Pref("playSound", true) static var playSound: Bool
    /// Open the editor right after each capture (otherwise: floating thumbnail with an Edit button).
    @Pref("openEditor", false) static var openEditor: Bool
    @Pref("autoUpdate", true) static var autoUpdate: Bool
    /// Screen Recording was granted at some point (detects a grant lost by an update).
    @Pref("hadScreenAccess", false) static var hadScreenAccess: Bool
    /// Highest snap number used (slyy-NNNNN.png).
    @Pref("lastSnapNumber", 0) static var lastSnapNumber: Int
    @Pref("cleanupAskedVersion", "") static var cleanupAskedVersion: String
    @Pref("skippedVersion", nil) static var skippedVersion: String?
}

/// A UserDefaults value with its default.
@propertyWrapper
struct Pref<T> {
    let key: String
    let fallback: T
    init(_ key: String, _ fallback: T) { self.key = key; self.fallback = fallback }
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? fallback }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
