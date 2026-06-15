import AVFoundation
import CoreAudio
import Foundation

enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case engineStartFailed(String)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .engineStartFailed(let reason):
            "The microphone could not be started: \(reason)"
        case .tapCreationFailed(let status):
            "System audio capture failed (tap error \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
        case .aggregateDeviceFailed(let status):
            "System audio capture failed (device error \(status))."
        case .ioProcFailed(let status):
            "System audio capture failed (IO error \(status))."
        case .formatUnavailable:
            "The audio format could not be determined."
        }
    }
}

/// Captures the user's microphone with voice processing (echo cancellation)
/// so speaker output doesn't bleed into the local channel.
@MainActor
final class MicCaptureService {
    private var engine: AVAudioEngine?
    private var halCapture: HALInputCapture?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var isRunning = false
    /// True when AEC could not be enabled and we fell back to a plain tap.
    private(set) var voiceProcessingActive = false

    static func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        precondition(!isRunning)
        let (stream, continuation) = AudioStreamBuffer.makeStream()

        // Voice processing (AEC) keeps speaker bleed out of the mic channel,
        // but its initialization is fragile (device-dependent, -10875; '!dev'
        // when another app holds a conflicting configuration), so fall back to
        // a plain capture engine, with one delayed retry for transient
        // device-busy states.
        do {
            engine = try runEngine(voiceProcessing: true, continuation: continuation)
            voiceProcessingActive = true
        } catch {
            DebugDiag.log("mic vp engine failed: \(error)")
            engine = nil
            do {
                engine = try runEngine(voiceProcessing: false, continuation: continuation)
                voiceProcessingActive = false
            } catch {
                DebugDiag.log("mic plain engine failed: \(error); retrying in 0.7s")
                try? await Task.sleep(for: .milliseconds(700))
                do {
                    engine = try runEngine(voiceProcessing: false, continuation: continuation)
                    voiceProcessingActive = false
                } catch {
                    DebugDiag.log("mic plain engine retry failed: \(error)")
                    do {
                        let hal = HALInputCapture(continuation: continuation)
                        try hal.start()
                        halCapture = hal
                        voiceProcessingActive = false
                        DebugDiag.log("mic HAL input fallback started")
                    } catch {
                        DebugDiag.log("mic HAL input fallback failed: \(error)")
                        continuation.finish()
                        throw AudioCaptureError.engineStartFailed(error.localizedDescription)
                    }
                }
            }
        }

        self.continuation = continuation
        isRunning = true
        return stream
    }

    private func runEngine(
        voiceProcessing: Bool,
        continuation: AsyncStream<AudioChunk>.Continuation
    ) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        _ = engine.outputNode

        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Full-duplex render path is required; keep it silent.
            engine.connect(input, to: engine.mainMixerNode, format: nil)
            engine.mainMixerNode.outputVolume = 0
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.formatUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, time in
            guard let copy = buffer.deepCopy() else { return }
            let result = continuation.yield(AudioChunk(buffer: copy, hostTime: time.hostTime))
            AudioStreamBuffer.recordYield(result, label: "mic raw")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if voiceProcessing {
                try? input.setVoiceProcessingEnabled(false)
            }
            throw error
        }
        return engine
    }

    func stop() {
        guard isRunning else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        halCapture?.stop()
        halCapture = nil
        continuation?.finish()
        continuation = nil
        isRunning = false
    }
}

private final class HALInputCapture: @unchecked Sendable {
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let ioQueue = DispatchQueue(label: "dev.local.transcriber.mic-hal-io")
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(continuation: AsyncStream<AudioChunk>.Continuation) {
        self.continuation = continuation
    }

    func start() throws {
        deviceID = try Self.readDefaultInputDevice()
        DebugDiag.log("mic HAL default input device: \(deviceID)")
        let asbd = try Self.readInputFormat(deviceID)
        guard let inputFormat = HALInputDescriptor(asbd),
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: asbd.mSampleRate,
                  channels: 1,
                  interleaved: false
              )
        else {
            DebugDiag.log(
                "mic HAL unsupported format: sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bytesPerFrame=\(asbd.mBytesPerFrame) formatID=\(asbd.mFormatID) flags=\(asbd.mFormatFlags)"
            )
            throw AudioCaptureError.formatUnavailable
        }
        DebugDiag.log(
            "mic HAL input format: \(asbd.mSampleRate) Hz \(asbd.mChannelsPerFrame)ch interleaved=\(!inputFormat.isNonInterleaved); output=mono"
        )

