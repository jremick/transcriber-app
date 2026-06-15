import AVFoundation
import Foundation

enum AudioFixture {
    enum FixtureError: LocalizedError {
        case invalidChunkDuration
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .invalidChunkDuration:
                "Audio fixture chunk duration must be greater than zero."
            case .bufferAllocationFailed:
                "Couldn't allocate an audio fixture buffer."
            }
        }
    }

    static func chunks(
        from url: URL,
        chunkDuration: TimeInterval = 0.1
    ) throws -> [AudioChunk] {
        guard chunkDuration > 0 else { throw FixtureError.invalidChunkDuration }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let framesPerChunk = max(
            1,
            AVAudioFrameCount((format.sampleRate * chunkDuration).rounded(.toNearestOrAwayFromZero))
        )
        var chunks: [AudioChunk] = []

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(framesPerChunk), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw FixtureError.bufferAllocationFailed
            }
            try file.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }
            guard let copy = buffer.deepCopy() else {
                throw FixtureError.bufferAllocationFailed
            }
            chunks.append(AudioChunk(buffer: copy, hostTime: nil))
        }

        return chunks
    }

    static func stream(from chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
