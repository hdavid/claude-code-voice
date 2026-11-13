import AppKit
import os

/// Answers `voice-ask` requests: speaks Claude's question, asks "Reply?", takes the dictation, reads it back and
/// sends it on "send". One request at a time; `voice-ask` holds the voice lock meanwhile, so no other session talks.
@MainActor
final class VoiceReplies {
    private let log = Logger(subsystem: "com.mots.claude-voice", category: "replies")
    private let speaker = Speaker()
    private let listener = Listener(localeIdentifier: "en-US")
    private var watcher: DirectoryWatcher?
    private var busy = false

    private static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "reply", "ok", "okay"]
    private static let noWords: Set<String> = ["no", "nope", "later", "skip", "nah"]
    private static let sendWords: Set<String> = ["send", "yes", "ok", "okay", "submit", "go"]
    private static let redoWords: Set<String> = ["redo", "again", "repeat", "retry"]
    private static let cancelWords: Set<String> = ["cancel", "no", "stop", "abort"]

    func start() {
        try? FileManager.default.createDirectory(at: ReplySettings.requestsURL, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(directory: ReplySettings.requestsURL) { [weak self] in self?.poll() }
        if watcher == nil {
            log.error("cannot watch \(ReplySettings.requestsURL.path, privacy: .public)")
        }
        poll()
    }

    /// Called on every change in the requests folder (and by the app's slow timer): takes the oldest open request.
    func poll() {
        guard !busy, let request = nextRequest() else { return }
        busy = true
        Task {
            await answer(request)
            busy = false
            poll()
        }
    }

    private func nextRequest() -> URL? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: ReplySettings.requestsURL, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "ask" }
            .filter { !fm.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("reply").path)
                && !fm.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("none").path) }
            .min { created($0) < created($1) }
    }

    private func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    // MARK: - One exchange

    private func answer(_ request: URL) async {
        let question = (try? String(contentsOf: request, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let outcome: Outcome
        do {
            outcome = try await converse(question, request: request)
        } catch {
            log.error("voice reply failed: \(error.localizedDescription, privacy: .public)")
            outcome = .none(error.localizedDescription)
        }
        write(outcome, for: request)
    }

    private enum Outcome {
        case reply(String)
        case none(String)
    }

    private func converse(_ question: String, request: URL) async throws -> Outcome {
        func gone() -> Bool { !FileManager.default.fileExists(atPath: request.path) || MuteState.isMuted }
        try await listener.authorize()
        if !question.isEmpty { await speaker.say(question) }
        if gone() { return .none("cancelled by Claude or muted") }

        await speaker.say("Reply?")
        let consent = spokenWords(try await listener.listen(.init(noSpeech: 6, silence: 1.2, maximum: 8)) {
            !spokenWords($0).isDisjoint(with: Self.yesWords.union(Self.noWords))
        })
        guard !consent.isDisjoint(with: Self.yesWords), consent.isDisjoint(with: Self.noWords) else {
            return .none(consent.isEmpty ? "no answer to \"Reply?\"" : "declined")
        }

        while !gone() {
            speaker.cue("Tink")
            let text = try await listener.listen(.init(noSpeech: 10, silence: 2.2, maximum: 120))
            guard !text.isEmpty else { return .none("nothing heard") }
            guard ReplySettings.readsBack else { return .reply(text) }

            switch try await confirm(text) {
            case .send: return .reply(text)
            case .redo: await speaker.say("Go ahead.")
            case .cancel: return .none("cancelled")
            }
        }
        return .none("cancelled by Claude or muted")
    }

    private enum Decision { case send, redo, cancel }

    private func confirm(_ text: String) async throws -> Decision {
        await speaker.say("You said: \(text). Send, redo, or cancel?")
        let all = Self.sendWords.union(Self.redoWords).union(Self.cancelWords)
        for attempt in 0..<2 {
            if attempt > 0 { await speaker.say("Send, redo, or cancel?") }
            let words = spokenWords(try await listener.listen(.init(noSpeech: 6, silence: 1.2, maximum: 8)) {
                !spokenWords($0).isDisjoint(with: all)
            })
            // Cancel and redo win over a stray "yes"/"ok" in the same answer.
            if !words.isDisjoint(with: Self.cancelWords) { return .cancel }
            if !words.isDisjoint(with: Self.redoWords) { return .redo }
            if !words.isDisjoint(with: Self.sendWords) { return .send }
        }
        return .cancel
    }

    /// The answer file, written atomically so `voice-ask` never reads half of it.
    private func write(_ outcome: Outcome, for request: URL) {
        guard FileManager.default.fileExists(atPath: request.path) else { return }   // voice-ask gave up already
        let (ext, body): (String, String) = switch outcome {
        case .reply(let text): ("reply", text)
        case .none(let reason): ("none", reason)
        }
        let url = request.deletingPathExtension().appendingPathExtension(ext)
        do {
            try Data((body + "\n").utf8).write(to: url, options: .atomic)
        } catch {
            log.error("cannot write \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
