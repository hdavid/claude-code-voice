import Foundation
import os

/// Is a newer Claude Voice out? Asks GitHub for the latest release (drafts and pre-releases are skipped there).
/// Any failure (offline, rate limited, an unexpected answer) reads as "no update": a check that cannot tell stays
/// quiet rather than nag. Same rules as Track Kommander's update check.
enum UpdateCheck {
    static let repo = "hdavid/claude-code-voice"
    static let latestAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    /// Known in advance, so it can be trusted where an address out of a network answer cannot.
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases")!
    /// A download anywhere else is never offered for installing.
    static let downloadsPrefix = "https://github.com/\(repo)/releases/download/"

    /// UserDefaults key; on unless the user switched it off.
    static let settingKey = "checkForUpdates"

    struct Asset: Equatable {
        let name: String     // "Claude-Voice-v1.4.0.zip"
        let url: URL         // under downloadsPrefix
        let sha256: String   // hex, GitHub's own digest of the upload
    }

    struct Release: Equatable {
        let version: String  // the tag without its "v"
        let page: URL        // the release's page, or the releases page
        let zip: Asset?      // nil: only the page can be offered
    }

    private static let log = Logger(subsystem: "com.mots.claude-voice", category: "update")

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// "v1.2.0" → [1, 2]; trailing zeros dropped so "1.2" == "1.2.0". Nil when it does not start with a version.
    static func parse(_ version: String) -> [Int]? {
        var text = Substring(version.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("v") { text = text.dropFirst() }
        let head = text.prefix { $0.isNumber || $0 == "." }
        var parts = head.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == head.split(separator: ".", omittingEmptySubsequences: false).count else {
            return nil
        }
        while parts.last == 0 { parts.removeLast() }
        return parts
    }

    /// True when `latest` is later than `current`. An unparseable `current` is never older, so it never prompts.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let new = parse(latest), let cur = parse(current) else { return false }
        for (a, b) in zip(new, cur) where a != b { return a > b }
        return new.count > cur.count
    }

    /// The release described by GitHub's JSON, or nil when the answer is not what is expected.
    static func release(from json: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tag = object["tag_name"] as? String, parse(tag) != nil else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let page = releasePage(object["html_url"] as? String)
        return Release(version: version, page: page, zip: pickZip(object["assets"]))
    }

    /// The app's zip among the release's files, with an address under our downloads and a sha256 digest.
    static func pickZip(_ assets: Any?) -> Asset? {
        guard let list = assets as? [[String: Any]] else { return nil }
        for asset in list {
            guard let name = asset["name"] as? String,
                  name.hasPrefix("Claude-Voice-"), name.hasSuffix(".zip") else { continue }
            let address = asset["browser_download_url"] as? String ?? ""
            let digest = (asset["digest"] as? String ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            guard address.hasPrefix(downloadsPrefix), let url = URL(string: address),
                  digest.count == 2, digest[0] == "sha256", digest[1].count == 64,
                  digest[1].allSatisfy(\.isHexDigit) else {
                log.warning("update: \(name, privacy: .public) not usable (\(address, privacy: .public))")
                return nil
            }
            return Asset(name: name, url: url, sha256: digest[1].lowercased())
        }
        return nil
    }

    /// `address` when it is an https page of our releases, else the releases page.
    static func releasePage(_ address: String?) -> URL {
        guard let address, let url = URL(string: address), url.scheme == "https", url.host == "github.com",
              url.path == releasesPage.path || url.path.hasPrefix(releasesPage.path + "/") else {
            return releasesPage
        }
        return url
    }

    /// The latest release when it is newer than the running app, else nil.
    static func fetchNewer() async -> Release? {
        var request = URLRequest(url: latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeVoice-update-check", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let latest = release(from: data) else {
                log.info("update: no usable answer")
                return nil
            }
            guard isNewer(latest.version, than: currentVersion) else {
                log.info("update: \(currentVersion, privacy: .public) is current")
                return nil
            }
            log.info("update: \(latest.version, privacy: .public) available")
            return latest
        } catch {
            log.info("update: no answer (\(error.localizedDescription, privacy: .public))")
            return nil
        }
    }
}
