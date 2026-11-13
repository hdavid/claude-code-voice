import Foundation

/// How loud Claude speaks, relative to the Mac's own output volume: 5 to 100 percent.
///
/// Kept in `~/.claude/voice-volume` as one integer, which `voice-say` reads at the moment a sentence plays and hands
/// to `afplay -v`, so only Claude's voice (and its chime) changes, never the system volume. No file means 100.
enum VoiceVolume {
    static let minimum = 5
    static let maximum = 100

    static let fileURL: URL = MuteState.directoryURL.appendingPathComponent("voice-volume", isDirectory: false)

    /// The stored percentage, clamped; 100 when the file is missing or unreadable.
    static var percent: Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return maximum
        }
        return clamp(value)
    }

    /// Writes the percentage (clamped). Atomic, so `voice-say` never reads a half-written number.
    static func setPercent(_ value: Int) throws {
        try FileManager.default.createDirectory(at: MuteState.directoryURL, withIntermediateDirectories: true)
        try Data("\(clamp(value))\n".utf8).write(to: fileURL, options: .atomic)
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, minimum), maximum)
    }
}
