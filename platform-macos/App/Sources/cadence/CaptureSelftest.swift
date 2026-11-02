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
    check("repin_when_drifted", RoutePolicy.needsRepin(wanted: true, builtIn: 10, current: 77, refusedFor: nil))
    check("no_repin_when_held", !RoutePolicy.needsRepin(wanted: true, builtIn: 10, current: 10, refusedFor: nil))
    check("no_repin_when_unwanted", !RoutePolicy.needsRepin(wanted: false, builtIn: 10, current: 77, refusedFor: nil))
    check("no_repin_without_built_in", !RoutePolicy.needsRepin(wanted: true, builtIn: nil, current: 77, refusedFor: nil))
    check("refused_route_not_hammered", !RoutePolicy.needsRepin(wanted: true, builtIn: 10, current: 77, refusedFor: 77))
    check("new_route_gets_fresh_attempt", RoutePolicy.needsRepin(wanted: true, builtIn: 10, current: 88, refusedFor: 77))
    check("unknown_current_repins", RoutePolicy.needsRepin(wanted: true, builtIn: 10, current: nil, refusedFor: nil))

    // Pin outcome classification.
    check("pin_held", RoutePolicy.pinResult(setStatus: 0, builtIn: 10, readBack: 10) == .held)
    check("pin_error_status", RoutePolicy.pinResult(setStatus: -10851, builtIn: 10, readBack: 77) == .failed(-10851))
    check("silent_pin_failure_caught", RoutePolicy.pinResult(setStatus: 0, builtIn: 10, readBack: 77) == .failed(-1))

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
