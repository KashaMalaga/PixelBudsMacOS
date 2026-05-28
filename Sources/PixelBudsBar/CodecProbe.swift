import CoreAudio

/// Best-effort codec label derived from the CoreAudio stream format of
/// the matching Bluetooth output device. No process spawning; synchronous.
///
/// macOS presents Bluetooth audio to CoreAudio as LPCM (host-decoded), so the
/// actual over-the-air codec is not exposed directly. Two transport paths:
///
/// Classic Bluetooth (kAudioDeviceTransportTypeBluetooth) — A2DP profile:
///   - 44 100 Hz / 48 000 Hz → AAC  (macOS always negotiates AAC when available)
///   -      8 / 16 000 Hz    → HFP  (Hands-Free Profile, active during calls)
///   -       0 Hz / absent   → nil  (A2DP not active; hide the label)
///
/// Bluetooth LE Audio (kAudioDeviceTransportTypeBluetoothLE) — ISO channels:
///   - Any rate → LC3  (the mandatory LE Audio codec; used by Pixel Buds Pro 2
///                      for Auracast and low-latency audio on supported sources)
///   macOS 14/15 do not yet expose LE Audio devices through CoreAudio, so this
///   branch is a forward-compatible stub — it will light up automatically if
///   Apple adds LE Audio output support in a future OS release.
enum CodecProbe {
    /// Returns a short codec label for the named Bluetooth device, or `nil`
    /// when the device has no active audio output stream or the codec cannot
    /// be determined. Always call on a background thread — safe to run inline
    /// in a Task because it does only synchronous CoreAudio property reads.
    static func label(forDeviceNamed name: String) -> String? {
        guard let (transport, rate) = bluetoothOutputStream(forDeviceNamed: name),
              rate > 0 else { return nil }

        // LE Audio path (Auracast / LC3) — macOS stub, ready for future OS support.
        if transport == kAudioDeviceTransportTypeBluetoothLE { return "LC3" }

        // Classic A2DP path.
        switch rate {
        case 0..<20_000: return "HFP"        // 8 kHz or 16 kHz voice narrowband
        default:         return "AAC"        // 44.1 kHz or 48 kHz A2DP stereo
        }
    }

    // MARK: - Private

    /// Walks CoreAudio's device list for a Bluetooth output device matching
    /// `name` and returns its (transportType, sampleRate) tuple. Accepts both
    /// classic Bluetooth and Bluetooth LE transport types so that an LC3/LE Audio
    /// device would be detected if macOS ever exposes one through CoreAudio.
    private static func bluetoothOutputStream(forDeviceNamed name: String) -> (UInt32, Double)? {
        var size: UInt32 = 0
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &ids
        ) == noErr else { return nil }

        let btTransports: Set<UInt32> = [
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
        ]
        for deviceID in ids {
            let transport = transportType(for: deviceID)
            guard deviceName(for: deviceID) == name,
                  btTransports.contains(transport),
                  let rate = outputSampleRate(for: deviceID)
            else { continue }
            return (transport, rate)
        }
        return nil
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // AudioObjectGetPropertyData returns a +1-retained CFString; take it as
        // Unmanaged to avoid the "UnsafeMutableRawPointer to CFString" warning.
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &ref) == noErr else {
            return nil
        }
        return ref?.takeRetainedValue() as String?
    }

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        return value
    }

    private static func outputSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &fmt) == noErr else {
            return nil
        }
        return fmt.mSampleRate
    }
}
