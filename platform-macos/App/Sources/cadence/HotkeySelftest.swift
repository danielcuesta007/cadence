// Pure-logic checks for the two-key push-to-talk binding (§12.4) and the language pairing
// shown in the menu. The Swift layer has no XCTest (Command Line Tools only), so the pattern
// here is the same one `insertctl selftest` and `cadence selftest-stats` use: exercise the
// pure types directly and print a JSON verdict.
//
//   cadence selftest-hotkeys
//
// What is worth pinning: the arbitration rules are invisible in normal use and fail silently.
// A regression would not crash — it would let two languages interleave in one utterance, let
// ⌃⌥⌘Z quietly open a dictation while undoing one, or leave a stray empty utterance behind
// every time the user types an accented character with ⌥.

import CadenceHotkeys
import CadenceOverlay
import CoreGraphics
import Foundation

private struct HotkeyCheck: Encodable {
    let name: String
    let pass: Bool
    let detail: String?
}

func runHotkeySelftest() -> Int32 {
    var checks: [HotkeyCheck] = []
    func check(_ name: String, _ pass: Bool, _ detail: String? = nil) {
        checks.append(HotkeyCheck(name: name, pass: pass, detail: pass ? nil : detail))
    }

    // 1. The ordinary round trip on each key.
    for key in [PTTKey.primary, PTTKey.secondary] {
        var a = PTTArbiter()
        let down = a.resolve(key: key, down: true, otherModifiers: false)
        let up = a.resolve(key: key, down: false, otherModifiers: false)
        check(
            "\(key.rawValue)_round_trip", down == .start(key) && up == .stop(key),
            "got \(down) then \(up)")
        check("\(key.rawValue)_releases_hold", a.held == nil, "held is \(String(describing: a.held))")
    }

    // 2. One dictation at a time: the second key pressed mid-utterance is ignored, and the
    //    utterance still belongs to the key that started it.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .primary, down: true, otherModifiers: false)
        let intruder = a.resolve(key: .secondary, down: true, otherModifiers: false)
        check("second_key_ignored_while_held", intruder == .ignore, "got \(intruder)")
        check("hold_still_primary", a.held == .primary, "held is \(String(describing: a.held))")
    }

    // 3. Only the owning key can end the utterance — releasing the other one is a no-op, not
    //    a stop. This is what keeps a stray modifier from cutting a dictation short.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .primary, down: true, otherModifiers: false)
        let wrong = a.resolve(key: .secondary, down: false, otherModifiers: false)
        check("foreign_release_is_noop", wrong == .ignore, "got \(wrong)")
        check("still_held_after_foreign_release", a.held == .primary, "held is \(String(describing: a.held))")
        let right = a.resolve(key: .primary, down: false, otherModifiers: false)
        check("owner_release_stops", right == .stop(.primary), "got \(right)")
    }

    // 4. A chord is not a PTT, when the other modifier lands first.
    for key in [PTTKey.primary, PTTKey.secondary] {
        var a = PTTArbiter()
        let d = a.resolve(key: key, down: true, otherModifiers: true)
        check("\(key.rawValue)_chord_not_ptt", d == .ignore, "got \(d)")
        check("\(key.rawValue)_chord_leaves_idle", a.held == nil, "held is \(String(describing: a.held))")
    }

    // 4b. …and when it lands second, the hold is retracted. This is the ⌃⌥⌘Z case that
    //     actually happens: a left hand presses Option before Control, so the dictation has
    //     already started by the time the chord is recognisable.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .secondary, down: true, otherModifiers: false)
        let r = a.retract()
        check("late_chord_retracts", r == .cancel(.secondary), "got \(r)")
        check("retract_clears_hold", a.held == nil, "held is \(String(describing: a.held))")
        // The key release still arrives afterwards; it must not double-fire as a stop.
        let up = a.resolve(key: .secondary, down: false, otherModifiers: false)
        check("release_after_retract_is_noop", up == .ignore, "got \(up)")
    }

    // 4c. Retracting when nothing is held is a no-op — typing with no PTT down must not
    //     manufacture a cancel for an utterance that never existed.
    do {
        var a = PTTArbiter()
        let r = a.retract()
        check("retract_while_idle_is_noop", r == .ignore, "got \(r)")
    }

    // 4d. Typing retracts too: ⌥e for an accent starts a hold on the Option press, and the
    //     'e' is what proves it was never speech. Without this, every accented character
    //     would leave a stray empty utterance behind.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .secondary, down: true, otherModifiers: false)
        check("typing_retracts_hold", a.retract() == .cancel(.secondary))
        check("typing_leaves_idle", a.held == nil, "held is \(String(describing: a.held))")
    }

    // 5. A release arriving with other modifiers still down must NOT be swallowed: the user
    //    can press a modifier mid-dictation, and losing the release would strand the app in
    //    the capturing state forever. Chord rejection applies to starts only.
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .primary, down: true, otherModifiers: false)
        let up = a.resolve(key: .primary, down: false, otherModifiers: true)
        check("release_survives_other_modifiers", up == .stop(.primary), "got \(up)")
    }

    // 6. The menu hint names the live pairing, and drops the second key when it is unbound so
    //    the line never advertises a key that does nothing.
    do {
        let both = AppDelegate.hintTitle(primary: "en", secondary: "es")
        check("hint_names_both_keys",
              both.contains("Right-Option (English)") && both.contains("Left-Option (Spanish)"),
              both)
        let off = AppDelegate.hintTitle(primary: "en", secondary: "off")
        check("hint_hides_unbound_key", !off.contains("Left-Option"), off)
        check("hint_keeps_cancel_and_undo", off.contains("Esc cancels") && off.contains("⌃⌥⌘Z"), off)
        let auto = AppDelegate.hintTitle(primary: "auto", secondary: "off")
        check("hint_labels_auto", auto.contains("Automatic"), auto)
    }

    // 7. The app's chords. Both need all of ⌃⌥⌘: a looser match would let plain ⌘V (paste)
    //    or ⌥V (a typed character) silently flip verbatim on, and every later dictation would
    //    lose its cleanup with no visible cause.
    do {
        typealias M = HotkeyMonitor
        let hyper: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let z: Int64 = 6, v: Int64 = 9, c: Int64 = 8
        check("chord_undo", M.chord(keyCode: z, flags: hyper) == .undo)
        check("chord_verbatim", M.chord(keyCode: v, flags: hyper) == .toggleVerbatim)
        check("chord_verbatim_with_shift",
              M.chord(keyCode: v, flags: hyper.union(.maskShift)) == .toggleVerbatim)
        check("paste_is_not_a_chord", M.chord(keyCode: v, flags: .maskCommand) == nil)
        check("option_v_is_not_a_chord", M.chord(keyCode: v, flags: .maskAlternate) == nil)
        check("ctrl_cmd_v_is_not_a_chord",
              M.chord(keyCode: v, flags: [.maskControl, .maskCommand]) == nil)
        check("other_key_is_not_a_chord", M.chord(keyCode: c, flags: hyper) == nil)
        // Holding the chord past the key-repeat delay must not flip verbatim back and forth
        // (or undo several times).
        // ...and the repeats are still swallowed, or they reach the frontmost app as its own
        // ⌃⌥⌘V / ⌃⌥⌘Z shortcut (release review #31).
        check("held_chord_repeat_is_swallowed_not_fired",
              M.chordAction(keyCode: v, flags: hyper, autorepeat: true, fired: .toggleVerbatim) == .swallow
                  && M.chordAction(keyCode: z, flags: hyper, autorepeat: true, fired: .undo) == .swallow)
        check("first_press_fires",
              M.chordAction(keyCode: v, flags: hyper, autorepeat: false, fired: nil) == .fire(.toggleVerbatim))
        check("non_chord_is_untouched",
              M.chordAction(keyCode: v, flags: .maskCommand, autorepeat: true, fired: nil) == nil)
        // A repeat of a press Cadence never fired (⌘V held, then ⌃⌥ added; or no handler)
        // belongs to the app.
        check("unfired_repeat_passes_through",
              M.chordAction(keyCode: v, flags: hyper, autorepeat: true, fired: nil) == nil)
        // Typing during a hold retracts it (⌥e is an accent, not speech), but an accidental
        // Return or Enter must not throw the dictation away.
        let e: Int64 = 14, ret: Int64 = 36, enter: Int64 = 76
        check("typing_retracts", M.typingRetracts(keyCode: e))
        check("return_does_not_retract", !M.typingRetracts(keyCode: ret))
        check("enter_does_not_retract", !M.typingRetracts(keyCode: enter))
    }

    // 8. A sticky verbatim mode is visible in the menu bar when idle, so cleanup never goes
    //    quiet without a sign; while dictating, the dictation state wins.
    do {
        let idleOn = AppDelegate.statusSymbol(state: "idle", verbatim: true)
        let idleOff = AppDelegate.statusSymbol(state: "idle", verbatim: false)
        check("verbatim_shows_when_idle", idleOn != idleOff, "\(idleOn) vs \(idleOff)")
        check("listening_ignores_verbatim",
              AppDelegate.statusSymbol(state: "listening", verbatim: true)
                  == AppDelegate.statusSymbol(state: "listening", verbatim: false))
    }

    // Timestamp-driven gestures: no sleeping and no global key synthesis.
    for key in [PTTKey.primary, .secondary] {
        var a = PTTArbiter()
        func edge(_ down: Bool, _ now: Double, _ mods: Bool = false) -> PTTArbiter.Decision {
            a.resolve(key: key, down: down, otherModifiers: mods, now: now, handsFree: true)
        }
        check("\(key)_first_tap_starts", edge(true, 0) == .start(key))
        check("\(key)_first_release_waits", edge(false, 0.05) == .ignore)
        check("\(key)_grace_not_expired", a.expire(now: 0.2) == .ignore)
        check("\(key)_second_down_no_restart", edge(true, 0.21) == .ignore)
        check("\(key)_second_release_latches", edge(false, 0.25) == .ignore && a.latched)
        check("\(key)_latched_does_not_expire", a.expire(now: 20) == .ignore && a.latched)
        check("\(key)_typing_keeps_recording", a.retract() == .ignore && a.latched)
        let foreignDown = a.resolve(key: key == .primary ? .secondary : .primary,
                                    down: true, otherModifiers: false, now: 20.5, handsFree: true)
        check("\(key)_foreign_key_cannot_finish", foreignDown == .ignore && a.latched)
        check("\(key)_finish_waits_for_release", edge(true, 21) == .ignore && a.latched)
        check("\(key)_single_tap_finishes", edge(false, 21.05) == .stop(key) && a.held == nil)
        check("\(key)_finish_does_not_fire_twice", edge(false, 21.1) == .ignore && a.expire(now: 22) == .ignore)
        _ = edge(true, 30)
        check("\(key)_hold_stops_without_delay", edge(false, 32) == .stop(key))
        _ = edge(true, 40); _ = edge(false, 40.05)
        check("\(key)_single_tap_eventually_stops",
              a.expire(now: 40.05 + PTTTiming.standard.interTapGap) == .stop(key))
        _ = edge(true, 50); _ = edge(false, 50.05)
        _ = edge(true, 50.15); _ = edge(false, 50.2)
        a.reset()
        check("\(key)_cancel_clears_latch", !a.latched && a.held == nil && a.deadline == nil)
        check("\(key)_shortcut_cannot_start", edge(true, 60, true) == .ignore)
    }
    do {
        var a = PTTArbiter()
        _ = a.resolve(key: .primary, down: true, otherModifiers: false, now: 0, handsFree: true)
        _ = a.resolve(key: .primary, down: false, otherModifiers: false, now: 0.05, handsFree: true)
        check("mixed_keys_cannot_latch", a.resolve(key: .secondary, down: true,
              otherModifiers: false, now: 0.1, handsFree: true) == .ignore && !a.latched)
    }

    do {
        var a = PTTArbiter()
        func edge(_ down: Bool, _ now: Double) -> PTTArbiter.Decision {
            a.resolve(key: .primary, down: down, otherModifiers: false, now: now, handsFree: true)
        }
        _ = edge(true, 0); _ = edge(false, 0.05)
        _ = edge(true, 0.15)
        check("second_long_hold_does_not_latch", edge(false, 2) == .stop(.primary) && !a.latched)
        _ = edge(true, 3); _ = edge(false, 3.05)
        _ = edge(true, 3.15); _ = edge(false, 3.2)
        _ = edge(true, 4)
        _ = a.retract() // Option+letter while hands-free: not a stop tap.
        check("shortcut_release_does_not_finish", edge(false, 4.05) == .ignore && a.latched)
        _ = edge(true, 4.15)
        check("clean_tap_after_shortcut_finishes", edge(false, 4.2) == .stop(.primary) && !a.latched)
    }

    // Forgiving double-tap: tap length and the pause between taps are separate limits, and
    // only the pause is generous. Boundaries are tested on both sides with an explicit timing
    // so the checks never depend on this Mac's double-click setting.
    do {
        let t = PTTTiming(maxTapDuration: 0.35, interTapGap: 0.5)
        check("timing_standard_gap_forgiving", PTTTiming.standard.interTapGap >= 0.5
              && PTTTiming.standard.maxTapDuration < PTTTiming.standard.interTapGap)
        check("timing_follows_double_click", PTTTiming.following(doubleClickInterval: 0.7).interTapGap == 0.7)
        check("timing_clamps_fast_setting", PTTTiming.following(doubleClickInterval: 0.1).interTapGap == 0.4)
        check("timing_clamps_slow_setting", PTTTiming.following(doubleClickInterval: 5).interTapGap == 0.8)
        check("timing_invalid_is_standard", PTTTiming.following(doubleClickInterval: .nan) == .standard
              && PTTTiming.following(doubleClickInterval: 0) == .standard)
        check("timing_tap_length_not_stretched",
              PTTTiming.following(doubleClickInterval: 0.8).maxTapDuration == PTTTiming.standard.maxTapDuration)

        func run(_ steps: [(Bool, Double)], key: PTTKey = .primary) -> (PTTArbiter, [PTTArbiter.Decision]) {
            var a = PTTArbiter(timing: t)
            var out: [PTTArbiter.Decision] = []
            for (down, now) in steps {
                // Mirrors HotkeyMonitor.update: an elapsed first tap resolves before any edge.
                let e = a.expire(now: now)
                if e != .ignore { out.append(e) }
                out.append(a.resolve(key: key, down: down, otherModifiers: false, now: now, handsFree: true))
            }
            return (a, out)
        }

        // A hesitant user: 0.45 s between taps used to stop the dictation (0.3 s window).
        var (a, out) = run([(true, 0), (false, 0.1), (true, 0.55), (false, 0.65)])
        check("hesitant_double_tap_latches", a.latched && out == [.start(.primary), .ignore, .ignore, .ignore])
        check("hesitant_latch_one_start", out.filter { if case .start = $0 { return true }; return false }.count == 1)
        check("pending_cleared_once_latched", !a.awaitingSecondTap)

        (a, out) = run([(true, 0), (false, 0.1), (true, 0.599), (false, 0.7)])
        check("gap_just_inside_latches", a.latched)
        (a, out) = run([(true, 0), (false, 0.1), (true, 0.6), (false, 0.7)])
        check("gap_at_boundary_stops_first_tap", !a.latched && out.contains(.stop(.primary)))
        check("gap_at_boundary_starts_fresh", out.filter { $0 == .start(.primary) }.count == 2)
        (a, out) = run([(true, 0), (false, 0.1), (true, 0.65), (false, 0.75)])
        check("gap_just_outside_does_not_latch", !a.latched && out[2] == .stop(.primary))

        (a, out) = run([(true, 0), (false, 0.35), (true, 0.5), (false, 0.6)])
        check("tap_length_at_limit_counts", a.latched)
        (a, out) = run([(true, 0), (false, 0.36)])
        check("tap_length_over_limit_is_hold", out.last == .stop(.primary) && a.deadline == nil)
        (a, out) = run([(true, 0), (false, 0.1), (true, 0.3), (false, 0.71)])
        check("long_second_press_is_hold_not_latch", !a.latched && out.last == .stop(.primary))

        var b = PTTArbiter(timing: t)
        _ = b.resolve(key: .primary, down: true, otherModifiers: false, now: 0, handsFree: true)
        check("hold_not_pending", !b.awaitingSecondTap)
        _ = b.resolve(key: .primary, down: false, otherModifiers: false, now: 0.1, handsFree: true)
        check("first_tap_pending", b.awaitingSecondTap)
        check("pending_still_open_before_gap", b.expire(now: 0.59) == .ignore && b.awaitingSecondTap)
        check("lone_tap_stops_after_gap", b.expire(now: 0.6) == .stop(.primary) && !b.awaitingSecondTap)
        check("lone_tap_stops_once", b.expire(now: 1) == .ignore)
        var h = PTTArbiter(timing: t)
        _ = h.resolve(key: .primary, down: true, otherModifiers: false, now: 0, handsFree: true)
        _ = h.resolve(key: .primary, down: false, otherModifiers: false, now: 0.1, handsFree: true)
        _ = h.resolve(key: .primary, down: true, otherModifiers: false, now: 0.5, handsFree: true)
        check("pending_hint_holds_during_second_press", h.awaitingSecondTap)
        _ = h.resolve(key: .primary, down: false, otherModifiers: false, now: 0.55, handsFree: true)
        check("pending_hint_clears_on_latch", h.latched && !h.awaitingSecondTap)

        // Hesitant latch, then a single clean tap finishes exactly once (no Return pressed:
        // the arbiter only ever emits start/stop/cancel, insertion never submits).
        (a, out) = run([(true, 0), (false, 0.1), (true, 0.55), (false, 0.65), (true, 30), (false, 30.1)])
        check("hesitant_latch_single_tap_finishes", out.last == .stop(.primary) && a.held == nil)
        check("hesitant_finish_no_duplicate",
              out.filter { $0 == .stop(.primary) }.count == 1 && a.expire(now: 40) == .ignore)

        // The other Option key during the longer pause can neither latch nor steal the
        // dictation, and the owner can still complete its double-tap.
        var c = PTTArbiter(timing: t)
        _ = c.resolve(key: .primary, down: true, otherModifiers: false, now: 0, handsFree: true)
        _ = c.resolve(key: .primary, down: false, otherModifiers: false, now: 0.1, handsFree: true)
        check("foreign_key_in_gap_ignored", c.resolve(key: .secondary, down: true, otherModifiers: false,
              now: 0.4, handsFree: true) == .ignore && c.held == .primary)
        check("foreign_release_in_gap_ignored", c.resolve(key: .secondary, down: false, otherModifiers: false,
              now: 0.45, handsFree: true) == .ignore && c.held == .primary)
        _ = c.resolve(key: .primary, down: true, otherModifiers: false, now: 0.5, handsFree: true)
        _ = c.resolve(key: .primary, down: false, otherModifiers: false, now: 0.55, handsFree: true)
        check("owner_latches_after_foreign_key", c.latched && c.held == .primary)

        // An Option shortcut on the second press (⌥e, ⌃⌥⌘Z) during the pause retracts the
        // whole thing rather than latching; a modifier already down cannot start or latch.
        var d = PTTArbiter(timing: t)
        _ = d.resolve(key: .primary, down: true, otherModifiers: false, now: 0, handsFree: true)
        _ = d.resolve(key: .primary, down: false, otherModifiers: false, now: 0.1, handsFree: true)
        _ = d.resolve(key: .primary, down: true, otherModifiers: false, now: 0.5, handsFree: true)
        check("typing_on_second_press_retracts", d.retract() == .cancel(.primary) && d.held == nil)
        check("retracted_release_is_noop", d.resolve(key: .primary, down: false, otherModifiers: false,
              now: 0.55, handsFree: true) == .ignore && !d.latched)
        var e = PTTArbiter(timing: t)
        _ = e.resolve(key: .primary, down: true, otherModifiers: false, now: 0, handsFree: true)
        _ = e.resolve(key: .primary, down: false, otherModifiers: false, now: 0.1, handsFree: true)
        check("chorded_second_press_cannot_latch", e.resolve(key: .primary, down: true, otherModifiers: true,
              now: 0.4, handsFree: true) == .ignore && !e.latched)
        check("chorded_second_press_leaves_first_tap", e.expire(now: 0.6) == .stop(.primary))

        // Escape (monitor resets the gesture) during the pause leaves nothing pending/stranded.
        var f = PTTArbiter(timing: t)
        _ = f.resolve(key: .primary, down: true, otherModifiers: false, now: 0, handsFree: true)
        _ = f.resolve(key: .primary, down: false, otherModifiers: false, now: 0.1, handsFree: true)
        f.reset()
        check("escape_in_gap_clears_pending", !f.awaitingSecondTap && f.held == nil
              && f.expire(now: 1) == .ignore)

        // Hold-to-talk is untouched: immediate start, immediate stop, never pending.
        (a, out) = run([(true, 0), (false, 3)])
        check("ordinary_hold_unchanged", out == [.start(.primary), .stop(.primary)] && !a.awaitingSecondTap)
        var g = PTTArbiter(timing: t)
        check("hands_free_off_hold_unchanged",
              g.resolve(key: .primary, down: true, otherModifiers: false, now: 0) == .start(.primary)
              && g.resolve(key: .primary, down: false, otherModifiers: false, now: 0.1) == .stop(.primary))

        check("pill_pending_hint", OverlayHUD.listeningGlyph(handsFree: false, tapPending: true)
              .contains("tap again"))
        check("pill_hands_free_wins", OverlayHUD.listeningGlyph(handsFree: true, tapPending: true)
              == "● hands-free · tap to finish")
        check("pill_plain_listening", OverlayHUD.listeningGlyph(handsFree: false, tapPending: false)
              == "● listening")
    }

    let pass = checks.allSatisfy { $0.pass }
    struct Report: Encodable {
        let checks: [HotkeyCheck]
        let pass: Bool
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(Report(checks: checks, pass: pass)),
        let s = String(data: data, encoding: .utf8)
    {
        print(s)
    }
    return pass ? 0 : 1
}
