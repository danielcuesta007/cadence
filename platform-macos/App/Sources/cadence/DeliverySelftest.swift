import AppKit
import CadenceInsertion
import Foundation

// Pure boundary fake: run real session validation, UTF-16 ranges and reconciliation.
private final class TestLiveField: LiveField {
    var state = LiveFieldState(value: "Before 🌎 after", selection: NSRange(location: 7, length: 2))
    var focused = true
    var writes = 0
    var failWrite = false
    func read() -> LiveFieldState? { focused ? state : nil }
    func replace(range: NSRange, text: String) -> Bool {
        writes += 1
        if failWrite { return false }
        state.value = (state.value as NSString).replacingCharacters(in: range, with: text)
        state.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
        return true
    }
}

func runDeliverySelftest() -> Int32 {
    var failed = 0
    var count = 0
    func check(_ name: String, _ pass: Bool) {
        count += 1
        if !pass { failed += 1 }
        print("\(pass ? "PASS" : "FAIL") \(name)")
    }
    do {
        let f = TestLiveField(), s = LiveInsertionSession(field: TestLiveField())
        check("readable_field_can_start", s != nil)
        let session = LiveInsertionSession(field: f)!
        check("preview_replaces_selection", session.update("hello") && f.state.value == "Before hello after")
        check("revision_replaces_only_preview", session.update("hello world") && f.state.value == "Before hello world after")
        check("final_replaces_preview_without_duplication", session.finish("Hello, world.") == .inserted && f.state.value == "Before Hello, world. after")
    }
    do {
        let f = TestLiveField(), session = LiveInsertionSession(field: TestLiveField())!
        check("no_preview_uses_normal_insertion", session.finish("final") == .unused)
        let s = LiveInsertionSession(field: f)!
        _ = s.update("provisional")
        s.cancel()
        check("cancel_restores_original_selection_text", f.state.value == "Before 🌎 after")
    }
    do {
        let f = TestLiveField()
        let session = LiveInsertionSession(field: f)!
        _ = session.update("preview")
        f.focused = false
        check("focus_change_routes_final_to_recovery", session.finish("final") == .recovery && f.writes == 1)
        f.focused = true
        check("refocusing_cannot_restart_blocked_preview", !session.update("unsafe") && f.writes == 1)
    }
    do {
        let f = TestLiveField(), s = LiveInsertionSession(field: f)!
        _ = s.update("preview")
        f.state.value += " user edit"
        check("typing_does_not_get_overwritten", s.finish("final") == .recovery && f.writes == 1)
        s.cancel()
        check("cancel_preserves_user_edit", f.state.value.hasSuffix(" user edit") && f.writes == 1)
    }
    do {
        let f = TestLiveField(), s = LiveInsertionSession(field: f)!
        _ = s.update("preview")
        f.state.selection.location = 0
        check("caret_movement_blocks_write", s.finish("final") == .recovery && f.writes == 1)
    }
    do {
        let f = TestLiveField(), s = LiveInsertionSession(field: f)!
        f.failWrite = true
        _ = s.update("preview")
        check("ambiguous_setter_failure_never_retries", s.finish("final") == .recovery && f.writes == 1)
    }
    do {
        let f = TestLiveField(), s = LiveInsertionSession(field: f)!
        f.focused = false
        check("focus_change_before_first_preview_cannot_redirect_final", s.finish("final") == .recovery && f.writes == 0)
    }
    do {
        var transcript = LiveTranscript()
        check("growing_hypothesis_revises", transcript.update("one two", sliding: false) == "one two")
        _ = transcript.update("one two three four five", sliding: false)
        check("sliding_window_retains_opening", transcript.update("three four five six", sliding: true) == "one two three four five six")
        check("ambiguous_overlap_waits_for_final", transcript.update("unrelated tail", sliding: true) == "one two three four five six")
    }
    do {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.cadence.delivery-test.\(UUID())"))
        defer { pb.releaseGlobally() }
        pb.setString("previous clipboard", forType: .string)
        ClipboardRecovery.prepare("dictated text", enabled: false, on: pb)
        check("copy_off_preserves_previous_clipboard", pb.string(forType: .string) == "previous clipboard")
        ClipboardRecovery.prepare("dictated text", enabled: true, on: pb)
        check("copy_on_covers_direct_insertion", pb.string(forType: .string) == "dictated text")
        let snapshot = ClipboardSnapshot.capture(pb)
        pb.clearContents(); pb.setString("dictated text", forType: .string)
        let pasteCount = pb.changeCount
        check("paste_restore_keeps_dictation_available", snapshot.restore(to: pb, ifChangeCountStill: pasteCount)
              && pb.string(forType: .string) == "dictated text")
        pb.clearContents(); pb.setString("new user copy", forType: .string)
        check("new_copy_during_paste_wins", !snapshot.restore(to: pb, ifChangeCountStill: pasteCount)
              && pb.string(forType: .string) == "new user copy")
    }
    print("\(count - failed)/\(count) delivery checks passed")
    return failed == 0 ? 0 : 1
}
