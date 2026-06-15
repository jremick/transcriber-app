import Foundation

enum DebugArtifacts {
    static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "Transcriber/debug", directoryHint: .isDirectory)
    }

    static func artifactURLs(in directory: URL = directory) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.filter { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return false }
            return isKnownDebugArtifact(url)
        }
    }

    static func artifactCount(in directory: URL = directory) throws -> Int {
        try artifactURLs(in: directory).count
    }

    @discardableResult
    static func deleteArtifacts(in directory: URL = directory) throws -> Int {
        let urls = try artifactURLs(in: directory)
        for url in urls {
            try FileManager.default.removeItem(at: url)
        }
        return urls.count
    }

    private static func isKnownDebugArtifact(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "wav" || url.lastPathComponent == "diag.log"
    }
}
