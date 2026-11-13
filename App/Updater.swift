import AppKit
import os

/// Checks for a newer Claude Voice at launch and every few hours, and puts "Update to …" at the top of the menu
/// when there is one. Picking it installs in place (SelfUpdate) and relaunches; when that cannot be done, the
/// release page opens instead.
@MainActor
final class Updater {
    private let log = Logger(subsystem: "com.mots.claude-voice", category: "update")
    private var timer: Timer?
    private var installing = false
    private(set) var available: UpdateCheck.Release?

    private static let interval: TimeInterval = 6 * 3600

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        guard UpdateCheck.isEnabled else {
            available = nil
            return
        }
        Task { available = await UpdateCheck.fetchNewer() }
    }

    /// "Update to Claude Voice 1.4.0" (only when one is available), for the top of the menu.
    func updateItem(target: AnyObject, action: Selector) -> NSMenuItem? {
        guard let release = available else { return nil }
        let title = installing ? "Updating to \(release.version)…" : "Update to Claude Voice \(release.version)"
        let item = NSMenuItem(title: title, action: installing ? nil : action, keyEquivalent: "")
        item.target = target
        item.isEnabled = !installing
        item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Update")
        return item
    }

    /// The "Check for updates" switch.
    func settingItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "Check for updates", action: action, keyEquivalent: "")
        item.target = target
        item.state = UpdateCheck.isEnabled ? .on : .off
        return item
    }

    func toggleSetting() {
        UserDefaults.standard.set(!UpdateCheck.isEnabled, forKey: UpdateCheck.settingKey)
        check()
    }

    /// Installs and quits (the hand-over script relaunches the new version). On failure: an alert and the page.
    func install(onFailure: @escaping (String) -> Void) {
        guard let release = available, !installing else { return }
        guard let zip = release.zip else {
            NSWorkspace.shared.open(release.page)
            return
        }
        installing = true
        Task {
            do {
                try await SelfUpdate.install(zip)
                NSApp.terminate(nil)
            } catch {
                installing = false
                log.error("update failed: \(error.localizedDescription, privacy: .public)")
                onFailure(error.localizedDescription)
                NSWorkspace.shared.open(release.page)
            }
        }
    }
}