        var newProcID: AudioDeviceIOProcID?
        let continuation = continuation
        var err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, deviceID, ioQueue) {
            @Sendable _, inputData, inputTime, _, _ in
            guard let chunk = Self.makeChunk(
                from: inputData,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                hostTime: inputTime.pointee.mHostTime
            ) else { return }
            let result = continuation.yield(chunk)
            AudioStreamBuffer.recordYield(result, label: "mic raw")
        }
        guard err == noErr, let procID = newProcID else {
            throw AudioCaptureError.ioProcFailed(err)
        }
        ioProcID = procID

        err = AudioDeviceStart(deviceID, procID)
        guard err == noErr else {
            stop()
            throw AudioCaptureError.ioProcFailed(err)
        }
    }

    func stop() {
        if let procID = ioProcID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        ioProcID = nil
        deviceID = AudioDeviceID(kAudioObjectUnknown)
    }

    private static func readDefaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard err == noErr, device != kAudioObjectUnknown else {
            throw AudioCaptureError.formatUnavailable
        }
        return device
    }

    private static func readInputFormat(_ device: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &asbd)
        if err == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 {
            return asbd
        }

        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        size = 0
        let sizeErr = AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &size)
        guard sizeErr == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) else {
            throw AudioCaptureError.formatUnavailable
        }

        let streamCount = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = Array(repeating: AudioStreamID(kAudioObjectUnknown), count: streamCount)
        let streamsErr = AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &size, &streams)
        guard streamsErr == noErr else { throw AudioCaptureError.formatUnavailable }

        for stream in streams where stream != kAudioObjectUnknown {
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamASBD = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let formatErr = AudioObjectGetPropertyData(
                stream, &formatAddress, 0, nil, &formatSize, &streamASBD)
            if formatErr == noErr,
               streamASBD.mSampleRate > 0,
               streamASBD.mChannelsPerFrame > 0 {
                return streamASBD
            }
        }

        throw AudioCaptureError.formatUnavailable
    }

    private nonisolated static func makeChunk(
        from abl: UnsafePointer<AudioBufferList>,
        inputFormat: HALInputDescriptor,
        outputFormat: AVAudioFormat,
        hostTime: UInt64
    ) -> AudioChunk? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return nil }
        let frameBytes = inputFormat.isNonInterleaved
            ? MemoryLayout<Float>.size
            : inputFormat.bytesPerFrame
        guard frameBytes > 0 else { return nil }
        var frameCount = Int(first.mDataByteSize) / frameBytes

        if inputFormat.isNonInterleaved {
            let channelCount = min(inputFormat.channelCount, buffers.count)
            guard channelCount > 0 else { return nil }
            for channel in 0..<channelCount {
                frameCount = min(
                    frameCount,
                    Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size
                )
            }
        }

        guard frameCount > 0 else { return nil }
        let frames = AVAudioFrameCount(frameCount)
        guard
              let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames),
              let dst = pcm.floatChannelData?[0]
        else { return nil }
        pcm.frameLength = frames

        if inputFormat.isNonInterleaved {
            let channelCount = min(inputFormat.channelCount, buffers.count)
            guard channelCount > 0 else { return nil }
            for frame in 0..<Int(frames) {
                var sum: Float = 0
                var samples = 0
                for channel in 0..<channelCount {
                    guard let data = buffers[channel].mData else { continue }
                    let source = data.assumingMemoryBound(to: Float.self)
                    sum += source[frame]
                    samples += 1
                }
                dst[frame] = samples > 0 ? sum / Float(samples) : 0
            }
        } else {
            guard let data = first.mData else { return nil }
            let source = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frames) {
                let base = frame * inputFormat.channelCount
                var sum: Float = 0
                for channel in 0..<inputFormat.channelCount {
                    sum += source[base + channel]
                }
                dst[frame] = sum / Float(inputFormat.channelCount)
            }
        }
        return AudioChunk(buffer: pcm, hostTime: hostTime)
    }
}

private struct HALInputDescriptor: Sendable {
    let channelCount: Int
    let bytesPerFrame: Int
    let isNonInterleaved: Bool

    init?(_ asbd: AudioStreamBasicDescription) {
        let flags = asbd.mFormatFlags
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0,
              asbd.mBytesPerFrame > 0,
              asbd.mBitsPerChannel == 32,
              flags & kAudioFormatFlagIsFloat != 0
        else { return nil }

        channelCount = Int(asbd.mChannelsPerFrame)
        bytesPerFrame = Int(asbd.mBytesPerFrame)
        isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0

        if isNonInterleaved {
            guard bytesPerFrame >= MemoryLayout<Float>.size else { return nil }
        } else {
            guard bytesPerFrame >= channelCount * MemoryLayout<Float>.size else { return nil }
        }
    }
}
