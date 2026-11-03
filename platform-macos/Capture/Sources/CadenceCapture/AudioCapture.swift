// AudioCapture — mic → 16 kHz mono i16 chunks for the core ring buffer (§16.1, §18 step 2).
//
// AVAudioEngine (CoreAudio-backed) tap at the device's native format, resampled per chunk
// through AVAudioConverter. Chunks are delivered on the audio tap thread; the core's
// `push_audio` is audio-thread-safe by contract, so the callback forwards directly.
//
// Warm-path design (§28: perceived capture start ≤ 50 ms): the tap + converter are built
// ONCE (and rebuilt only on an audio-route change) — the first live run measured 85–94 ms
// with per-start tap install + cold engine.start(). The engine is fully stopped between
// utterances so the mic-in-use indicator tracks actual listening (§10 privacy), but
// prepare() re-arms immediately after stop; if live numbers are still over target, the
// next lever is engine.pause() — verify the orange dot goes off before shipping that.

import AVFoundation
import CObjCCatch
import CoreAudio
import os

public enum CaptureError: Error, CustomStringConvertible {
    case formatUnavailable
    case engineStart(Error)
    case tapInstall(String)

    public var description: String {
        switch self {
        case .formatUnavailable:
            return "no usable input format (mic permission missing or no input device?)"
        case .engineStart(let e):
            return "audio engine start failed: \(e.localizedDescription)"
        case .tapInstall(let reason):
            return "tap install rejected by AVFAudio: \(reason)"
        }
    }
}

public final class AudioCapture {
    // var, not let: recreated outright when a route change leaves it serving stale
    // formats (reset() proved insufficient live — see start()).
    private var engine = AVAudioEngine()
    private var running = false
    private var tapInstalled = false
    private var tapFormat: AVAudioFormat?
    private var routeChangeObserver: NSObjectProtocol?
    private var rebuildWork: DispatchWorkItem?
    /// Open while an utterance wants audio. The tap drops buffers while it is shut, so a
    /// Bluetooth mic held open between dictations (`bluetoothGrace`) never reaches the core.
    private let gate = OSAllocatedUnfairLock(initialState: false)
    /// Pending real engine stop at the end of a Bluetooth grace period.
    private var graceStop: DispatchWorkItem?

    /// Seconds to keep a Bluetooth (AirPods) mic open after a dictation ends, 0 = off
    /// (default). Daniel (3 Nov 2026): "I would rather keep my music good and then still use
    /// the AirPods microphone." Releasing the AirPods mic flips them back from headset to
    /// music mode, which glitches music right at insert; holding the mic open for a while
    /// moves that one switch to after the last dictation. Audio is NOT delivered or kept
    /// while held (the gate is shut); the mic-in-use indicator stays on until it closes.
    public var bluetoothGrace: TimeInterval = 0
    public static let defaultBluetoothGrace: TimeInterval = 30

    /// (samples16k, level 0…1) — called on the audio tap thread. Only fires while running:
    /// the tap checks this flag so a buffer straggling in after stop() is still delivered
    /// (no-lost-words), but nothing arrives once the engine is stopped.
    public var onChunk: (([Int16], Float) -> Void)?

    /// Always use the built-in mic (default OFF since 2 Nov 2026). Off, capture pins a
    /// connected headset mic (AirPods, USB headset) — the mic at your mouth wins in a loud
    /// room — at the cost of telephony-mode (HFP) audio: music in the earbuds drops to call
    /// quality while dictating. On restores the old built-in-only behaviour.
    public var preferBuiltInMic = false

