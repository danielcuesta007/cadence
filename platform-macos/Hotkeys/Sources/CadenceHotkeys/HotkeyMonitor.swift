// HotkeyMonitor — global PTT + cancel via a CGEvent tap (§12.4).
//
// Two push-to-talk keys, so a bilingual user never pays for language detection: hold
// Right-Option (keycode 61) or Left-Option (58), and the app pins the language bound to
// whichever key was used. Esc cancels while a dictation is active (consumed so it doesn't
// also hit the target app). Everything else passes through untouched. The tap is re-enabled
// if macOS disables it for latency — user input must never stay blocked because of us (§16.3).
//
// Why the two Option keys and not, say, Right-Control: Apple laptops don't have one. The
// MacBook bottom row is fn / control / option / command / space / command / option / arrows —
// a single Control, on the left. Right-Shift types capitals and Right-Command is half of every
// right-handed ⌘ shortcut, which leaves the Option pair as the only two keys that are both
// present and unclaimed.
//
// Both Option keys raise the same .maskAlternate, so telling them apart needs the
// device-dependent bits (NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK from IOLLEvent.h) rather
// than the general mask — see `isDown`.
//
// Left-Option is the more dangerous binding of the two, because it is the Option people
// actually use: ⌥e for an accent, ⌃⌥⌘Z to undo. Two retractions defend it — see the `cancel`
// paths in PTTArbiter.

import AppKit
import CoreGraphics

/// Which push-to-talk key fired. Each is bound to its own language by the app layer.
public enum PTTKey: String {
    case primary  // Right-Option
    case secondary  // Left-Option
}

/// How forgiving the hands-free gesture is. Two separate limits, because they answer
/// different questions: `maxTapDuration` decides whether the FIRST press was a tap (a longer
/// first press is an ordinary hold and stops the instant it is released), while
/// `interTapGap` is how long after that tap's release the second press may still arrive.
/// The second press may be any length (tap-then-hold): it latches hands-free the moment it
/// goes down, so the pill says so while the key is still held.
public struct PTTTiming: Equatable {
    public var maxTapDuration: TimeInterval
    public var interTapGap: TimeInterval
    /// Holding the first press this long switches to long dictation: it latches hands-free,
    /// so the hand can let go and one tap finishes. Daniel (3 Nov 2026): "i want to hold to
    /// trigger long dication afet a certian amount i want th epill to show 'long dication
    /// enabled'". Only while hands-free is on in Settings.
    public var longHold: TimeInterval

    public init(maxTapDuration: TimeInterval, interTapGap: TimeInterval,
                longHold: TimeInterval = PTTTiming.defaultLongHold) {
        self.maxTapDuration = maxTapDuration
        self.interTapGap = interTapGap
        self.longHold = longHold
    }

    /// Longer than almost any quick dictation, so short notes never latch by accident.
    public static let defaultLongHold: TimeInterval = 10

    /// Daniel asked twice for more forgiveness (1 Nov 2026), so the pause allowed between
    /// taps is the macOS double-click speed plus `extraGap`: 0.7 s at the 0.5 s default.
    public static let standard = PTTTiming(maxTapDuration: 0.45, interTapGap: 0.7)
    public static let extraGap: TimeInterval = 0.2
    /// Never stricter than 0.6 s, and capped at 1 s so a lone short tap still stops promptly.
    public static let gapRange: ClosedRange<TimeInterval> = 0.6...1.0

    /// Follows the user's own double-click speed (System Settings › Accessibility › Pointer
    /// Control) with `extraGap` on top, so someone who has told macOS they click slowly gets
    /// more here too. Clamped to `gapRange`; a missing or invalid reading means `standard`.
    public static func following(doubleClickInterval: TimeInterval) -> PTTTiming {
        guard doubleClickInterval.isFinite, doubleClickInterval > 0 else { return .standard }
        let gap = min(max(doubleClickInterval + extraGap, gapRange.lowerBound), gapRange.upperBound)
        return PTTTiming(maxTapDuration: standard.maxTapDuration, interTapGap: gap)
    }
}

