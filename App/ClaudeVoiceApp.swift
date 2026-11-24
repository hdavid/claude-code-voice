import AppKit
import ServiceManagement
import WidgetKit
import os

/// Menu bar switch for Claude's spoken alerts.
///
/// Click the icon: a menu with the state, Mute, Claude's volume slider, "Open at login" and Quit.
/// Option- or Control-click: mute or unmute at once. The icon follows the file, so a "mute" typed to Claude shows up here too.
@main
@MainActor
final class ClaudeVoiceApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = ClaudeVoiceApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let log = Logger(subsystem: "com.mots.claude-voice", category: "app")
    private var statusItem: NSStatusItem?
    private var watcher: DirectoryWatcher?
    private var pollTimer: Timer?
    private var shownManualMute: Bool?
    private let calls = CallDetector()
    private let missed = MissedAlerts()
    private var pendingMenu: Timer?
    private let preview = VolumePreview()
    private let replies = VoiceReplies()
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        calls.onChange = { [weak self] in
            guard let self else { return }
            if calls.callApp != nil { replies.interrupt() }   // voice-say stops its own sentence (bin/voice-say)
            refresh()
        }
        missed.onChange = { [weak self] in self?.refresh() }
        refresh()
        // Immediate: a vnode event on ~/.claude whenever an entry is created or removed there.
        watcher = DirectoryWatcher(directory: MuteState.directoryURL) { [weak self] in self?.refresh() }
        if watcher == nil {
            log.error("cannot watch \(MuteState.directoryURL.path, privacy: .public); polling only")
        }
        // Belt and braces: a slow poll in case an event is missed.
        // A timer scheduled here fires on the main run loop, so the main actor is already ours.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.replies.poll()
                self?.missed.collect(flash: true)
            }
        }
        calls.start()
        missed.start()
        replies.start()
        updater.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        calls.stop()
    }

    // MARK: - Clicks

    /// Click: the menu (after a short wait, to tell it from a double-click). Right-click: the menu at once.
    /// Double-click, Option-click or Control-click: mute or unmute at once.
    @objc private func statusItemClicked(_ sender: Any?) {
        // The keys held right now: the status item's event carries no modifier flags (measured: flags 0 while
        // Control was held), and Control-click arrives as a right click.
        let held = NSEvent.modifierFlags
        missed.acknowledge()   // any click: the user has seen the flash
        if held.contains(.option) || held.contains(.control) {
            cancelPendingMenu()
            setMuted(!MuteState.isMuted)
            return
        }
        guard NSApp.currentEvent?.type == .leftMouseUp else {
            cancelPendingMenu()
            showMenu()
            return
        }
        // A second click while the first one's menu is still pending: a double-click.
        if pendingMenu != nil {
            cancelPendingMenu()
            setMuted(!MuteState.isMuted)
            return
        }
        let wait = min(NSEvent.doubleClickInterval, Self.doubleClickWait)
        pendingMenu = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pendingMenu = nil
                self?.showMenu()
            }
        }
    }

    /// The longest the menu waits for a second click; the system's double-click speed when that is shorter.
    private static let doubleClickWait: TimeInterval = 0.3

    private func cancelPendingMenu() {
        pendingMenu?.invalidate()
        pendingMenu = nil
    }

    private func volumeChanged(_ percent: Int) {
        do {
            try VoiceVolume.setPercent(percent)
            refresh()   // the tooltip shows the level
        } catch {
            log.error("could not save the volume: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func toggleFromMenu(_ sender: Any?) {
        setMuted(!MuteState.isMuted)
    }

    @objc private func installUpdate(_ sender: Any?) {
        updater.install { [weak self] reason in
            self?.presentError(title: "Could not update Claude Voice", detail: "\(reason)\nThe release page opens instead.")
        }
    }

    @objc private func toggleUpdateCheck(_ sender: Any?) {
        updater.toggleSetting()
    }

    @objc private func toggleReplies(_ sender: Any?) {
        changeSetting("voice replies") { try ReplySettings.setEnabled(!ReplySettings.isEnabled) }
    }

    @objc private func toggleCallMute(_ sender: Any?) {
        changeSetting("mute during calls") { try calls.setEnabled(!CallDetector.isEnabled) }
    }

    @objc private func toggleReadback(_ sender: Any?) {
        changeSetting("read back") { try ReplySettings.setReadsBack(!ReplySettings.readsBack) }
    }

    private func changeSetting(_ name: String, _ change: () throws -> Void) {
        do {
            try change()
        } catch {
            log.error("\(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            presentError(title: "Could not change “\(name)”", detail: error.localizedDescription)
        }
    }

    @objc private func toggleOpenAtLogin(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            log.error("open at login: \(error.localizedDescription, privacy: .public)")
            presentError(title: "Could not change “Open at login”", detail: error.localizedDescription)
        }
    }

    private func showMenu() {
        guard let item = statusItem else { return }
        let muted = MuteState.isMuted
        let menu = NSMenu()

        if let update = updater.updateItem(target: self, action: #selector(installUpdate(_:))) {
            menu.addItem(update)
            menu.addItem(.separator())
        }

        let state = NSMenuItem(title: stateTitle(manual: muted), action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)

        let toggle = NSMenuItem(title: muted ? "Unmute" : "Mute", action: #selector(toggleFromMenu(_:)), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let callItem = NSMenuItem(title: "Mute during calls", action: #selector(toggleCallMute(_:)), keyEquivalent: "")
        callItem.target = self
        callItem.state = CallDetector.isEnabled ? .on : .off
        callItem.toolTip = "Silent while Teams, Slack, Zoom, FaceTime or a browser uses the mic. List: \(CallDetector.appsURL.path)"
        menu.addItem(callItem)

        addMissed(to: menu)

        menu.addItem(.separator())

        let volume = NSMenuItem()
        volume.view = VolumeMenuItemView(
            percent: VoiceVolume.percent,
            onChange: { [weak self] percent in self?.volumeChanged(percent) },
            onRelease: { [weak self] percent in self?.preview.play(percent: percent) })
        menu.addItem(volume)

        menu.addItem(.separator())

        let replyItem = NSMenuItem(title: "Voice replies", action: #selector(toggleReplies(_:)), keyEquivalent: "")
        replyItem.target = self
        replyItem.state = ReplySettings.isEnabled ? .on : .off
        replyItem.toolTip = "After a spoken question, Claude asks \"Reply?\" and takes your dictated answer."
        menu.addItem(replyItem)

        let readback = NSMenuItem(title: "Read back before sending", action: #selector(toggleReadback(_:)), keyEquivalent: "")
        readback.target = self
        readback.state = ReplySettings.readsBack ? .on : .off
        readback.isEnabled = ReplySettings.isEnabled
        readback.indentationLevel = 1
        menu.addItem(readback)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(updater.settingItem(target: self, action: #selector(toggleUpdateCheck(_:))))

        let hint = NSMenuItem(title: "Double-click: mute at once", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Voice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Attach the menu for this click only, so the next click comes back to statusItemClicked.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The sentences not spoken while muted, newest first, with their time.
    private func addMissed(to menu: NSMenu) {
        guard !missed.recent.isEmpty else { return }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Not spoken while muted", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        for entry in missed.recent {
            let sentence = entry.sentence.isEmpty ? entry.session : entry.sentence
            let short = sentence.count > Self.missedLength ? String(sentence.prefix(Self.missedLength)) + "…" : sentence
            let line = NSMenuItem(title: "\(time.string(from: entry.date))  \(short)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.toolTip = sentence
            line.indentationLevel = 1
            menu.addItem(line)
        }
    }

    private static let missedLength = 60

    private func stateTitle(manual: Bool) -> String {
        if manual { return "Claude voice: muted" }
        if let app = calls.callApp { return "Claude voice: muted, in a call (\(app))" }
        return "Claude voice: on"
    }

    // MARK: - State

    private func setMuted(_ muted: Bool) {
        do {
            try MuteState.setMuted(muted)
            if !muted {
                NSSound(named: "Pop")?.play()   // audible proof that the voice is back
            }
            refresh()
        } catch {
            log.error("could not \(muted ? "mute" : "unmute", privacy: .public): \(error.localizedDescription, privacy: .public)")
            presentError(title: muted ? "Could not mute Claude" : "Could not unmute Claude",
                         detail: "\(MuteState.fileURL.path)\n\(error.localizedDescription)")
        }
    }

    /// Draws the icon from the current state: muted by hand or by a call, a flash in progress, a missed session.
    private func refresh() {
        let manual = MuteState.isMuted
        let muted = manual || calls.callApp != nil
        guard let button = statusItem?.button else { return }
        // The menu bar draws a template image in its own color and ignores contentTintColor (measured: the flash
        // came out white), so the red half of a flash uses a red, non-template copy of the icon.
        button.image = missed.isRed ? Self.redIcon(muted: muted) : Self.menuBarIcon(muted: muted)
        // Never dimmed: a dimmed icon was hard to see (2026-11-24). The struck-through icon says "muted".
        button.appearsDisabled = false
        if let session = missed.badge {
            let color: NSColor = missed.isRed ? .systemRed : .labelColor
            button.attributedTitle = NSAttributedString(string: " " + session, attributes: [
                .foregroundColor: color,
                .font: NSFont.menuBarFont(ofSize: 0),
            ])
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
        button.toolTip = tooltip(manual: manual)
        if manual != shownManualMute {
            shownManualMute = manual
            ControlCenter.shared.reloadControls(ofKind: MuteState.controlKind)
        }
    }

    private func tooltip(manual: Bool) -> String {
        var text: String
        if manual {
            text = "Claude voice: muted. Double-click to unmute."
        } else if let app = calls.callApp {
            text = "Claude voice: muted while \(app) has the microphone."
        } else {
            text = "Claude voice: on, \(VoiceVolume.percent) %. Click for the volume, double-click to mute."
        }
        if let session = missed.badge {
            text += "\nNot spoken while muted: \(session). Click to see it."
        }
        return text
    }

    /// The Claude mark with the speaker's sound waves (muted: struck through), a template image from the asset
    /// catalog shared with the Control Center toggle: the system tints it for light and dark.
    private static func menuBarIcon(muted: Bool) -> NSImage {
        let image = NSImage(named: muted ? "VoiceMuted" : "VoiceOn") ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = muted ? "Claude voice muted" : "Claude voice on"
        return image
    }

    /// The same icon filled red, drawn as a plain (non-template) image so the menu bar keeps the color.
    private static func redIcon(muted: Bool) -> NSImage {
        let source = menuBarIcon(muted: muted)
        let image = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            NSColor.systemRed.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = source.accessibilityDescription
        return image
    }

    private func presentError(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Fires on the main queue whenever an entry is added to or removed from one directory.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(directory: URL, onChange: @escaping () -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
    }
}