    /// Apple voice processing on the input (AEC + noise suppression — the "Voice
    /// Isolation" machinery; default OFF, experimental). Enabling helps café/office
    /// ambience, but AUVoiceIO teardown DEADLOCKED the main thread live (2026-07-19
    /// 14:07 sample: AudioComponentInstanceDispose → shared_mutex wait, app frozen) —
    /// stays opt-in until its lifecycle proves trustworthy. If enabling it makes capture
    /// fail, start() drops it for the session rather than cancel dictations.
    public var voiceIsolation = false
    private var vpDisabledFallback = false
    /// Result of the last built-in-mic pin attempt (logged with every capture start).
    private var pinState: PinState = .pending
    /// Device that was current when the system last refused the pin: not retried for that
    /// same route on every key press (see RoutePolicy.needsRepin).
    private var pinRefusedFor: AudioDeviceID?
    /// The mic to pin (RoutePolicy.pinTarget), looked up once per route (cold path, route or
    /// device-list change), never per key press. nil inside = follow the system default.
    private var targetCache: AudioDeviceID??
    /// The device capture pinned explicitly, so un-pinning (headset gone) can hand the unit
    /// back to the system default instead of leaving it on a vanished device. Kept until the
    /// hand-back verifiably succeeds, so a failed hand-back is retried.
    private var pinnedDevice: AudioDeviceID?
    /// CoreAudio device-list listener: earbuds connecting/disconnecting re-pick the mic.
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    public func setPreferBuiltInMic(_ on: Bool) {
        guard on != preferBuiltInMic else { return }
        preferBuiltInMic = on
        targetCache = nil  // mid-capture too: the next start() re-picks and re-pins
        applyConfigChange()
    }

    public func setVoiceIsolation(_ on: Bool) {
        guard on != voiceIsolation else { return }
        voiceIsolation = on
        vpDisabledFallback = false
        applyConfigChange()
    }

    private func applyConfigChange() {
        guard !running else { return } // mid-capture: applies at the next start
        recreateEngine()
        prewarm()
    }

    /// Actual engine state, including session fallback; distinct from the saved preference.
    public var voiceProcessingActive: Bool { engine.inputNode.isVoiceProcessingEnabled }

    /// What capture is listening through right now, including aggregate members and whether
    /// the built-in pin held. `inputDescription` is its log form.
    public var currentRoute: InputRoute {
        let fmt = engine.inputNode.inputFormat(forBus: 0)
        var name = "default input"
        var members: [String] = []
        if let dev = currentDevice() {
            name = Self.deviceName(dev) ?? name
            var ids = Self.aggregateInputMemberIDs(dev)
            // An aggregate lists every member that HAS input streams (output-only AirPods
            // included), not the one it takes input from. When the built-in is a member, it is
            // the one capture selected (pin / voice processing), so report just it.
            // Cached pick, else the default input: one property read, no device scan per press.
            if let t = pinTarget() ?? Self.defaultInputDevice(), ids.contains(t) { ids = [t] }
            members = ids.map(Self.memberLabel)
        }
        return InputRoute(
            deviceName: name, aggregateInputs: members, sampleRate: Int(fmt.sampleRate),
            voiceProcessing: engine.inputNode.isVoiceProcessingEnabled,
            pin: pinState)
    }

    /// Log form, e.g. "MacBook Pro Microphone @ 44100 Hz".
    public var inputDescription: String { currentRoute.description }