/// The push-to-talk arbitration rules, factored out of the event tap so they can be exercised
/// without synthesizing CGEvents (the Swift layer has no XCTest — see `cadence
/// selftest-hotkeys`). Three invariants live here:
///
/// 1. **One dictation at a time.** A second PTT pressed while another is held is ignored, and
///    only the key that started an utterance can end it — otherwise the two languages could
///    interleave mid-utterance, or a stray release could cut a live dictation short.
/// 2. **A chord is not a PTT.** If another real modifier is already down the user is typing a
///    shortcut, not starting to speak.
/// 3. **A hold can be retracted.** Invariant 2 only catches chords whose *other* modifier
///    lands first. Press Option before Control in ⌃⌥⌘Z — which is the natural order for a
///    left hand — and the dictation has already started by the time the chord is
///    recognisable. So anything that proves the user was not speaking retracts it: a foreign
///    modifier arriving mid-hold, or any ordinary key being typed. The latter is what makes
///    ⌥e (é) safe. Retraction happens within milliseconds of the press, before there is any
///    speech to lose, and it must fire exactly once — the eventual key release is then a
///    no-op, since nothing is held any more.
public struct PTTArbiter {
    public enum Decision: Equatable {
        case start(PTTKey)
        case stop(PTTKey)
        case cancel(PTTKey)
        case ignore
    }

    public private(set) var held: PTTKey?
    public private(set) var latched = false
    public private(set) var deadline: TimeInterval?
    private var pressedAt: TimeInterval = 0
    private var secondTap = false
    private var physicalDown = false
    /// The press that latched hands-free is still down; its release must not finish.
    private var latchPress = false
    /// This gesture follows the hands-free rules (Settings › hands-free on).
    private var gestureHandsFree = false
    /// Hands-free was latched by holding past `timing.longHold`, not by a double tap.
    public private(set) var latchedByHold = false
    /// Read at the start of each gesture by the monitor; fixed for the gesture's lifetime.
    public var timing: PTTTiming

    public init(timing: PTTTiming = .standard) { self.timing = timing }

    /// A tap was released and recording continues while a second tap may still latch
    /// hands-free. The pill says so, so a hesitant user knows the first tap registered.
    /// Stays true while the second press is down, so the hint does not flicker off mid-tap.
    public var awaitingSecondTap: Bool { deadline != nil && !latched && !physicalDown }

    public mutating func resolve(key: PTTKey, down: Bool, otherModifiers: Bool,
                                 now: TimeInterval = 0, handsFree: Bool = false) -> Decision {
        if !handsFree {
            if down {
                guard held == nil, !otherModifiers else { return .ignore }
                held = key
                return .start(key)
            }
            guard held == key else { return .ignore }
            held = nil
            return .stop(key)
        }
        if down {
            guard !otherModifiers, !physicalDown, held == nil || held == key else { return .ignore }
            gestureHandsFree = true
            physicalDown = true
            pressedAt = now
            // Strictly before the deadline: at the deadline itself `expire` has already
            // stopped the first tap, and the two must agree on which side the edge falls.
            let inGap = deadline.map { now < $0 } ?? false
            deadline = nil
            if held == nil {
                held = key
                return .start(key)
            }
            // The second press latches on the way DOWN, whatever its length (tap-then-hold),
            // so the pill reads hands-free while it is held and a late brush of another key
            // cannot throw the speech away. A chord within the first instant still retracts.
            if inGap, !latched {
                latched = true
                latchPress = true
                secondTap = true
            }
            return .ignore
        }
        guard held == key, physicalDown else { return .ignore }
        physicalDown = false
        if latchPress {
            latchPress = false
            secondTap = false
            return .ignore
        }
        // Once latched, one clean owner-key release finishes. Chords/typing call
        // retract(), clearing physicalDown, so their releases cannot finish speech.
        if latched {
            reset()
            return .stop(key)
        }
        // Only the FIRST press must be a tap, so a plain hold stays push-to-talk.
        if now - pressedAt <= timing.maxTapDuration {
            deadline = now + timing.interTapGap
            return .ignore
        }
        reset()
        return .stop(key)
    }

