import Foundation

/// The one fact the menu bar icon and the Control Center toggle both act on.
///
/// Claude's spoken alerts are muted while `~/.claude/voice-muted` exists: every `say` in a Claude session
/// is guarded by `[ -e ~/.claude/voice-muted ]` (see ~/.claude/rules/common/voice-alerts.md). Claude itself
/// creates and removes the same file on "mute" / "unmute", so both sides share one switch.
enum MuteState {
    /// The Control Center control's kind, so the app can ask WidgetKit to redraw it after a change.
    static let controlKind = "io.github.hdavid.claude-code-voice.control.voice"

    /// `~/.claude`, under the real home directory (a sandbox container has its own, wrong, home).
    static let directoryURL: URL = realHomeDirectory().appendingPathComponent(".claude", isDirectory: true)

    static let fileURL: URL = directoryURL.appendingPathComponent("voice-muted", isDirectory: false)

    static var isMuted: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Creates or removes the mute file. Already in the asked-for state is not an error.
    static func setMuted(_ muted: Bool) throws {
        let fm = FileManager.default
        if muted {
            guard !isMuted else { return }
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            // Plain create, not an atomic write: the sandboxed control may only touch ~/.claude itself,
            // and an atomic write goes through a temporary file elsewhere.
            guard fm.createFile(atPath: fileURL.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        } else {
            guard isMuted else { return }
            try fm.removeItem(at: fileURL)
        }
    }

    private static func realHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
