// Isolated storage-boundary tests: never open the user's store, keychain or legacy file.
import AppKit
import CCadenceFFI
import Foundation

func runHistorySelftest() -> Int32 {
    var failed = 0, checks = 0
    func check(_ name: String, _ ok: Bool) {
        checks += 1
        if !ok { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-history-" + UUID().uuidString)
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    catch { print("FAIL temporary_directory"); return 1 }
    defer { try? FileManager.default.removeItem(at: dir) }
    func open(_ name: String) -> OpaquePointer? {
        let key = [UInt8](repeating: 42, count: 32)
        return key.withUnsafeBufferPointer { cadence_store_open(dir.appendingPathComponent(name).path, $0.baseAddress, $0.count) }
    }
    let a: [String: Any] = ["utterance": "utt-1", "ts": "2026-11-05T12:00:00Z", "text": "private English words", "language": "en"]
    let b: [String: Any] = ["utterance": "utt-2", "ts": "2026-11-05T12:00:01Z", "text": "palabras privadas", "language": "es"]
    let c: [String: Any] = ["utterance": "utt-3", "ts": "2026-11-05T12:00:02Z", "text": "arrived during retry"]
    let pending = PendingHistory()
    pending.append(a); pending.append(b)
    let originalTokens = pending.snapshot.map(\.token)
    check("failed_retry_saves_nothing", pending.retry { _ in false } == 0)
    check("failed_retry_keeps_exact_words_and_tokens", pending.snapshot.map(\.token) == originalTokens && pending.copyText == "private English words\n\npalabras privadas")
    var calls = 0
    let partial = pending.retry { record in
        calls += 1
        if calls == 1 { pending.append(c) }
        return record["utterance"] as? String == "utt-1"
    }
    check("partial_retry_removes_only_success", partial == 1 && pending.count == 2)
    check("new_arrival_not_in_retry_snapshot", calls == 2 && pending.snapshot.last?.record["text"] as? String == "arrived during retry")
    check("failure_keeps_original_timestamp_and_language", pending.snapshot.first?.record["ts"] as? String == b["ts"] as? String && pending.snapshot.first?.record["language"] as? String == "es")

    // This is the actual nil-store fallback used by the effect router.
    let clipboardBefore = NSPasteboard.general.changeCount
    let fallback = PendingHistory()
    History.append(record: ["utterance": "fallback"], text: "only in RAM", metrics: ["capture_window_ms": 100], pending: fallback)
    check("nil_store_fallback_retains_text", fallback.copyText == "only in RAM")
    check("nil_store_fallback_retains_metrics_and_timestamp", fallback.snapshot.first?.record["capture_window_ms"] as? Int == 100 && fallback.snapshot.first?.record["ts"] is String)
    let unavailable = HistoryStore(handle: nil, pending: fallback)
    unavailable.persist(record: ["utterance": "no-handle"], text: "still here", metrics: [:])
    unavailable.finishPendingWrites()
    check("unavailable_handle_retains_words_after_queue_drain", fallback.count == 2 && fallback.snapshot.last?.record["text"] as? String == "still here")
    check("unavailable_handle_retry_preserves_words", fallback.retry(write: unavailable.persistRecoveredRecord) == 0 && fallback.count == 2)
    check("automatic_recovery_does_not_touch_clipboard", NSPasteboard.general.changeCount == clipboardBefore)
    check("fallback_creates_no_files", (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true)

    // Fail the actual persistence boundary after creating an encrypted audio blob.
    guard let failingHandle = open("failure.db"), let successHandle = open("success.db") else {
        print("FAIL isolated_store_open"); return 1
    }
    var capturedBlob: String?
    let failedWrites = PendingHistory()
    let failing = HistoryStore(handle: failingHandle, pending: failedWrites, writeJSON: { _, json in
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        capturedBlob = obj?["audio_blob_id"] as? String
        return false
    })
    failing.persist(record: ["utterance": "audio-failure", "language": "es"], text: "encrypted save failed", metrics: ["capture_window_ms": 250], audio: [1, 2, 3])
    failing.finishPendingWrites()
    check("write_failure_retains_transcript_and_metrics", failedWrites.copyText == "encrypted save failed" && failedWrites.snapshot.first?.record["capture_window_ms"] as? Int == 250)
    check("failed_transcript_has_no_dangling_audio_link", failedWrites.snapshot.first?.record["audio_blob_id"] == nil)
    check("failed_transcript_removes_unlinked_audio_blob", capturedBlob != nil && failing.audioBlob(id: capturedBlob!) == nil)
    check("failed_transcript_not_in_encrypted_history", failing.recent(limit: 10).isEmpty)

    let success = HistoryStore(handle: successHandle, pending: failedWrites)
    let recoveryRecord = failedWrites.snapshot[0].record
    check("encrypted_retry_clears_only_after_success", failedWrites.retry(write: success.persistRecoveredRecord) == 1 && failedWrites.count == 0)
    let rows = success.recent(limit: 10)
    check("encrypted_retry_preserves_text_and_timestamp", rows.count == 1 && rows[0]["text"] as? String == "encrypted save failed" && rows[0]["ts"] as? String == recoveryRecord["ts"] as? String)
    check("retry_is_idempotent", success.persistRecoveredRecord(recoveryRecord) && success.recent(limit: 10).count == 1)
    check("retry_reader_deduplicates_ram_and_qualified_database_id", HistoryIdentity.merge(pending: [recoveryRecord], stored: rows).count == 1)
    check("separate_sessions_keep_reused_ids", HistoryIdentity.merge(pending: [a, a.merging(["ts": "2026-11-06T12:00:00Z"]) { _, new in new }], stored: []).count == 2)
    check("legacy_rows_without_ids_are_not_dropped", HistoryIdentity.merge(pending: [], stored: [["text": "one"], ["text": "two"]]).count == 2)
    success.persist(record: ["utterance": "normal"], text: "normal encrypted save", metrics: [:], audio: [4, 5, 6])
    success.finishPendingWrites()
    let normal = success.recent(limit: 10).first { $0["text"] as? String == "normal encrypted save" }
    let audio = (normal?["audio_blob_id"] as? String).flatMap { success.audioBlob(id: $0) }
    check("normal_save_keeps_encrypted_audio", audio?.starts(with: Data("RIFF".utf8)) == true && failedWrites.count == 0)
    success.persist(record: ["utterance": "encoding", "invalid": Date()], text: "encoding failure", metrics: [:])
    success.finishPendingWrites()
    check("encoding_failure_also_retains_words", failedWrites.copyText == "encoding failure")
    let db = (try? Data(contentsOf: dir.appendingPathComponent("success.db"))) ?? Data()
    check("database_has_no_plaintext_transcript", !db.isEmpty && db.range(of: Data("normal encrypted save".utf8)) == nil)

    do {
        let legacy = dir.appendingPathComponent("history.jsonl")
        let prior = legacy.appendingPathExtension("imported")
        try Data("old archive".utf8).write(to: prior)
        try Data("legacy source".utf8).write(to: legacy)
        try HistoryStore.archiveLegacy(legacy)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let archive = files.first { $0.lastPathComponent.hasPrefix("history.jsonl.imported-") }
        check("earlier_legacy_archive_preserved", try Data(contentsOf: prior) == Data("old archive".utf8))
        check("current_legacy_file_preserved_separately", archive.flatMap { try? Data(contentsOf: $0) } == Data("legacy source".utf8) && !FileManager.default.fileExists(atPath: legacy.path))
    } catch { check("legacy_archive_operation", false) }

    var diagnostics: [String] = []
    let router = EffectRouter()
    router.diagnosticLog = { diagnostics.append($0) }
    router.route("malformed private-transcript-marker")
    router.route("{\"type\":\"private-transcript-marker\",\"text\":\"private-transcript-marker\"}")
    router.route("{\"type\":\"arm_undo\",\"text\":\"private-transcript-marker\"}")
    check("effect_diagnostics_never_echo_transcript_payloads", !diagnostics.isEmpty && !diagnostics.joined().contains("private-transcript-marker"))

    // Exercise the app delegate's actual quit decision without terminating the harness.
    // No launch callbacks, capture, hotkeys, live store or permissions are touched.
    let app = NSApplication.shared
    let delegate = AppDelegate(config: Config())
    let engine = CoreEngine(backend: .mock(refined: "fixture"), onEffect: { _ in })
    delegate.engine = engine
    PendingHistory.shared.append(a)
    var prompted = 0
    delegate.confirmHistoryDiscard = { count in prompted = count; return false }
    check("quit_cancel_keeps_engine_and_recovery", delegate.applicationShouldTerminate(app) == .terminateCancel && delegate.engine === engine && PendingHistory.shared.count == 1 && prompted == 1)
    delegate.confirmHistoryDiscard = { _ in true }
    check("explicit_discard_allows_quit", delegate.applicationShouldTerminate(app) == .terminateNow)
    PendingHistory.shared.retry { _ in true }
    check("no_unsaved_words_allows_quit", delegate.applicationShouldTerminate(app) == .terminateNow)
    success.setDictationLanguage("fr")
    success.setSecondaryLanguage("off")
    success.setVerbatimMode(true)
    success.setRetainAudio(true)
    success.setPreferBuiltInMic(true)
    success.setVoiceIsolation(false)
    success.setFeature("copy_dictations", enabled: false)
    success.setFeature("hands_free", enabled: false)
    success.setFeature("noisy_room", enabled: true)
    success.setFeature("live_insertion", enabled: true)
    delegate.adoptRecoveredStore(success)
    check("reopened_store_reconnects_all_readers", delegate.historyStore === success && delegate.router.historyStore === success && HistoryReader.store === success)
    check("reopened_store_restores_languages_and_modes", delegate.dictationLanguage == "fr" && delegate.secondaryLanguage == "off" && delegate.verbatimMode && delegate.retainAudio)
    check("reopened_store_restores_delivery_and_capture_preferences", !delegate.copyDictations && !delegate.handsFree && delegate.noisyRoom && delegate.liveInsertion && delegate.capture.preferBuiltInMic && !delegate.capture.voiceIsolation)
    HistoryReader.store = nil
    delegate.engine = nil
    print("history recovery: \(checks - failed)/\(checks) passed")
    return failed == 0 ? 0 : 1
}
