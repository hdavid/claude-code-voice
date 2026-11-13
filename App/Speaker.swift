import AppKit

/// Speaks a sentence the way `voice-say` does (the system voice through `say`, at Claude's own volume) and returns
/// when it has finished playing, so the app can listen right after without hearing itself.
@MainActor
final class Speaker: NSObject, NSSoundDelegate {
    private var finished: CheckedContinuation<Void, Never>?
    private var sound: NSSound?

    func say(_ text: String) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-voice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return
        }
        let file = dir.appendingPathComponent("s.aiff")
        guard await render(text, to: file), let next = NSSound(contentsOf: file, byReference: false) else { return }
        next.volume = Float(VoiceVolume.percent) / 100
        next.delegate = self
        sound = next
        await withCheckedContinuation { continuation in
            finished = continuation
            if !next.play() {
                finish()
            }
        }
    }

    /// A short system sound (the "listening now" cue), at Claude's volume, without waiting for it.
    func cue(_ name: NSSound.Name) {
        guard let cue = NSSound(named: name)?.copy() as? NSSound else { return }
        cue.volume = Float(VoiceVolume.percent) / 100
        cue.play()
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor in self.finish() }
    }

    private func finish() {
        finished?.resume()
        finished = nil
        sound = nil
    }

    private func render(_ text: String, to file: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-o", file.path, "--", text]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
