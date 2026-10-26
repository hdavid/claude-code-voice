import AppKit
import ServiceManagement
import WidgetKit
import os

/// Menu bar switch for Claude's spoken alerts.
///
/// Click the speaker: toggles the mute. Right-click (or control-click): a menu with the state,
/// "Open at login" and Quit. The icon follows the file, so a "mute" typed to Claude shows up here too.
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

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
            || event?.modifierFlags.contains(.option) == true
        if wantsMenu {
            showMenu()
        } else {
            setMuted(!MuteState.isMuted)
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

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let hint = NSMenuItem(title: "Click the icon to toggle. Control Center: add “Claude Voice”.", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Voice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Pop the menu for this click only; the next plain click toggles again.
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
        statusItem?.button?.toolTip = muted ? "Claude voice: muted. Click to unmute." : "Claude voice: on. Click to mute."
        ControlCenter.shared.reloadControls(ofKind: MuteState.controlKind)
    }

    /// Claude.app's own menu bar mark, read from that app when it is installed. The mark is Anthropic's, so it is
    /// never bundled or shipped here; without Claude.app the icon falls back to an asterisk.
    private static let claudeMark: NSImage? = {
        let homes = ["/Applications", NSHomeDirectory() + "/Applications"]
        for home in homes {
            let path = home + "/Claude.app/Contents/Resources/TrayIconTemplate@2x.png"
            if let image = NSImage(contentsOfFile: path) {
                image.isTemplate = true
                return image
            }
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        return NSImage(systemSymbolName: "asterisk", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }()

    /// The mark with a speaker beside it, as one template image: the system tints both for light, dark and the
    /// dimmed muted state, and the speaker carries the state.
    private static func menuBarIcon(muted: Bool) -> NSImage {
        let height: CGFloat = 18
        let gap: CGFloat = 4
        let mark = claudeMark
        let symbolName = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let speaker = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        let markSize = mark == nil ? NSSize.zero : NSSize(width: height, height: height)   // Claude's PNG is 24 pt with padding: full height here
        let speakerSize = speaker?.size ?? .zero
        let width = markSize.width + (mark == nil || speaker == nil ? 0 : gap) + speakerSize.width
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            mark?.draw(in: NSRect(x: 0, y: (height - markSize.height) / 2, width: markSize.width, height: markSize.height))
            speaker?.draw(in: NSRect(x: width - speakerSize.width, y: (height - speakerSize.height) / 2,
                                     width: speakerSize.width, height: speakerSize.height))
            return true
        }
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
