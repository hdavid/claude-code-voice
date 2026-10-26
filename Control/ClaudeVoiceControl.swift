import AppIntents
import SwiftUI
import WidgetKit

/// Control Center toggle "Claude voice": on = Claude speaks, off = muted.
/// It reads and writes the same `~/.claude/voice-muted` file as the menu bar icon and Claude itself.
@main
struct ClaudeVoiceControlBundle: WidgetBundle {
    var body: some Widget {
        ClaudeVoiceControl()
    }
}

struct ClaudeVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: MuteState.controlKind, provider: VoiceOnProvider()) { voiceOn in
            ControlWidgetToggle(isOn: voiceOn, action: SetClaudeVoiceIntent()) {
                Text("Claude voice")
            } valueLabel: { on in
                Label(on ? "On" : "Muted", systemImage: on ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .tint(.orange)
        }
        .displayName("Claude voice")
        .description("Mute or unmute Claude's spoken alerts.")
    }
}

struct VoiceOnProvider: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        !MuteState.isMuted
    }
}

/// Control Center calls this with the toggle's new value.
struct SetClaudeVoiceIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Claude voice"
    static let description = IntentDescription("Turns Claude's spoken alerts on or off.")

    @Parameter(title: "Voice on")
    var value: Bool

    func perform() async throws -> some IntentResult {
        try MuteState.setMuted(!value)
        return .result()
    }
}
