import AppKit
import CryptoKit
import Security

// Release feed: github.com/simplify-erp/slyy-releases, tags slyy-snap-vX.Y.Z,
// assets SlyySnap-X.Y.Z.zip + SHA256SUMS (see snap/scripts/build.sh).
private let releasesAPI = URL(string: "https://api.github.com/repos/simplify-erp/slyy-releases/releases?per_page=100")!
private let tagPrefix = "slyy-snap-v"
/// Developer ID team also accepted for updates (set before moving releases from the self-signed certificate to it).
private let allowedDeveloperTeam = ""
let installCommand = "curl -fsSL https://raw.githubusercontent.com/simplify-erp/slyy-releases/main/snap-install.sh | sh"

struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ s: String) {
        let comps = s.split(separator: ".", omittingEmptySubsequences: false)
        let parts = comps.compactMap { c in c.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(c) : nil }
        guard comps.count == 3, parts.count == 3 else { return nil }
        self.parts = parts
    }

    static func < (a: Version, b: Version) -> Bool {
        a.parts.lexicographicallyPrecedes(b.parts)
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static var current: Version {
        let s = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return Version(s) ?? Version("0.0.0")!
    }
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let assets: [GitHubAsset]
}

struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: URL
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Self-updater: newest release -> SHA-256 (SHA256SUMS), bundle id, version and signature checks -> swap in place, relaunch.
@MainActor
final class Updater {
    private var checking = false

    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        var req = URLRequest(url: releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result = Result<(GitHubRelease, Version)?, Error> {
                if let err { throw err }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200, let data else { throw UpdateError("GitHub answered HTTP \(status).") }
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                return releases.compactMap { r -> (GitHubRelease, Version)? in
                    guard !r.draft, !r.prerelease, r.tag_name.hasPrefix(tagPrefix),
                          let v = Version(String(r.tag_name.dropFirst(tagPrefix.count))) else { return nil }
                    return (r, v)
                }.max { $0.1 < $1.1 }
            }
            DispatchQueue.main.async {
                self.checking = false
                self.handle(result, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handle(_ result: Result<(GitHubRelease, Version)?, Error>, userInitiated: Bool) {
        let current = Version.current
        switch result {
        case .failure(let error):
            if userInitiated { Alerts.info("Update check failed", error.localizedDescription) }
        case .success(let found):
            guard let found, found.1 > current else {
                if userInitiated { Alerts.info("Slyy Shot is up to date", "Version \(current) is the newest.") }
                return
            }
            let (release, version) = found
            if !userInitiated, Settings.skippedVersion == version.description { return }
            let alert = NSAlert()
            alert.messageText = "Slyy Shot \(version) is available"
            let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            alert.informativeText = "You have \(current).\(notes.isEmpty ? "" : "\n\n" + String(notes.prefix(800)))"
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Skip This Version")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: install(release, version)
            case .alertThirdButtonReturn: Settings.skippedVersion = version.description
            default: break
            }
        }
    }

    private func install(_ release: GitHubRelease, _ version: Version) {
        let zipName = "SlyySnap-\(version).zip"
        guard let zipAsset = release.assets.first(where: { $0.name == zipName }),
              let sumsAsset = release.assets.first(where: { $0.name == "SHA256SUMS" }) else {
            Alerts.info("Update failed", "Release \(release.tag_name) has no \(zipName) or SHA256SUMS.")
            return
        }
        let app = Bundle.main.bundleURL
        let parent = app.deletingLastPathComponent()
        guard app.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else {
            Alerts.info("Cannot update in place", "No write access to \(parent.path). Update from Terminal:\n\n\(installCommand)")
            return
        }
        let zipURL = zipAsset.browser_download_url
        let sumsURL = sumsAsset.browser_download_url
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let staged = try Updater.downloadAndVerify(zip: zipURL, sums: sumsURL, zipName: zipName,
                                                           version: version.description)
                DispatchQueue.main.async { self.swapAndRelaunch(app: app, staged: staged) }
            } catch {
                DispatchQueue.main.async { Alerts.info("Update failed", error.localizedDescription) }
            }
        }
    }

    nonisolated static func downloadAndVerify(zip: URL, sums: URL, zipName: String, version: String) throws -> URL {
        let zipData = try Data(contentsOf: zip)
        let sumsText = String(decoding: try Data(contentsOf: sums), as: UTF8.self)
        let want = sumsText.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: " ")
            guard f.count == 2, f[1] == zipName || f[1] == "*" + zipName else { return nil }
            return f[0].lowercased()
        }.first
        guard let want else { throw UpdateError("SHA256SUMS lists no \(zipName).") }
        let got = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        guard got == want else { throw UpdateError("Checksum mismatch for \(zipName); nothing installed.") }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("slyy-snap-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zipFile = work.appendingPathComponent(zipName)
        try zipData.write(to: zipFile)
        let out = work.appendingPathComponent("x", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, out.path])
        let app = out.appendingPathComponent("Slyy Snap.app", isDirectory: true) // zip keeps the pre-1.3 name
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == "ai.slyy.snap",
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("The download is not Slyy Shot \(version); nothing installed.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        // Stable signature (self-signed or Developer ID): only accept updates satisfying our designated requirement.
        if let requirement = updateRequirement() {
            try verifySignature(of: app, requirement: requirement)
        }
        return app
    }

    /// Our designated requirement (+ allowed Developer ID team); nil when ad-hoc signed (a per-build hash).
    nonisolated static func updateRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        let own = text as String
        if own.hasPrefix("cdhash") { return nil }
        if allowedDeveloperTeam.isEmpty { return own }
        return "(\(own)) or (identifier \"ai.slyy.snap\" and anchor apple generic and certificate leaf[subject.OU] = \"\(allowedDeveloperTeam)\")"
    }

    nonisolated static func verifySignature(of app: URL, requirement text: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("Cannot read the signature of the download; nothing installed.")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("Internal error: bad signature requirement.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError("The download is not signed like this app (error \(status)); nothing installed.")
        }
    }

    nonisolated static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed (exit \(p.terminationStatus)).")
        }
    }

    /// Stage the new bundle next to the old one, then a detached script swaps them after we exit (rolls back on failure) and reopens.
    private func swapAndRelaunch(app: URL, staged: URL) {
        let fm = FileManager.default
        let next = URL(fileURLWithPath: app.path + ".new", isDirectory: true)
        do {
            try? fm.removeItem(at: next)
            try fm.moveItem(at: staged, to: next)
        } catch {
            Alerts.info("Update failed", error.localizedDescription)
            return
        }
        let script = """
        pid="$1"; old="$2"; new="$3"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        rm -rf "$old.previous"
        if mv "$old" "$old.previous"; then
          if mv "$new" "$old"; then rm -rf "$old.previous"; else mv "$old.previous" "$old"; fi
        fi
        open "$old"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "slyy-snap-update",
                       String(ProcessInfo.processInfo.processIdentifier), app.path, next.path]
        do {
            try p.run()
        } catch {
            Alerts.info("Update failed", error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    /// Remove leftovers of an interrupted update.
    func cleanUp() {
        let app = Bundle.main.bundleURL.path
        for leftover in [app + ".new", app + ".previous"] {
            try? FileManager.default.removeItem(atPath: leftover)
        }
    }
}
