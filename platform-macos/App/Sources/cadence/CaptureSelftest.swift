// CaptureSelftest — headless checks of the input-route logic (`cadence selftest-capture`).
// Step 15: the log must say which microphone a dictation used, and the built-in pin must be
// re-asserted when the route drifts without hammering a pin the system refused. No audio I/O.
import CadenceCapture
import CoreAudio
import Foundation

func runCaptureSelftest() -> Int32 {
    var checks: [[String: Any]] = []
    func check(_ name: String, _ pass: Bool) { checks.append(["name": name, "pass": pass]) }

    // Log form keeps the historical "<name> @ <rate> Hz" prefix old greps rely on.
    let plain = InputRoute(deviceName: "MacBook Pro Microphone", sampleRate: 44100,
                           voiceProcessing: false, pin: .held)
    check("plain_route_log_unchanged", plain.description == "MacBook Pro Microphone @ 44100 Hz")
    check("built_in_is_not_headset", !plain.mayBeHeadsetMic)

    let agg = InputRoute(deviceName: "CADefaultDeviceAggregate-16073-6",
                         aggregateInputs: ["AirPods (bluetooth)"], sampleRate: 24000,
                         voiceProcessing: false, pin: .failed(-10851))
    check("aggregate_names_real_input_and_failed_pin",
          agg.description == "CADefaultDeviceAggregate-16073-6 [in: AirPods (bluetooth)] @ 24000 Hz pin=FAILED(-10851)")
    check("bluetooth_member_flagged_as_headset", agg.mayBeHeadsetMic)
    let aggBuiltIn = InputRoute(deviceName: "CADefaultDeviceAggregate-1-1",
                                aggregateInputs: ["MacBook Pro Microphone (built-in)"],
                                sampleRate: 44100, voiceProcessing: true, pin: .held)
    check("aggregate_of_built_in_not_headset", !aggBuiltIn.mayBeHeadsetMic)
    check("vp_marker_kept", aggBuiltIn.description.hasSuffix("@ 44100 Hz +vp"))
    check("pin_off_is_explicit",
          InputRoute(deviceName: "AirPods", sampleRate: 24000, voiceProcessing: false, pin: .off)
              .description == "AirPods @ 24000 Hz pin=off")

    // Menu form: real mic names, plain notes, no aggregate internals.
    check("menu_plain", plain.menuTitle == "MacBook Pro Microphone \u{00B7} 44 kHz")
    check("menu_aggregate_headset_failed",
          agg.menuTitle == "AirPods \u{00B7} 24 kHz \u{00B7} headset mic, lower quality \u{00B7} couldn't switch to built-in")
    check("menu_aggregate_built_in_vp",
          aggBuiltIn.menuTitle == "MacBook Pro Microphone \u{00B7} 44 kHz")
    check("menu_hides_aggregate_name", !agg.menuTitle.contains("CADefault"))

    // Re-pin policy.
    func repin(_ wanted: Bool = true, builtIn: UInt32? = 10, inputs: [UInt32], current: UInt32,
               refused: UInt32? = nil) -> Bool {
        RoutePolicy.needsRepin(wanted: wanted, builtIn: builtIn, currentInputs: inputs,
                               current: current, refusedFor: refused)
    }
    check("repin_when_drifted", repin(inputs: [77], current: 77))
    check("no_repin_when_held", !repin(inputs: [10], current: 10))
    check("no_repin_when_aggregate_wraps_built_in", !repin(inputs: [10], current: 500))
    check("no_repin_when_unwanted", !repin(false, inputs: [77], current: 77))
    check("no_repin_without_built_in", !repin(builtIn: nil, inputs: [77], current: 77))
    check("refused_route_not_hammered", !repin(inputs: [77], current: 77, refused: 77))
    check("refused_unreadable_route_not_hammered", !repin(inputs: [], current: 0, refused: 0))
    check("new_route_gets_fresh_attempt", repin(inputs: [88], current: 88, refused: 77))

    // Pin outcome classification.
    check("pin_held", RoutePolicy.pinResult(setStatus: 0, builtIn: 10, readBackInputs: [10]) == .held)
    check("pin_held_through_vp_aggregate",
          RoutePolicy.pinResult(setStatus: 0, builtIn: 10, readBackInputs: [10]) == .held)
    check("pin_error_status",
          RoutePolicy.pinResult(setStatus: -10851, builtIn: 10, readBackInputs: [77]) == .failed(-10851))
    check("silent_pin_failure_caught",
          RoutePolicy.pinResult(setStatus: 0, builtIn: 10, readBackInputs: [77]) == .failed(-1))
    check("pending_pin_is_silent", PinState.pending == .pending
          && InputRoute(deviceName: "Mic", sampleRate: 48000, voiceProcessing: false, pin: .pending)
              .description == "Mic @ 48000 Hz")

    check("transport_bluetooth", RoutePolicy.transportName(kAudioDeviceTransportTypeBluetooth) == "bluetooth")
    check("transport_ble", RoutePolicy.transportName(kAudioDeviceTransportTypeBluetoothLE) == "bluetooth")
    check("transport_built_in", RoutePolicy.transportName(kAudioDeviceTransportTypeBuiltIn) == "built-in")
    check("transport_auto_aggregate", RoutePolicy.transportName(kAudioDeviceTransportTypeAutoAggregate) == "aggregate")

    let pass = checks.allSatisfy { $0["pass"] as? Bool == true }
    if let data = try? JSONSerialization.data(withJSONObject: ["pass": pass, "checks": checks], options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
    print("selftest-capture: \(checks.filter { $0["pass"] as? Bool == true }.count)/\(checks.count) passed")
    return pass ? 0 : 1
}
