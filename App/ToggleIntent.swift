import AppIntents

/// "Toggle Claude voice" for Shortcuts and Spotlight, so the switch can also get a keyboard shortcut
/// (Shortcuts app: new shortcut with this action, then a hotkey in its details).
struct ToggleClaudeVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Claude voice"
    static let description = IntentDescription("Mutes Claude's spoken alerts when they are on, unmutes them when they are muted.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let muted = !MuteState.isMuted
        try MuteState.setMuted(muted)
        return .result(dialog: muted ? "Claude voice muted" : "Claude voice on")
    }
}
