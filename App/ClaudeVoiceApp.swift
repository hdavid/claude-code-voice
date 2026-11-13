import AppKit
import ServiceManagement
import WidgetKit
import os

/// Menu bar switch for Claude's spoken alerts.
///
/// Click the icon: a menu with the state, Mute, Claude's volume slider, "Open at login" and Quit.
/// Option-click: mute or unmute at once. The icon follows the file, so a "mute" typed to Claude shows up here too.
@main
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
    private let preview = VolumePreview()

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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: - Clicks

    /// Click (left or right): the menu with the volume slider and Mute. Option-click: mute or unmute at once.
    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let quickToggle = event?.type == .leftMouseUp && event?.modifierFlags.contains(.option) == true
        if quickToggle {
            setMuted(!MuteState.isMuted)
        } else {
            showMenu()
        }
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

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let hint = NSMenuItem(title: "Option-click the icon to mute at once. Control Center: add “Claude Voice”.", action: nil, keyEquivalent: "")
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
            ? "Claude voice: muted. Option-click to unmute."
            : "Claude voice: on, \(VoiceVolume.percent) %. Click for the volume, option-click to mute."
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
