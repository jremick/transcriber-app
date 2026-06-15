import AVFoundation
import Testing
@testable import Transcriber

struct AudioStreamBufferTests {
    @Test func bufferingNewestDropsOldestChunkWhenConsumerStalls() async throws {
        let (stream, continuation) = AudioStreamBuffer.makeStream(limit: 2)

        continuation.yield(try Self.chunk(hostTime: 1))
        continuation.yield(try Self.chunk(hostTime: 2))
        continuation.yield(try Self.chunk(hostTime: 3))
        continuation.finish()

        var hostTimes: [UInt64] = []
        for await chunk in stream {
            if let hostTime = chunk.hostTime {
                hostTimes.append(hostTime)
            }
        }

        #expect(hostTimes == [2, 3])
    }

    private static func chunk(hostTime: UInt64) throws -> AudioChunk {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        return AudioChunk(buffer: buffer, hostTime: hostTime)
    }
}
