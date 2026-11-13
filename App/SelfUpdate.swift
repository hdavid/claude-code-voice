import CryptoKit
import Foundation
import Security
import os

/// Installs a newer Claude Voice in place, once the user has picked "Update".
///
/// The zip is checked against the digest GitHub computed at upload, and the app inside must carry a valid signature
/// from the running app's Developer ID team: a build signed by anyone else is never installed. The app cannot replace
/// itself while it runs, so the last step starts a small script and the caller quits: the script waits for this
/// process to end, swaps the bundle (putting the old one back if the copy fails) and opens the new version.
enum SelfUpdate {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private static let log = Logger(subsystem: "com.mots.claude-voice", category: "update")

    /// Downloads, checks and stages `asset`, then starts the hand-over script. The caller quits right after.
    static func install(_ asset: UpdateCheck.Asset) async throws {
        guard asset.url.absoluteString.hasPrefix(UpdateCheck.downloadsPrefix) else {
            throw Failure("refusing to download from \(asset.url)")
        }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { throw Failure("not running from an app bundle") }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw Failure("no permission to replace the app in \(target.deletingLastPathComponent().path)")
        }
        let work = try freshWorkDir()
        let zip = try await download(asset, into: work)
        let staged = try unzip(zip, expecting: target.lastPathComponent, into: work)
        try verifySignature(of: staged)
        try handOver(staged: staged, target: target, work: work)
    }

    private static func freshWorkDir() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let work = caches.appendingPathComponent("io.github.hdavid.claude-code-voice/update", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    private static func download(_ asset: UpdateCheck.Asset, into work: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: asset.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let file = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: temp, to: file)
        let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw Failure("\(asset.name) does not match its published checksum")
        }
        log.info("update: downloaded \(asset.name, privacy: .public), checksum ok")
        return file
    }

    private static func unzip(_ zip: URL, expecting name: String, into work: URL) throws -> URL {
        let out = work.appendingPathComponent("unzipped", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path], what: "unzip the update")
        let app = out.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path) else { throw Failure("the update holds no \(name)") }
        return app
    }

    /// The new app must verify (nested code too) and be signed by the running app's team.
    private static func verifySignature(of app: URL) throws {
        guard let team = runningTeam() else {
            throw Failure("this build is not Developer ID signed; install the new one by hand")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            throw Failure("could not read the new app's signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw Failure("the new app is not signed by team \(team) (status \(status))")
        }
    }

    private static func runningTeam() -> String? {
        var me: SecCode?
        var staticMe: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func handOver(staged: URL, target: URL, work: URL) throws {
        let script = work.appendingPathComponent("update.sh")
        try handOverScript(pid: getpid(), staged: staged, target: target, work: work)
            .write(to: script, atomically: true, encoding: .utf8)
        let logFile = work.deletingLastPathComponent().appendingPathComponent("update.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let out = try FileHandle(forWritingTo: logFile)
        out.seekToEndOfFile()
        process.standardOutput = out
        process.standardError = out
        try process.run()   // outlives this app: reparented to launchd when the app quits
        log.info("update: handed over to \(script.path, privacy: .public)")
    }

    /// Waits for `pid` to end, puts `staged` in place of `target` (the old bundle aside, restored if the copy fails),
    /// reopens it, and removes the work folder.
    static func handOverScript(pid: Int32, staged: URL, target: URL, work: URL) -> String {
        func q(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".previous")
        return """
        #!/bin/sh
        # Claude Voice update: started by the app as it quit.
        date
        while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done
        rm -rf \(q(old))
        if mv \(q(target)) \(q(old)); then
          if ditto \(q(staged)) \(q(target)); then
            rm -rf \(q(old))
            echo "updated \(target.path)"
          else
            echo "copy failed, putting the old version back"
            rm -rf \(q(target))
            mv \(q(old)) \(q(target))
          fi
        else
          echo "could not move the old version aside"
        fi
        open \(q(target))
        rm -rf \(q(work))

        """
    }

    private static func run(_ tool: String, _ arguments: [String], what: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure("could not \(what): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
