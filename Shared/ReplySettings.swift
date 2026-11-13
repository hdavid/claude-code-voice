import Foundation

/// Voice replies: after Claude asks a question with `voice-ask`, the app asks "Reply?" and takes a dictated answer.
///
/// All state is files under `~/.claude`, so `voice-ask` (a shell script) and the app read the same switches:
/// - `voice-replies`              exists: voice replies are on (off by default: the microphone is never used unasked)
/// - `voice-reply-no-readback`    exists: send the dictation without reading it back first
/// - `voice-ask/<id>.ask`         a pending question, written by `voice-ask`
/// - `voice-ask/<id>.reply`       the confirmed answer, written by the app
/// - `voice-ask/<id>.none`        no answer, with the reason, written by the app
enum ReplySettings {
    static let enabledURL = MuteState.directoryURL.appendingPathComponent("voice-replies", isDirectory: false)
    static let noReadbackURL = MuteState.directoryURL.appendingPathComponent("voice-reply-no-readback", isDirectory: false)
    static let requestsURL = MuteState.directoryURL.appendingPathComponent("voice-ask", isDirectory: true)

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: enabledURL.path) }
    static var readsBack: Bool { !FileManager.default.fileExists(atPath: noReadbackURL.path) }

    static func setEnabled(_ on: Bool) throws {
        try setFlag(enabledURL, present: on)
    }

    static func setReadsBack(_ on: Bool) throws {
        try setFlag(noReadbackURL, present: !on)
    }

    private static func setFlag(_ url: URL, present: Bool) throws {
        let fm = FileManager.default
        if present {
            guard !fm.fileExists(atPath: url.path) else { return }
            try fm.createDirectory(at: MuteState.directoryURL, withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } else if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
