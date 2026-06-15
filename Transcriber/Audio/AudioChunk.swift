import AVFoundation
import Foundation

/// A captured PCM buffer crossing from an audio callback into async consumers.
/// The wrapped buffer is exclusively owned by this chunk and never mutated
/// after creation, which makes the unchecked-Sendable claim sound.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// Host time of the first frame, when the callback provided one.
    let hostTime: UInt64?

    var frameCount: AVAudioFrameCount { buffer.frameLength }
    var format: AVAudioFormat { buffer.format }
    var duration: TimeInterval {
        Double(buffer.frameLength) / buffer.format.sampleRate
    }

    /// Root-mean-square level of the first channel, 0...1.
    var rmsLevel: Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let samples = data[0]
        for i in 0..<n { sum += samples[i] * samples[i] }
        return min(1, sqrt(sum / Float(n)) * 4)
    }
}

extension AVAudioPCMBuffer {
    /// Deep copy so audio-callback-owned memory never escapes the callback.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let src = audioBufferList.pointee
        let dst = copy.mutableAudioBufferList.pointee
        let srcBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList))
        let dstBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.mNumberBuffers == dst.mNumberBuffers else { return nil }
        for i in 0..<srcBuffers.count {
            guard let s = srcBuffers[i].mData, let d = dstBuffers[i].mData else { continue }
            memcpy(d, s, Int(srcBuffers[i].mDataByteSize))
        }
        return copy
    }
}

/// Streaming sample-rate/format converter to a canonical mono Float32 format.
/// Create one per source format; not thread-safe — use from a single task.
final class AudioResampler {
    private let converter: AVAudioConverter
    let outputFormat: AVAudioFormat

    init?(from sourceFormat: AVAudioFormat, toSampleRate rate: Double) {
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ), let conv = AVAudioConverter(from: sourceFormat, to: out) else {
            return nil
        }
        self.converter = conv
        self.outputFormat = out
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Convert and return the mono float samples.
    func convertToFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let out = convert(buffer), let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
