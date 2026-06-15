import Foundation
import os

/// Dev-only file diagnostics (`defaults write dev.local.transcriber debugDiag -bool YES`).
/// Appends to ~/Library/Application Support/Transcriber/debug/diag.log.
enum DebugDiag {
    private static let handle: FileHandle? = {
        guard UserDefaults.standard.bool(forKey: "debugDiag") else { return nil }
        let dir = DebugArtifacts.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "diag.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    private static let lock = OSAllocatedUnfairLock()

    static func log(_ message: String) {
        guard handle != nil else { return }
        lock.withLock {
            let stamp = Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))
            handle?.write(Data("[\(stamp)] \(message)\n".utf8))
        }
    }
}
