import Foundation
import Testing
@testable import Transcriber

struct DebugArtifactsTests {
    @Test func countsAndDeletesOnlyKnownDebugArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "transcriber-debug-artifacts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let wav = directory.appending(path: "mic-test.wav")
        let log = directory.appending(path: "diag.log")
        let unrelated = directory.appending(path: "keep.txt")
        try Data("audio".utf8).write(to: wav)
        try Data("diag".utf8).write(to: log)
        try Data("keep".utf8).write(to: unrelated)

        #expect(try DebugArtifacts.artifactCount(in: directory) == 2)

        let deleted = try DebugArtifacts.deleteArtifacts(in: directory)

        #expect(deleted == 2)
        #expect(!FileManager.default.fileExists(atPath: wav.path))
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func missingDirectoryHasNoArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "transcriber-missing-debug-artifacts-\(UUID().uuidString)", directoryHint: .isDirectory)

        #expect(try DebugArtifacts.artifactCount(in: directory) == 0)
        #expect(try DebugArtifacts.deleteArtifacts(in: directory) == 0)
    }
}
