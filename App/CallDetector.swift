import AppKit
import CoreAudio
import os

/// Mutes Claude while a call app has the microphone (Teams, Slack huddle, Zoom, Meet in a browser...).
///
/// "Any app uses the mic" is not enough: Ableton Live and other audio apps keep the input open all day. So only the
/// apps listed in `~/.claude/voice-call-apps` count, matched on the bundle ID of the process that holds the input
/// (CoreAudio reports helpers too: a Teams call runs in `com.microsoft.teams2.modulehost`, measured 2026-11-23).
///
/// Files under `~/.claude`, read by `voice-say` and `voice-ask`:
/// - `voice-in-call`          exists while a listed app uses the mic; holds that app's name
/// - `voice-call-mute-off`    exists: the "Mute during calls" menu item is off
/// - `voice-call-apps`        the list: one bundle ID prefix and a display name per line
@MainActor
final class CallDetector {
    static let inCallURL = MuteState.directoryURL.appendingPathComponent("voice-in-call", isDirectory: false)
    static let offURL = MuteState.directoryURL.appendingPathComponent("voice-call-mute-off", isDirectory: false)
    static let appsURL = MuteState.directoryURL.appendingPathComponent("voice-call-apps", isDirectory: false)

    /// How often the microphone's users are checked. One pass reads a few properties of each audio process.
    private static let interval: TimeInterval = 2

    static var isEnabled: Bool { !FileManager.default.fileExists(atPath: offURL.path) }

    /// The call app's name while Claude is silenced by a call, nil otherwise.
    private(set) var callApp: String?
    var onChange: () -> Void = {}

    private let log = Logger(subsystem: "com.mots.claude-voice", category: "calls")
    private var timer: Timer?
    private var started = false

    func start() {
        writeDefaultListIfMissing()
        started = true
        poll(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(force: false) }
        }
    }

    /// On quit: no call file left behind (voice-say also ignores it while the app is not running).
    func stop() {
        timer?.invalidate()
        timer = nil
        apply(nil)
    }

    func setEnabled(_ on: Bool) throws {
        let fm = FileManager.default
        if on {
            if fm.fileExists(atPath: Self.offURL.path) { try fm.removeItem(at: Self.offURL) }
        } else if !fm.fileExists(atPath: Self.offURL.path) {
            guard fm.createFile(atPath: Self.offURL.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: Self.offURL.path])
            }
        }
        poll(force: true)
    }

    private func poll(force: Bool) {
        guard started else { return }
        let app = Self.isEnabled ? detectCall() : nil
        guard force || app != callApp else { return }
        apply(app)
    }

    private func apply(_ app: String?) {
        let changed = app != callApp
        callApp = app
        do {
            if let app {
                try Data((app + "\n").utf8).write(to: Self.inCallURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: Self.inCallURL.path) {
                try FileManager.default.removeItem(at: Self.inCallURL)
            }
        } catch {
            log.error("call file \(Self.inCallURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        if changed {
            log.info("call: \(app ?? "none", privacy: .public)")
            onChange()
        }
    }

    // MARK: - Who has the mic

    /// The display name of the first listed app that is capturing audio input, if any.
    private func detectCall() -> String? {
        let rules = Self.readList()
        guard !rules.isEmpty else { return nil }
        for process in Self.audioProcesses() where Self.uint32(process, kAudioProcessPropertyIsRunningInput) == 1 {
            guard let bundle = Self.string(process, kAudioProcessPropertyBundleID)?.lowercased() else { continue }
            if let rule = rules.first(where: { bundle.hasPrefix($0.prefix) }) {
                return rule.name
            }
        }
        return nil
    }

    private static func audioProcesses() -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - The list

    struct Rule: Equatable {
        let prefix: String
        let name: String
    }

    /// Parses the list: `<bundle ID prefix> <name>` per line, `#` starts a comment. Read on every poll, so an edit
    /// takes effect within two seconds.
    static func parse(_ text: String) -> [Rule] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let words = content.split(whereSeparator: \.isWhitespace)
            guard let prefix = words.first else { return nil }
            let name = words.dropFirst().joined(separator: " ")
            return Rule(prefix: prefix.lowercased(), name: name.isEmpty ? String(prefix) : name)
        }
    }

    private static func readList() -> [Rule] {
        guard let text = try? String(contentsOf: appsURL, encoding: .utf8) else { return parse(defaultList) }
        return parse(text)
    }

    private func writeDefaultListIfMissing() {
        guard !FileManager.default.fileExists(atPath: Self.appsURL.path) else { return }
        do {
            try FileManager.default.createDirectory(at: MuteState.directoryURL, withIntermediateDirectories: true)
            try Data(Self.defaultList.utf8).write(to: Self.appsURL, options: .atomic)
        } catch {
            log.error("cannot write \(Self.appsURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static let defaultList = """
        # Claude Voice stays silent while one of these apps uses the microphone (menu: "Mute during calls").
        # One app per line: a bundle ID prefix, then the name shown in the menu. Edits apply within 2 seconds.
        # An app's bundle ID: osascript -e 'id of app "Zoom"'
        # Audio apps (Ableton Live...) are left out on purpose: they keep the mic open without a call.
        com.microsoft.teams Teams
        com.tinyspeck.slackmacgap Slack
        us.zoom Zoom
        com.apple.FaceTime FaceTime
        com.apple.avconferenced FaceTime
        com.cisco.webex Webex
        com.webex Webex
        Cisco-Systems.Spark Webex
        com.hnc.Discord Discord
        net.whatsapp.WhatsApp WhatsApp
        desktop.WhatsApp WhatsApp
        org.whispersystems.signal-desktop Signal
        # Browsers: Google Meet, Teams and Zoom on the web.
        com.google.Chrome Chrome
        com.apple.Safari Safari
        com.apple.WebKit.GPU Safari
        company.thebrowser.Browser Arc
        org.mozilla.firefox Firefox
        com.microsoft.edgemac Edge
        com.brave.Browser Brave

        """
}
