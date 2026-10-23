import UIKit

/// Edits the AI features make in the lyrics. Offsets are UTF-16, like UITextView's.
extension EditorBridge {
    var text: String { textView?.text ?? "" }

    /// The caret's line: its range (without the newline) and the text before the caret on it.
    func caretLine() -> (range: NSRange, before: String)? {
        guard let tv = textView else { return nil }
        let ns = (tv.text ?? "") as NSString
        let a = min(tv.selectedRange.location, ns.length)
        var ls = 0
        if a > 0 { let r = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: a)); if r.location != NSNotFound { ls = r.location + 1 } }
        var le = ns.length
        let rr = ns.range(of: "\n", options: [], range: NSRange(location: a, length: ns.length - a))
        if rr.location != NSNotFound { le = rr.location }
        return (NSRange(location: ls, length: le - ls), ns.substring(with: NSRange(location: ls, length: a - ls)))
    }

    private func place(_ loc: Int) {
        guard let tv = textView else { return }
        tv.selectedRange = NSRange(location: min(loc, (tv.text as NSString? ?? "").length), length: 0)
        coordinator?.afterChange(tv)
    }

    /// The Muse's insLine: after the caret's line, or in place of it when it's empty; then a new line.
    func insertLine(_ line: String) {
        guard let (r, _) = caretLine() else { return }
        let ns = text as NSString
        let raw = ns.substring(with: r)
        let end: Int
        if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            end = replace(NSRange(location: r.location + r.length, length: 0), with: "\n" + line + "\n")
        } else {
            end = replace(r, with: line + "\n")
        }
        place(end)
        Haptics.thud()
    }

    /// Lines mode with no selection: replaces the caret's line, or goes after it when the caret sits
    /// at the start of a written line (e.g. a [Section] tag).
    func applyLine(_ line: String) {
        guard let (r, before) = caretLine() else { return }
        let raw = (text as NSString).substring(with: r)
        let end: Int
        if !raw.trimmingCharacters(in: .whitespaces).isEmpty && before.trimmingCharacters(in: .whitespaces).isEmpty {
            end = replace(NSRange(location: r.location + r.length, length: 0), with: "\n" + line + "\n")
        } else {
            end = replace(r, with: line + "\n")
        }
        place(end)
        Haptics.tap()
    }

    /// Rewrite / Tighten: replaces the selected text, found again if it has moved. False if it's gone.
    func replaceSelection(_ src: String, at range: NSRange, with line: String) -> Bool {
        let ns = text as NSString
        var r = range
        if r.location + r.length > ns.length || ns.substring(with: r) != src {
            let f = ns.range(of: src)
            guard f.location != NSNotFound else { return false }
            r = f
        }
        let end = replace(r, with: line)
        textView?.selectedRange = NSRange(location: end, length: 0)
        Haptics.tap()
        return true
    }

    /// "Lines that rhyme": a new line after the line the selection ends on.
    func insertAfter(_ loc: Int, _ line: String) {
        let ns = text as NSString
        let at = min(loc, ns.length)
        let nl = ns.range(of: "\n", options: [], range: NSRange(location: at, length: ns.length - at))
        let e = nl.location == NSNotFound ? ns.length : nl.location
        let end = replace(NSRange(location: e, length: 0), with: "\n" + line + "\n")
        place(end)
        Haptics.tap()
    }

    /// Selects some text (Rate's quotes), scrolling it into view. False if it isn't in the lyrics.
    @discardableResult
    func selectQuote(_ q: String) -> Bool {
        guard let tv = textView, let r = Self.findQuote(q, in: text) else { return false }
        tv.becomeFirstResponder()
        tv.selectedRange = r
        tv.scrollRangeToVisible(r)
        return true
    }

    /// findQuote: exact, then ignoring case, then with quote marks stripped.
    static func findQuote(_ q: String, in text: String) -> NSRange? {
        guard !q.isEmpty else { return nil }
        let ns = text as NSString
        var r = ns.range(of: q)
        if r.location == NSNotFound { r = ns.range(of: q, options: .caseInsensitive) }
        if r.location == NSNotFound {
            let s = q.replacingOccurrences(of: "[“”\"]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            r = ns.range(of: s, options: .caseInsensitive)
        }
        return r.location == NSNotFound ? nil : r
    }

    /// Appends text at the end of the song (the Muse's scratch sections), caret after it.
    func appendAtEnd(_ s: String) {
        let ns = text as NSString
        let end = replace(NSRange(location: ns.length, length: 0), with: s)
        textView?.becomeFirstResponder()
        place(end)
    }

    /// A co-writer's change: spliced into the text without touching the undo stack, keeping my caret
    /// where it was relative to the words around it.
    func applyRemote(at: Int, delete: Int, insert: String) {
        guard let tv = textView else { return }
        let ns = (tv.text ?? "") as NSString
        let a = min(max(0, at), ns.length), len = min(delete, ns.length - a)
        let sel = tv.selectedRange
        let ins = (insert as NSString).length
        tv.textStorage.beginEditing()
        tv.textStorage.replaceCharacters(in: NSRange(location: a, length: len), with: NSAttributedString(string: insert, attributes: EditorBridge.baseAttributes))
        tv.textStorage.endEditing()
        func shift(_ p: Int) -> Int { p >= a + len ? p + ins - len : (p > a ? a + ins : p) }
        let s0 = shift(sel.location), s1 = shift(sel.location + sel.length)
        tv.selectedRange = NSRange(location: s0, length: max(0, s1 - s0))
        coordinator?.afterChange(tv)
    }

    /// Words in the lyrics right now (sprint counts).
    var wordCount: Int { text.matches(of: #/[A-Za-z0-9']+/#).count }
}
