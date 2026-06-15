import Foundation
import os

enum AudioStreamBuffer {
    static let chunkLimit = 120

    private static let droppedCounts = OSAllocatedUnfairLock(initialState: [String: Int]())

    static func makeStream(
        limit: Int = chunkLimit
    ) -> (stream: AsyncStream<AudioChunk>, continuation: AsyncStream<AudioChunk>.Continuation) {
        AsyncStream.makeStream(
            of: AudioChunk.self,
            bufferingPolicy: .bufferingNewest(limit)
        )
    }

    static func recordYield<Element>(
        _ result: AsyncStream<Element>.Continuation.YieldResult,
        label: String
    ) {
        guard case .dropped(_) = result else { return }
        let count = droppedCounts.withLock {
            $0[label, default: 0] += 1
            return $0[label] ?? 0
        }
        if count == 1 || count.isMultiple(of: 100) {
            DebugDiag.log("audio buffer dropped chunks: \(label) count=\(count)")
        }
    }
}
