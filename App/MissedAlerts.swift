import Foundation
import os

/// Sentences Claude did not speak because the voice was muted (by hand or by a call).
///
/// `voice-say` drops one file per silenced sentence in `~/.claude/voice-missed/` (`<epoch>-<pid>.txt`, the
/// sentence inside). The app takes them, flashes the menu bar icon red with the session's name, and keeps the last
/// few for the menu. The session's name is the sentence's subject: "Bose session: ..." gives "Bose session".
@MainActor
final class MissedAlerts {
    struct Missed {
        let session: String
        let sentence: String
        let date: Date
    }

    static let directoryURL = MuteState.directoryURL.appendingPathComponent("voice-missed", isDirectory: true)

    private static let keep = 5
    private static let flashes = 4
    private static let flashStep: TimeInterval = 0.35
    private static let longestSubject = 40

    /// Newest first.
    private(set) var recent: [Missed] = []
    /// The session shown next to the icon until the user clicks the icon (so it is still there after time away).
    private(set) var badge: String?
    /// True during the red half of a flash.
    private(set) var isRed = false
    var onChange: () -> Void = {}

    private let log = Logger(subsystem: "com.mots.claude-voice", category: "missed")
    private var watcher: DirectoryWatcher?
    private var flashTimer: Timer?
    private var flashCount = 0

    func start() {
        do {
            try FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
        } catch {
            log.error("cannot create \(Self.directoryURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        collect(flash: false)   // left from before the app started: listed, not flashed
        watcher = DirectoryWatcher(directory: Self.directoryURL) { [weak self] in self?.collect(flash: true) }
        if watcher == nil {
            log.error("cannot watch \(Self.directoryURL.path, privacy: .public)")
        }
    }

    /// The user has seen it: a click on the icon.
    func acknowledge() {
        guard badge != nil else { return }
        flashTimer?.invalidate()
        flashTimer = nil
        isRed = false
        badge = nil
        onChange()
    }

    /// Also called by the app's slow poll, in case a watcher event is missed.
    func collect(flash: Bool) {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: Self.directoryURL.path)
        } catch {
            return   // the folder is created at start; a missing one has nothing to show
        }
        let files = names.filter { $0.hasSuffix(".txt") }.sorted()
        guard !files.isEmpty else { return }
        var found: [Missed] = []
        for name in files {
            let url = Self.directoryURL.appendingPathComponent(name)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            do {
                try fm.removeItem(at: url)
            } catch {
                log.error("cannot remove \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            found.append(Self.missed(fileName: name, text: text))
        }
        recent = Array((found.reversed() + recent).prefix(Self.keep))
        if flash, let latest = found.last {
            badge = latest.session
            startFlash()
        }
        onChange()
    }

    static func missed(fileName: String, text: String) -> Missed {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let epoch = fileName.split(separator: "-").first.flatMap { Double($0) }
        let date = epoch.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return Missed(session: session(of: sentence), sentence: sentence, date: date)
    }

    /// "Bose session: the build is ready" gives "Bose session"; a sentence without a short subject gives "Claude".
    static func session(of sentence: String) -> String {
        guard let colon = sentence.firstIndex(of: ":") else { return "Claude" }
        let subject = sentence[..<colon].trimmingCharacters(in: .whitespaces)
        guard !subject.isEmpty, subject.count <= longestSubject else { return "Claude" }
        return subject
    }

    private func startFlash() {
        flashTimer?.invalidate()
        flashCount = 0
        isRed = true
        flashTimer = Timer.scheduledTimer(withTimeInterval: Self.flashStep, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.flashCount += 1
                let step = self.flashCount
                self.isRed = step % 2 == 0 && step < Self.flashes * 2
                if step >= Self.flashes * 2 {
                    timer.invalidate()
                    self.flashTimer = nil
                }
                self.onChange()
            }
        }
        onChange()
    }
}
