// Provisional text is edited only while field identity, complete value and selection
// still match our last verified write. No clipboard paste or blind app-wide typing.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

public struct LiveFieldState: Equatable {
    public var value: String
    public var selection: NSRange
    public init(value: String, selection: NSRange) { self.value = value; self.selection = selection }
}

public protocol LiveField: AnyObject {
    // nil means focus moved, secure input, unreadable value, or permission lost.
    func read() -> LiveFieldState?
    func replace(range: NSRange, text: String) -> Bool
}

public final class LiveInsertionSession {
    public enum Finish: Equatable { case unused, inserted, recovery }
    private let field: LiveField
    private let original: LiveFieldState
    private var expected: LiveFieldState
    private var preview = ""
    private var blocked = false
    private var attempted = false
    public var hasPreview: Bool { attempted }

    public init?(field: LiveField) {
        guard let state = field.read(), state.selection.location != NSNotFound,
              NSMaxRange(state.selection) <= (state.value as NSString).length else { return nil }
        self.field = field; original = state; expected = state
    }

    @discardableResult public func update(_ text: String) -> Bool {
        guard !blocked, field.read() == expected else { blocked = true; return false }
        if attempted && text == preview { return true }
        let range = NSRange(location: original.selection.location,
                            length: attempted ? (preview as NSString).length : original.selection.length)
        let nextValue = (expected.value as NSString).replacingCharacters(in: range, with: text)
        attempted = true // even a failed setter may have changed the remote field
        guard field.replace(range: range, text: text) else { blocked = true; return false }
        let next = LiveFieldState(value: nextValue,
                                 selection: NSRange(location: range.location + (text as NSString).length, length: 0))
        guard field.read() == next else { blocked = true; return false }
        expected = next; preview = text
        return true
    }

    public func finish(_ text: String) -> Finish {
        guard !blocked, field.read() == expected else { blocked = true; return .recovery }
        guard attempted else { return .unused }
        return update(text) ? .inserted : .recovery
    }

    public func cancel() {
        guard attempted, !blocked, field.read() == expected else { return }
        let originalText = (original.value as NSString).substring(with: original.selection)
        _ = update(originalText)
    }

    public static func focused() -> LiveInsertionSession? {
        guard let field = AXLiveField() else { return nil }
        return LiveInsertionSession(field: field)
    }
}

private final class AXLiveField: LiveField {
    let element: AXUIElement
    let pid: pid_t
    init?() {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        self.pid = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        for attr in [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, attr as CFString, &settable) == .success,
                  settable.boolValue else { return nil }
        }
        guard read() != nil else { return nil }
    }
    func read() -> LiveFieldState? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, element) else { return nil }
        var subrole: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subroleStatus == .success || subroleStatus == .attributeUnsupported || subroleStatus == .noValue,
              subrole as? String != "AXSecureTextField" else { return nil }
        var value: CFTypeRef?, selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value = value as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range), range.location >= 0,
              range.length >= 0, range.location <= (value as NSString).length,
              range.length <= (value as NSString).length - range.location else { return nil }
        return LiveFieldState(value: value, selection: NSRange(location: range.location, length: range.length))
    }
    func replace(range: NSRange, text: String) -> Bool {
        guard let before = read() else { return false }
        let expectedRange = range
        var range = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
              let after = read(), after.value == before.value,
              after.selection == expectedRange else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}

// Once the ASR's eight-second window slides, retain the prefix and reconcile its
// overlapping words. Ambiguous/no-overlap hypotheses wait for the authoritative final.
public struct LiveTranscript {
    public private(set) var text = ""
    public init() {}
    public mutating func update(_ partial: String, sliding: Bool) -> String {
        guard !partial.isEmpty else { return text }
        guard sliding, !text.isEmpty else { text = partial; return text }
        let old = text.split(separator: " ").map(String.init)
        let new = partial.split(separator: " ").map(String.init)
        func key(_ word: String) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }
        // Find a matching pair near the old tail. The new prefix can begin mid-word.
        if old.count >= 2, new.count >= 2 {
            for i in max(0, old.count - 80)..<(old.count - 1) {
                for j in 0..<min(4, new.count - 1) {
                    guard !key(old[i]).isEmpty, key(old[i]) == key(new[j]),
                          key(old[i + 1]) == key(new[j + 1]) else { continue }
                    text = (Array(old[..<i]) + Array(new[j...])).joined(separator: " ")
                    return text
                }
            }
        }
        return text
    }
}
