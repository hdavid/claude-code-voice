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
    private var shownMuted: Bool?
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
            }
        }
        replies.start()
        updater.start()
    }

    // MARK: - Clicks

    /// Click: the menu (after a short wait, to tell it from a double-click). Right-click: the menu at once.
    /// Double-click, Option-click or Control-click: mute or unmute at once.
    @objc private func statusItemClicked(_ sender: Any?) {
        // The keys held right now: the status item's event carries no modifier flags (measured: flags 0 while
        // Control was held), and Control-click arrives as a right click.
        let held = NSEvent.modifierFlags
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
            shownMuted = nil   // the tooltip shows the level
            refresh()
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

        let state = NSMenuItem(title: muted ? "Claude voice: muted" : "Claude voice: on", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)

        let toggle = NSMenuItem(title: muted ? "Unmute" : "Mute", action: #selector(toggleFromMenu(_:)), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

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

    private func refresh() {
        let muted = MuteState.isMuted
        guard muted != shownMuted else { return }
        shownMuted = muted
        statusItem?.button?.image = Self.menuBarIcon(muted: muted)
        statusItem?.button?.appearsDisabled = muted
        statusItem?.button?.toolTip = muted
            ? "Claude voice: muted. Double-click to unmute."
            : "Claude voice: on, \(VoiceVolume.percent) %. Click for the volume, double-click to mute."
        ControlCenter.shared.reloadControls(ofKind: MuteState.controlKind)
    }

    /// The Claude mark with the speaker's sound waves (muted: struck through), a template image from the asset
    /// catalog shared with the Control Center toggle: the system tints it for light, dark and the dimmed state.
    private static func menuBarIcon(muted: Bool) -> NSImage {
        let image = NSImage(named: muted ? "VoiceMuted" : "VoiceOn") ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = muted ? "Claude voice muted" : "Claude voice on"
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