    private func currentDevice() -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &dev, &size) == noErr, dev != 0
        else { return nil }
        return dev
    }

    /// Devices capture is effectively taking input from: the device itself, or an aggregate's
    /// input-capable members (AUVoiceIO and AVAudioEngine both wrap the mic in one).
    private func currentInputs() -> [AudioDeviceID] {
        guard let dev = currentDevice() else { return [] }
        let members = Self.aggregateInputMemberIDs(dev)
        return members.isEmpty ? [dev] : members
    }

    private func pinTarget() -> AudioDeviceID? {
        if let cached = targetCache { return cached }
        let found = Self.pick(preferBuiltIn: preferBuiltInMic)
        targetCache = .some(found)
        return found
    }

    private func setUnitDevice(_ device: AudioDeviceID) -> OSStatus {
        guard let unit = engine.inputNode.audioUnit else { return -1 }
        var id = device
        return AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Point capture at the chosen mic (RoutePolicy.pinTarget); records the outcome in
    /// pinState. Called on the cold path only (tap rebuild), so the device scan is not per
    /// key press.
    private func applyPin() {
        targetCache = nil // cold path: the device list may have changed
        guard let target = pinTarget() else {
            pinState = preferBuiltInMic ? .noBuiltIn : .off
            pinRefusedFor = nil
            // A headset we pinned went away: hand the unit back to the system default rather
            // than leave it bound to a device that no longer exists. Only forget the pin once
            // the default is a different device and the set reads back; otherwise retry later.
            if let pinned = pinnedDevice, let def = Self.defaultInputDevice(), def != pinned,
                setUnitDevice(def) == noErr, currentInputs().contains(def) {
                pinnedDevice = nil
            }
            return
        }
        if currentInputs().contains(target) {
            pinState = .held
            pinRefusedFor = nil
            return
        }
        let status = setUnitDevice(target)
        pinnedDevice = target
        pinState = RoutePolicy.pinResult(
            setStatus: status, target: target, readBackInputs: currentInputs())
        // Key the refusal on the route as it stands AFTER the attempt — that is what the warm
        // path compares against (0 = unreadable), so a refused route is not retried per press.
        if case .failed = pinState { pinRefusedFor = currentDevice() ?? 0 } else { pinRefusedFor = nil }
    }

    // MARK: - CoreAudio device selection

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &nameRef) == noErr,
            let name = nameRef?.takeRetainedValue()
        else { return nil }
        return name as String
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector)
        -> UInt32?
    {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// For an aggregate (incl. AVAudioEngine's auto "CADefaultDeviceAggregate" and AUVoiceIO's),
    /// the active members that have input streams. Empty for a plain device.
    private static func aggregateInputMemberIDs(_ id: AudioDeviceID) -> [AudioDeviceID] {
        guard let t = uint32Property(id, kAudioDevicePropertyTransportType),
            RoutePolicy.transportName(t) == "aggregate"
        else { return [] }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var subs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &subs) == noErr else { return [] }
        return subs.filter(hasInputStreams)
    }

    /// "Name (transport)" for the log and menu.
    private static func memberLabel(_ id: AudioDeviceID) -> String {
        let transport = uint32Property(id, kAudioDevicePropertyTransportType)
            .map(RoutePolicy.transportName) ?? "other"
        return "\(deviceName(id) ?? "device \(id)") (\(transport))"
    }

    private let listenerQueue = DispatchQueue(label: "cadence.capture.devices", qos: .utility)

    private static func pick(preferBuiltIn: Bool) -> AudioDeviceID? {
        RoutePolicy.pinTarget(
            preferBuiltIn: preferBuiltIn, devices: inputCandidates(),
            defaultInput: defaultInputDevice())
    }

    /// Every device with input streams, with its transport, in CoreAudio's order.
    private static func inputCandidates() -> [InputCandidate] {
        allDeviceIDs().compactMap { id in
            guard hasInputStreams(id),
                let transport = uint32Property(id, kAudioDevicePropertyTransportType)
            else { return nil }
            return InputCandidate(id: id, transport: transport)
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        let v = uint32Property(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return (v ?? 0) == 0 ? nil : v
    }

    /// Re-pick the mic when devices come and go (earbuds in/out). The engine's own
    /// config-change notification only fires when ITS device changes — a pinned engine never
    /// hears AirPods connecting. Debounced onto the same rebuild as a route change.
    private func installDeviceListListener() {
        guard deviceListListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Runs on a utility queue: CoreAudio adds/removes hidden aggregate devices around
        // every capture, and the device scan must not compete with capture start on main.
        // Those aggregates are never candidates, so only a real change of pick (earbuds
        // in/out) rebuilds — otherwise each dictation would tear down the warm tap.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let builtInOnly = DispatchQueue.main.sync { self.preferBuiltInMic }
            let fresh = Self.pick(preferBuiltIn: builtInOnly)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .some(let cached) = self.targetCache, cached == fresh { return }
                self.scheduleRouteRebuild()
            }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block) == noErr {
            deviceListListener = block
        }
    }

    /// Debounced rebuild against the current route (main queue). Mid-capture it only drops
    /// the cached pick: the next start()'s drift check re-pins.
    private func scheduleRouteRebuild() {
        targetCache = nil
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.running else { return }
            self.endGrace()  // a held-open mic on the old route closes before the rebuild
            self.targetCache = nil
            self.teardownTap()
            self.prewarm()
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    public init() {}

    deinit {
        if let o = routeChangeObserver { NotificationCenter.default.removeObserver(o) }
        if let block = deviceListListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block)
        }
    }

    public static func micAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Resolves mic permission, prompting if undetermined (§10.1: just-in-time, with payoff).
    public static func requestMicAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: done)
        default: done(false)
        }
    }

    /// Pay the one-time costs (tap install, converter build, engine prepare) at app load
    /// instead of on the first key-down. Does NOT start audio I/O — no mic indicator.
    /// Safe to call without mic permission (start() will re-derive if this failed).
    public func prewarm() {
        try? ensureTap()
        engine.prepare()
    }

    public func start() throws {
        guard !running else { return }
        // Inside a Bluetooth grace period the engine is still running on the same route:
        // reopen the gate instead of restarting it. No mic switch, so no music glitch.
        if graceStop != nil, engine.isRunning, tapInstalled {
            graceStop?.cancel()
            graceStop = nil
            gate.withLock { $0 = true }
            running = true
            return
        }
        endGrace()
        do {
            try startOnce()
        } catch {
            // Route changed under a stale tap. reset() proved insufficient live
            // (2026-07-19 13:03–13:06: four consecutive tap rejections, every dictation
            // cancelling) — an AVAudioEngine can keep serving stale formats for the life
            // of the object. Recreate it outright and retry once.
            recreateEngine()
            do {
                try startOnce()
            } catch {
                // Voice processing itself may be what's failing (AUVoiceIO is the
                // newest, quirkiest piece). Never let a nicety cancel dictations:
                // drop it for the session and go bare before giving up.
                guard voiceIsolation, !vpDisabledFallback else { throw error }
                vpDisabledFallback = true
                recreateEngine()
                try startOnce()
            }
        }
        gate.withLock { $0 = true }
        running = true
    }

    private func startOnce() throws {
        try ensureTap()
        do { try engine.start() } catch { throw CaptureError.engineStart(error) }
    }

    /// Nuclear route-change recovery: discard the engine (its tap dies with it) and start
    /// clean. The config-change observer is engine-bound, so it is re-registered by the
    /// next ensureTap.
    ///
    /// The old engine is disposed on a background queue, NEVER inline: deallocating an
    /// engine whose AUVoiceIO was live deadlocks in AudioComponentInstanceDispose
    /// (froze the whole app on the main thread, 2026-07-19). If Apple's dispose hangs on
    /// the background queue we leak one engine — annoying, invisible, survivable.
    private func recreateEngine() {
        if let o = routeChangeObserver {
            NotificationCenter.default.removeObserver(o)
            routeChangeObserver = nil
        }
        rebuildWork?.cancel()
        graceStop?.cancel()
        graceStop = nil
        gate.withLock { $0 = false }
        let old = engine
        tapInstalled = false
        tapFormat = nil
        pinState = .pending
        pinRefusedFor = nil
        targetCache = nil
        pinnedDevice = nil
        engine = AVAudioEngine()
        DispatchQueue.global(qos: .utility).async {
            old.stop()
            // `old` released here, off the main thread.
        }
    }

    /// Synchronous stop. After return, in-flight tap callbacks have had time to land their
    /// samples, so the caller may safely confirm `capture_stopped` (no-lost-words contract).
    /// Full engine stop (not pause) so the mic-in-use indicator turns off with the capture;
    /// the tap stays installed and prepare() re-arms immediately, keeping the next start warm.
    public func stop() {
        guard running else { return }
        running = false
        if RoutePolicy.holdsMicOpen(grace: bluetoothGrace, transport: inputTransport()) {
            // Let in-flight buffers land (no-lost-words), then shut the gate and keep the
            // engine (and the AirPods mic) running until the grace period ends.
            Thread.sleep(forTimeInterval: 0.02)
            gate.withLock { $0 = false }
            let work = DispatchWorkItem { [weak self] in self?.endGrace() }
            graceStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + bluetoothGrace, execute: work)
            return
        }
        engine.stop()
        Thread.sleep(forTimeInterval: 0.02)
        gate.withLock { $0 = false }
        engine.prepare()
    }

    /// Close a held-open Bluetooth mic now (grace over, route change, setting off, quit).
    public func endGrace() {
        guard let work = graceStop else { return }
        work.cancel()
        graceStop = nil
        guard !running else { return }
        engine.stop()
        engine.prepare()
    }

    /// Transport of the mic capture is actually using ("bluetooth", "built-in", ...).
    private func inputTransport() -> String {
        guard let dev = pinTarget() ?? Self.defaultInputDevice() else { return "other" }
        return Self.uint32Property(dev, kAudioDevicePropertyTransportType)
            .map(RoutePolicy.transportName) ?? "other"
    }

    // MARK: - warm tap

    private func ensureTap() throws {
        if tapInstalled {
            // Trust the format, not the flag: a route change the observer missed (or one
            // that landed mid-debounce) leaves a tap bound to the old sample rate.
            let current = engine.inputNode.inputFormat(forBus: 0)
            let drifted = RoutePolicy.needsRepin(
                target: pinTarget(), unpinNeeded: pinTarget() == nil && pinnedDevice != nil,
                currentInputs: currentInputs(), current: currentDevice() ?? 0,
                refusedFor: pinRefusedFor)
            if !drifted, let f = tapFormat, f.sampleRate == current.sampleRate,
                f.channelCount == current.channelCount {
                return
            }
            teardownTap()
        }
        let input = engine.inputNode
        // Voice processing before anything reads formats — enabling it swaps the
        // underlying unit (AUHAL → AUVoiceIO) and changes the served formats. NSException-
        // fenced like the tap install; a refusal here degrades to bare capture.
        let wantVP = voiceIsolation && !vpDisabledFallback
        if input.isVoiceProcessingEnabled != wantVP {
            let vpFail = CadenceCatchNSException {
                try? input.setVoiceProcessingEnabled(wantVP)
            }
            if vpFail != nil, wantVP {
                vpDisabledFallback = true
            }
        }
        // Pin the built-in mic (when preferred and present) BEFORE reading the format:
        // the AUHAL otherwise follows the system default input, i.e. whatever Bluetooth
        // headset connected last. Failure to pin falls through to the default input.
        // The outcome is recorded (pinState) and logged with every capture start: before Step 15
        // it was discarded, and 22% of live captures logged an opaque aggregate name.
        applyPin()
        // The HARDWARE format, not outputFormat(forBus:): installTap asserts
        // format.sampleRate == inputHWFormat.sampleRate, and the output side can serve a
        // stale rate after a route change (the exact repeated live failure) while
        // inputFormat is the source of truth the assert compares against.
        let inFormat = input.inputFormat(forBus: 0)
        // channelCount too: mid-route-change the node can report 48 kHz / 0 ch, and
        // installTap raises on it.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                interleaved: true),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw CaptureError.formatUnavailable }

        // ~43 ms buffers at 48 kHz: small enough that the ring is near-live, big enough to
        // keep the tap cheap.
        let install = { input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self, let onChunk = self.onChunk, self.gate.withLock({ $0 }) else { return }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
            else { return }
            var fed = false
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData
            else { return }
            let n = Int(out.frameLength)
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
            var acc: Float = 0
            for s in samples {
                let f = Float(s) / 32768
                acc += f * f
            }
            let rms = (acc / Float(max(n, 1))).squareRoot()
            onChunk(samples, min(1.0, rms * 6)) // speech RMS ~0.05–0.15 → usable 0…1 level
        } }
        // AVFAudio raises NSException (not a throw) if the format goes stale between the
        // query above and the install — fatal if unfenced (crashed the resident app
        // 2026-07-18 on a route change). Fenced, it degrades to a throw; the next start()
        // rebuilds cold.
        if let reason = CadenceCatchNSException(install) {
            throw CaptureError.tapInstall(reason)
        }
        tapInstalled = true
        tapFormat = inFormat
        engine.prepare()

        // Device/route changes (AirPods connect, display mic, …) invalidate the tap's
        // format and converter: tear down so the next start() rebuilds against the new route.
        // Rebuild on the main queue, debounced: changes arrive in bursts on arbitrary
        // threads, and re-tapping while the engine is still reconfiguring is what raised.
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                self?.scheduleRouteRebuild()  // mid-capture: start() rebuilds after
            }
        }
        installDeviceListListener()
    }

    private func teardownTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        tapFormat = nil
    }
}