    /// When a still-held first press will turn into long dictation; nil if it cannot.
    public var longHoldAt: TimeInterval? {
        guard gestureHandsFree, physicalDown, held != nil, !latched, deadline == nil else { return nil }
        return pressedAt + timing.longHold
    }

    /// The first press has been held past `timing.longHold`: latch hands-free so letting go
    /// keeps recording. Returns true when it latched. The press is still down, so its release
    /// is swallowed like a tap-then-hold second press.
    public mutating func holdElapsed(now: TimeInterval) -> Bool {
        guard let at = longHoldAt, now >= at else { return false }
        latched = true
        latchPress = true
        latchedByHold = true
        return true
    }

    public mutating func expire(now: TimeInterval) -> Decision {
        guard let deadline, now >= deadline else { return .ignore }
        self.deadline = nil
        guard !latched, let key = held else { return .ignore }
        reset()
        return .stop(key)
    }

    public mutating func reset() {
        latchPress = false
        latchedByHold = false
        gestureHandsFree = false
        held = nil
        latched = false
        deadline = nil
        physicalDown = false
        secondTap = false
    }

    /// `now` defaults to "long after the press": callers without a clock keep speech.
    public mutating func retract(now: TimeInterval = .infinity) -> Decision {
        // A chord on the press that just latched (⌥e as the second press) is typing, not
        // speech: retract it like any accidental hold.
        if latched, latchPress, now - pressedAt <= timing.maxTapDuration, let key = held {
            reset()
            return .cancel(key)
        }
        // Hands-free dictation permits ordinary typing and modifier shortcuts.
        if latched {
            latchPress = false
            deadline = nil
            secondTap = false
            physicalDown = false
            return .ignore
        }
        guard let key = held else { return .ignore }
        reset()
        return .cancel(key)
    }

}

public final class HotkeyMonitor {
    public var onPTTDown: ((PTTKey) -> Void)?
    public var onPTTUp: ((PTTKey) -> Void)?
    /// A hold was retracted before it counted as speech (chord or typing). Distinct from
    /// onPTTUp: there is no utterance to finish, only one to throw away.
    public var onPTTCancel: ((PTTKey) -> Void)?
    public var onCancel: (() -> Void)?
    /// §7 F21: dedicated undo-last-dictation chord (⌃⌥⌘Z), consumed when handled.
    public var onUndo: (() -> Void)?
    /// §7 F15: verbatim on/off chord (⌃⌥⌘V), consumed when handled.
    public var onToggleVerbatim: (() -> Void)?
    /// Governs Esc consumption; read on the tap thread (main run loop).
    public var isActive: () -> Bool = { false }
    /// The second key is opt-out: when this returns false Left-Option is ignored entirely,
    /// so a user who needs it for typing can turn the whole binding off.
    public var secondaryEnabled: () -> Bool = { true }

    public var handsFreeEnabled: () -> Bool = { true }
    public var onHandsFreeChanged: ((Bool) -> Void)?
    /// True while a first tap waits for its second (recording is already running).
    public var onTapPendingChanged: ((Bool) -> Void)?
    /// Read once per gesture, so a settings change never reshapes a gesture in flight.
    public var timing: () -> PTTTiming = {
        PTTTiming.following(doubleClickInterval: NSEvent.doubleClickInterval)
    }
    private var releaseTimer: Timer?
    private var holdTimer: Timer?
    private var tapPending = false
    /// The current hands-free latch came from a long hold (the pill says "long dictation").
    public var latchedByHold: Bool { arbiter.latchedByHold }

