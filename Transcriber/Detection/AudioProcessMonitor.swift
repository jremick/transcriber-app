import CoreAudio
import Foundation

/// Reads Core Audio's process objects to answer: which apps are using the
/// microphone right now? This is the most reliable "a call is happening"
/// signal available without extra permissions.
actor AudioProcessMonitor {
    /// Bundle IDs of processes currently running audio input (excluding us).
    func activeInputBundleIDs() -> Set<String> {
        var result: Set<String> = []
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        for object in processObjects() {
            guard readPID(of: object) != ownPID,
                  readIsRunningInput(object),
                  let bundleID = readBundleID(of: object),
                  !bundleID.isEmpty
            else { continue }
            result.insert(bundleID)
        }
        return result
    }

    private func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard err == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects)
        guard err == noErr else { return [] }
        return objects
    }

    private func readPID(of object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        return pid
    }

    private func readBundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { return nil }
        return value as String
    }

    private func readIsRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return err == noErr && value != 0
    }
}
