import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Captures a mono mixdown of all system audio output (every process except our
/// own) using Core Audio process taps (macOS 14.4+): tap → private aggregate
/// device → IOProc. This is how we hear remote meeting participants.
@MainActor
final class SystemAudioTapService {
    private static let log = Logger(subsystem: "dev.local.transcriber", category: "SystemTap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "dev.local.transcriber.system-tap-io")
    private(set) var isRunning = false

    func start() throws -> AsyncStream<AudioChunk> {
        precondition(!isRunning)
        let (stream, continuation) = AudioStreamBuffer.makeStream()
        self.continuation = continuation
        do {
            try activateTap()
        } catch {
            continuation.finish()
            self.continuation = nil
            throw error
        }
        installDeviceChangeListener()
        isRunning = true
        return stream
    }

    func stop() {
        guard isRunning else { return }
        removeDeviceChangeListener()
        deactivateTap()
        continuation?.finish()
        continuation = nil
        isRunning = false
    }

    // MARK: - Tap plumbing

    private func activateTap() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        description.name = "Transcriber System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID != kAudioObjectUnknown else {
            throw AudioCaptureError.tapCreationFailed(err)
        }
        tapID = newTapID

        var asbd = try readTapFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            deactivateTap()
            throw AudioCaptureError.formatUnavailable
        }
        Self.log.info("Tap format: \(format.sampleRate) Hz, \(format.channelCount) ch")

        let outputUID = try Self.readDefaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcriber Tap Device",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard err == noErr, newAggregateID != kAudioObjectUnknown else {
            deactivateTap()
            throw AudioCaptureError.aggregateDeviceFailed(err)
        }
        aggregateID = newAggregateID

        guard let continuation else { throw AudioCaptureError.formatUnavailable }
        var newProcID: AudioDeviceIOProcID?
        let tapFormat = format
        err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) {
            @Sendable _, inInputData, _, _, _ in
            guard let chunk = Self.makeChunk(from: inInputData, format: tapFormat) else { return }
            let result = continuation.yield(chunk)
            AudioStreamBuffer.recordYield(result, label: "system raw")
        }
        guard err == noErr, let procID = newProcID else {
            deactivateTap()
            throw AudioCaptureError.ioProcFailed(err)
        }
        ioProcID = procID

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            deactivateTap()
            throw AudioCaptureError.ioProcFailed(err)
        }
    }

    private func deactivateTap() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// The tap's aggregate is bound to the output device that was default at
    /// start; rebuild when the user switches output (e.g. AirPods connect).
    private func installDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDefaultDeviceChange()
            }
        }
        deviceChangeListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    private func removeDeviceChangeListener() {
        guard let listener = deviceChangeListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        deviceChangeListener = nil
    }

    private func handleDefaultDeviceChange() {
        guard isRunning else { return }
        Self.log.info("Default output device changed — rebuilding tap")
        deactivateTap()
        do {
            try activateTap()
        } catch {
            Self.log.error("Tap rebuild failed: \(error.localizedDescription)")
            continuation?.finish()
        }
    }

    // MARK: - Buffer conversion (runs on IO queue)

    private nonisolated static func makeChunk(
        from abl: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AudioChunk? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return nil }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(first.mDataByteSize / bytesPerFrame)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        pcm.frameLength = frames
        let dst = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for i in 0..<min(buffers.count, dst.count) {
            guard let s = buffers[i].mData, let d = dst[i].mData else { continue }
            memcpy(d, s, Int(min(buffers[i].mDataByteSize, dst[i].mDataByteSize)))
        }
        return AudioChunk(buffer: pcm, hostTime: nil)
    }

    // MARK: - Core Audio property helpers

    private func readTapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard err == noErr else { throw AudioCaptureError.formatUnavailable }
        return asbd
    }

    private static func readDefaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioCaptureError.formatUnavailable
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw AudioCaptureError.formatUnavailable }
        return uid as String
    }

    /// Our own process's audio objects, excluded from the tap so any future
    /// audio we play never feeds back into transcription.
    private static func ownProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object)
        }
        guard err == noErr, object != kAudioObjectUnknown else { return [] }
        return [object]
    }
}