    public func resetGesture() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        holdTimer?.invalidate()
        holdTimer = nil
        arbiter.reset()
        onHandsFreeChanged?(false)
        publishTapPending()
    }

    private func publishTapPending() {
        let now = arbiter.awaitingSecondTap
        guard now != tapPending else { return }
        tapPending = now
        onTapPendingChanged?(now)
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Owns the "which key is held" state; see PTTArbiter for the rules it enforces.
    private var arbiter = PTTArbiter()
    /// The chord whose first press we handled; its auto-repeats are swallowed.
    private var firedChord: Chord?

    private static let kRightOption: Int64 = 61
    private static let kLeftOption: Int64 = 58
    private static let kEscape: Int64 = 53
    private static let kReturn: Int64 = 36
    private static let kEnter: Int64 = 76  // keypad Enter, and fn-Return on a laptop
    private static let kZ: Int64 = 6
    private static let kV: Int64 = 9
    /// Device-dependent modifier bits (IOLLEvent.h). The general .maskAlternate cannot tell
    /// the two Option keys apart, and both PTT keys are Option keys.
    private static let deviceLeftAlt: UInt64 = 0x0000_0020
    private static let deviceRightAlt: UInt64 = 0x0000_0040

    public init() {}

    /// Returns false when the event tap can't be created (Accessibility not granted).
    public func start() -> Bool {
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        resetGesture()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let active = arbiter.held
            resetGesture()
            if let active { onPTTCancel?(active) }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged {
            if keyCode == Self.kRightOption {
                update(key: .primary, down: isDown(.primary, event.flags), flags: event.flags)
                return Unmanaged.passUnretained(event)
            }
            if keyCode == Self.kLeftOption, secondaryEnabled() {
                update(key: .secondary, down: isDown(.secondary, event.flags), flags: event.flags)
                return Unmanaged.passUnretained(event)
            }
            // Some *other* modifier moved. If a PTT is held, the user is assembling a chord
            // (⌃⌥⌘Z with a left hand presses Option first), so retract the dictation.
            retractIfChording(flags: event.flags)
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, keyCode == Self.kEscape, isActive() {
            resetGesture()
            DispatchQueue.main.async { self.onCancel?() }
            return nil // consumed: cancel must not also close the user's dialog/sheet
        }
        // Typing while a PTT is held is not speech — it is ⌥e for an accent, or a shortcut.
        // Retract rather than transcribe silence. Esc above has already been handled.
        if type == .keyDown, arbiter.held != nil, Self.typingRetracts(keyCode: keyCode) {
            fire(arbiter.retract(now: ProcessInfo.processInfo.systemUptime))
            publishTapPending()
        }
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyDown, !repeating { firedChord = nil }
        if type == .keyDown,
            let action = Self.chordAction(
                keyCode: keyCode, flags: event.flags, autorepeat: repeating, fired: firedChord)
        {
            switch action {
            case .swallow:
                return nil // a held chord's repeat: ours, but already handled
            case .fire(let chord):
                let handler: (() -> Void)?
                switch chord {
                case .undo: handler = onUndo
                case .toggleVerbatim: handler = onToggleVerbatim
                }
                if let handler {
                    firedChord = chord
                    DispatchQueue.main.async { handler() }
                    return nil // consumed: the chord is ours alone
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Whether a key typed during a held push-to-talk retracts it. Return and Enter do not:
    /// hitting one by accident must not cancel a dictation. Pure, so `cadence selftest-hotkeys` pins it.
    public static func typingRetracts(keyCode: Int64) -> Bool {
        keyCode != kReturn && keyCode != kEnter
    }

    /// The app's own chords, all on ⌃⌥⌘ so none can collide with a plain shortcut — ⌘V in
    /// particular must stay the user's paste. Pure, so `cadence selftest-hotkeys` pins it.
    public enum Chord: Equatable { case undo, toggleVerbatim }

    public enum ChordAction: Equatable { case fire(Chord), swallow }

    /// A held chord's repeats are not new presses (a toggle must flip once), but they are
    /// still ours: passed on, they would fire the frontmost app's own ⌃⌥⌘V / ⌃⌥⌘Z. Only
    /// repeats of a press we actually fired, though — `fired` — or an app's own held ⌘V
    /// that picks up ⌃⌥ midway would vanish.
    public static func chordAction(
        keyCode: Int64, flags: CGEventFlags, autorepeat: Bool, fired: Chord?
    ) -> ChordAction? {
        guard let chord = chord(keyCode: keyCode, flags: flags) else { return nil }
        if !autorepeat { return .fire(chord) }
        return chord == fired ? .swallow : nil
    }

    public static func chord(keyCode: Int64, flags: CGEventFlags) -> Chord? {
        let mods: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        guard flags.isSuperset(of: mods) else { return nil }
        switch keyCode {
        case kZ: return .undo
        case kV: return .toggleVerbatim
        default: return nil
        }
    }

    /// Is this specific Option key physically down? Both raise .maskAlternate, so the general
    /// mask would report the left key as down while only the right one is held.
    private func isDown(_ key: PTTKey, _ flags: CGEventFlags) -> Bool {
        let bit = key == .primary ? Self.deviceRightAlt : Self.deviceLeftAlt
        return flags.rawValue & bit != 0
    }

    /// Edge-detect one PTT key: translate CGEvent flags into the pure arbiter's terms, then
    /// fan the decision out to the app layer.
    private func update(key: PTTKey, down: Bool, flags: CGEventFlags) {
        // Option is excluded from the "foreign modifier" set because both PTT keys are Option
        // keys — the other one being down is the arbiter's business, not a chord signal.
        let chordMods: CGEventFlags = [.maskCommand, .maskControl, .maskShift]
        let others = !flags.intersection(chordMods).isEmpty
        // Resolve an elapsed first tap before a later press can steal its pending stop.
        // One clock read: expire and resolve must judge the same instant, or a press landing
        // on the deadline could be neither a second tap nor a fresh start.
        let now = ProcessInfo.processInfo.systemUptime
        fire(arbiter.expire(now: now))
        let wasLatched = arbiter.latched
        if down, arbiter.held == nil { arbiter.timing = timing() }
        fire(arbiter.resolve(key: key, down: down, otherModifiers: others,
                             now: now, handsFree: handsFreeEnabled()))
        if wasLatched != arbiter.latched { onHandsFreeChanged?(arbiter.latched) }
        scheduleExpiry()
        scheduleLongHold()
        publishTapPending()
    }

    /// Arms the long-dictation latch for a held first press. Re-arms if it fires early.
    private func scheduleLongHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard let at = arbiter.longHoldAt else { return }
        let timer = Timer(timeInterval: max(0, at - ProcessInfo.processInfo.systemUptime),
                          repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.arbiter.holdElapsed(now: ProcessInfo.processInfo.systemUptime) {
                self.onHandsFreeChanged?(true)
            } else {
                self.scheduleLongHold()
            }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Arms the lone-tap stop. If the timer ever fires before the deadline (run-loop
    /// coalescing), it re-arms instead of leaving a lone tap recording forever.
    private func scheduleExpiry() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        guard let deadline = arbiter.deadline else { return }
        let timer = Timer(timeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime),
                          repeats: false) { [weak self] _ in
            guard let self else { return }
            self.fire(self.arbiter.expire(now: ProcessInfo.processInfo.systemUptime))
            self.scheduleExpiry()
            self.publishTapPending()
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// A non-PTT modifier moved: retract any hold it just turned into a chord.
    private func retractIfChording(flags: CGEventFlags) {
        guard arbiter.held != nil else { return }
        let chordMods: CGEventFlags = [.maskCommand, .maskControl, .maskShift]
        guard !flags.intersection(chordMods).isEmpty else { return }
        fire(arbiter.retract(now: ProcessInfo.processInfo.systemUptime))
        publishTapPending()
    }

    private func fire(_ decision: PTTArbiter.Decision) {
        switch decision {
        case .start(let k): DispatchQueue.main.async { self.onPTTDown?(k) }
        case .stop(let k): DispatchQueue.main.async { self.onPTTUp?(k) }
        case .cancel(let k): DispatchQueue.main.async { self.onPTTCancel?(k) }
        case .ignore: break
        }
    }
}
