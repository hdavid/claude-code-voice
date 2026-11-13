import AVFoundation
import Speech
import os

/// Listens on the microphone and transcribes on this Mac (on-device recognition: no audio leaves the computer).
@MainActor
final class Listener {
    enum Failure: LocalizedError {
        case microphoneDenied, recognitionDenied, recognizerUnavailable, audio(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "microphone access denied (System Settings > Privacy & Security > Microphone)"
            case .recognitionDenied: return "speech recognition denied (System Settings > Privacy & Security > Speech Recognition)"
            case .recognizerUnavailable: return "on-device speech recognition is not available for this language"
            case .audio(let detail): return "microphone could not start: \(detail)"
            }
        }
    }

    /// How a listening pass ends.
    struct Limits {
        var noSpeech: TimeInterval     // nothing heard at all for this long: give up
        var silence: TimeInterval      // after some speech, quiet for this long: done
        var maximum: TimeInterval      // hard stop
    }

    private let recognizer: SFSpeechRecognizer?
    private let log = Logger(subsystem: "com.mots.claude-voice", category: "listen")

    init(localeIdentifier: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    func authorize() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphoneDenied }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure.recognitionDenied }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw Failure.recognizerUnavailable
        }
    }

    /// Transcribes until the limits end it, or until `isDone` accepts the text so far. Returns the text heard.
    func listen(_ limits: Limits, isDone: (String) -> Bool = { _ in false }) async throws -> String {
        guard let recognizer else { throw Failure.recognizerUnavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let level = Level()
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
            level.add(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.audio(error.localizedDescription)
        }

        let heard = Heard()
        let task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            Task { @MainActor in
                heard.callbacks += 1
                if let text { heard.update(text) }
                if let error { heard.fail(error) }
                if final || error != nil { heard.ended = true }
            }
        }

        let start = Date()
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            let now = Date()
            if heard.text.isEmpty {
                if now.timeIntervalSince(start) > limits.noSpeech { break }
            } else if isDone(heard.text) || now.timeIntervalSince(heard.changed) > limits.silence {
                break
            }
            if now.timeIntervalSince(start) > limits.maximum { break }
        }
        // Documented teardown: stop the audio, end the request, and let the task deliver its final result before
        // the next pass starts. Cancelling a running task straight away left the next pass with no results at all.
        engine.stop()
        input.removeTap(onBus: 0)
        request.endAudio()
        let ending = Date()
        while !heard.ended, Date().timeIntervalSince(ending) < 2 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()

        let (buffers, peak) = level.snapshot()
        log.info("listened \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public) s: \(buffers, privacy: .public) buffers, peak \(peak, format: .fixed(precision: 4), privacy: .public), \(heard.callbacks, privacy: .public) results, final \(heard.ended, privacy: .public), heard \(heard.text.count, privacy: .public) chars, error \(heard.error ?? "none", privacy: .public)")
        return heard.text
    }

    /// The latest partial transcription and when it last changed.
    @MainActor
    private final class Heard {
        private(set) var text = ""
        private(set) var changed = Date()
        private(set) var error: String?
        var callbacks = 0
        var ended = false

        func fail(_ error: Error) {
            self.error = error.localizedDescription
        }

        func update(_ next: String) {
            guard next != text else { return }
            text = next
            changed = Date()
        }
    }
}

/// Counts microphone buffers and the loudest sample, to tell "no sound" from "not recognised" in the log.
private final class Level: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var peak: Float = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        var loudest: Float = 0
        for i in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(samples[i])) }
        lock.lock()
        buffers += 1
        peak = max(peak, loudest)
        lock.unlock()
    }

    func snapshot() -> (Int, Float) {
        lock.lock()
        defer { lock.unlock() }
        return (buffers, peak)
    }
}

/// Lower-case words of a transcription, for matching spoken keywords ("Yes.", "send it" ...).
func spokenWords(_ text: String) -> Set<String> {
    Set(text.lowercased().split { !$0.isLetter }.map(String.init))
}
