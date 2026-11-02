// InputRoute — what the capture is actually listening through, and whether the built-in-mic
// pin held (Step 15, background noise in loud rooms).
//
// Why this exists: 121 of 560 live captures (2026-07-20 → 2026-11-01) logged
// "CADefaultDeviceAggregate-…" instead of a microphone name. The pin result was discarded, so
// the log could not say whether those dictations used the MacBook mic or a Bluetooth headset
// mic — exactly the question a noise report needs answered. Pure value types + decisions here;
// CoreAudio reads stay in AudioCapture. `cadence selftest-capture` pins the logic.

import CoreAudio

public enum PinState: Equatable {
    /// Not attempted yet on this engine (fresh engine, before the first tap build).
    case pending
    /// Preference off: following the system default input on purpose.
    case off
    /// No built-in input device exists (Mac mini with nothing plugged in, etc.).
    case noBuiltIn
    /// The AUHAL reads back the built-in device.
    case held
    /// The set call returned an error, or read back a different device.
    case failed(Int32)

    var note: String {
        switch self {
        case .off: return " pin=off"
        case .noBuiltIn: return " pin=no-built-in"
        case .held, .pending: return ""
        case .failed(let status): return " pin=FAILED(\(status))"
        }
    }
}

public struct InputRoute: Equatable {
    public var deviceName: String
    /// For aggregate devices: the member devices that have input streams, as
    /// "Name (transport)". Empty for a plain device.
    public var aggregateInputs: [String]
    public var sampleRate: Int
    public var voiceProcessing: Bool
    public var pin: PinState

    public init(deviceName: String, aggregateInputs: [String] = [], sampleRate: Int,
                voiceProcessing: Bool, pin: PinState) {
        self.deviceName = deviceName
        self.aggregateInputs = aggregateInputs
        self.sampleRate = sampleRate
        self.voiceProcessing = voiceProcessing
        self.pin = pin
    }

    /// Log form. Keeps the historical prefix "<name> @ <rate> Hz" so old log greps still work:
    ///   MacBook Pro Microphone @ 44100 Hz
    ///   CADefaultDeviceAggregate-16073-6 [in: AirPods (bluetooth)] @ 24000 Hz pin=FAILED(-10851)
    public var description: String {
        let members = aggregateInputs.isEmpty ? "" : " [in: \(aggregateInputs.joined(separator: ", "))]"
        let vp = voiceProcessing ? " +vp" : ""
        return "\(deviceName)\(members) @ \(sampleRate) Hz\(vp)\(pin.note)"
    }

    /// Menu form (Dictation Settings › Input): the real microphone, never an aggregate's
    /// internal name, plus plain-language notes when it matters for quality.
    ///   MacBook Pro Microphone · 44 kHz
    ///   AirPods · 24 kHz · headset mic, lower quality · couldn't switch to built-in
    public var menuTitle: String {
        let name: String
        if aggregateInputs.isEmpty {
            name = deviceName
        } else {
            name = aggregateInputs.map { member -> String in
                guard let open = member.lastIndex(of: "(") else { return member }
                return member[..<open].trimmingCharacters(in: .whitespaces)
            }.joined(separator: " + ")
        }
        var parts = [name, "\(sampleRate / 1000) kHz"]
        // Voice processing has its own menu line ("Voice filtering: …"); not repeated here.
        if mayBeHeadsetMic { parts.append("headset mic, lower quality") }
        if case .failed = pin { parts.append("couldn't switch to built-in") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// True when the effective input may be a Bluetooth headset mic (telephony-quality audio,
    /// the known cause of garbage transcripts) — worth surfacing beyond the log.
    public var mayBeHeadsetMic: Bool {
        if deviceName.localizedCaseInsensitiveContains("airpods") { return true }
        return aggregateInputs.contains { $0.hasSuffix("(bluetooth)") }
    }
}

public enum RoutePolicy {
    /// Should the warm path re-apply the built-in pin before starting?
    ///
    /// - wanted: the user's "Use Built-in Microphone" preference.
    /// - builtIn: the built-in mic's CoreAudio id (nil when there is none).
    /// - currentInputs: what capture takes input from — the device, or an aggregate's input
    ///   members (voice processing always wraps the mic in an aggregate, so comparing the device
    ///   id alone would call a held pin "drifted" forever).
    /// - current / refusedFor: the current device id (0 = unreadable) and the device that was
    ///   current right after the last refused pin. A refused route is not retried on every key
    ///   press (each retry tears the warm tap down); a new route gets a fresh attempt.
    public static func needsRepin(wanted: Bool, builtIn: UInt32?, currentInputs: [UInt32],
                                  current: UInt32, refusedFor: UInt32?) -> Bool {
        guard wanted, let builtIn else { return false }
        if currentInputs.contains(builtIn) { return false }
        if let refusedFor, refusedFor == current { return false }
        return true
    }

    /// Classify a pin attempt from the set call's status and what capture reads back afterwards.
    public static func pinResult(setStatus: Int32, builtIn: UInt32, readBackInputs: [UInt32])
        -> PinState
    {
        if setStatus != 0 { return .failed(setStatus) }
        // A clean status that does not read back means the unit silently kept its old device.
        return readBackInputs.contains(builtIn) ? .held : .failed(-1)
    }

    /// "bluetooth" / "built-in" / "usb" / … from a CoreAudio transport FourCC.
    public static func transportName(_ fourCC: UInt32) -> String {
        switch fourCC {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
            kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "continuity"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        default: return "other"
        }
    }
}
