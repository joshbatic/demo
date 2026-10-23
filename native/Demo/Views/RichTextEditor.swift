import SwiftUI
import UIKit

/// Talks to the lyric text view: formatting commands from the toolbar act on the selection.
/// A plain class (not observed): the view reads it, it never drives SwiftUI updates.
@MainActor
final class EditorBridge {
    weak var textView: UITextView?
    /// Saves an edit and returns the (rich, lyrics) it stored, so the view knows not to reload them.
    var onEdit: ((NSAttributedString) -> (String, String))?
    /// The stored text this view last loaded or saved, and when the user last typed.
    var lastKey = ""
    var lastEdit = Date.distantPast

    static let baseFont = UIFont.systemFont(ofSize: 19)
    static let slate = UIColor(red: 0.557, green: 0.557, blue: 0.588, alpha: 1)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineSpacing = 6
        return [.font: baseFont, .foregroundColor: UIColor.label, .paragraphStyle: p]
    }

    enum Trait { case bold, italic, underline, strike }

    func toggle(_ t: Trait) {
        guard let tv = textView else { return }
        Haptics.selection()
        let r = tv.selectedRange
        if r.length == 0 {
            var a = tv.typingAttributes
            Self.flip(t, in: &a)
            tv.typingAttributes = a
            return
        }
        let storage = tv.textStorage
        // on for the whole selection unless it's already on everywhere
        var allOn = true
        storage.enumerateAttributes(in: r) { a, _, stop in if !Self.has(t, a) { allOn = false; stop.pointee = true } }
        storage.beginEditing()
        storage.enumerateAttributes(in: r) { a, sub, _ in
            var n = a
            if Self.has(t, a) == allOn { Self.flip(t, in: &n) }
            storage.setAttributes(n, range: sub)
        }
        storage.endEditing()
        tv.selectedRange = r
        emit()
    }

    func setColor(_ c: UIColor?) { apply(.foregroundColor, c ?? .label) }
    func setHighlight(_ c: UIColor?) {
        guard let tv = textView else { return }
        Haptics.selection()
        let r = tv.selectedRange
        guard r.length > 0 else { return }
        if let c { tv.textStorage.addAttribute(.backgroundColor, value: c, range: r) } else { tv.textStorage.removeAttribute(.backgroundColor, range: r) }
        tv.selectedRange = r
        emit()
    }

    func clearFormatting() {
        guard let tv = textView else { return }
        Haptics.selection()
        let r = tv.selectedRange
        guard r.length > 0 else { return }
        tv.textStorage.setAttributes(Self.baseAttributes, range: r)
        tv.selectedRange = r
        emit()
    }

    private func apply(_ key: NSAttributedString.Key, _ v: Any) {
        guard let tv = textView else { return }
        Haptics.selection()
        let r = tv.selectedRange
        if r.length == 0 { tv.typingAttributes[key] = v; return }
        tv.textStorage.addAttribute(key, value: v, range: r)
        tv.selectedRange = r
        emit()
    }

    func emit() {
        guard let tv = textView, let (r, l) = onEdit?(tv.attributedText) else { return }
        lastKey = r + "\u{0}" + l
    }

    static func has(_ t: Trait, _ a: [NSAttributedString.Key: Any]) -> Bool {
        switch t {
        case .bold: return (a[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
        case .italic: return (a[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitItalic) ?? false
        case .underline: return ((a[.underlineStyle] as? Int) ?? 0) != 0
        case .strike: return ((a[.strikethroughStyle] as? Int) ?? 0) != 0
        }
    }

    static func flip(_ t: Trait, in a: inout [NSAttributedString.Key: Any]) {
        switch t {
        case .bold, .italic:
            let f = (a[.font] as? UIFont) ?? baseFont
            var traits = f.fontDescriptor.symbolicTraits
            let bit: UIFontDescriptor.SymbolicTraits = t == .bold ? .traitBold : .traitItalic
            if traits.contains(bit) { traits.remove(bit) } else { traits.insert(bit) }
            let d = baseFont.fontDescriptor.withSymbolicTraits(traits) ?? baseFont.fontDescriptor
            a[.font] = UIFont(descriptor: d, size: f.pointSize)
        case .underline: a[.underlineStyle] = has(.underline, a) ? 0 : NSUnderlineStyle.single.rawValue
        case .strike: a[.strikethroughStyle] = has(.strike, a) ? 0 : NSUnderlineStyle.single.rawValue
        }
    }
}

/// The lyric editor: a native text view holding the song's formatted lyrics.
struct RichTextEditor: UIViewRepresentable {
    let bridge: EditorBridge
    /// The song's text as stored; when it changes from elsewhere (sync), the view reloads.
    let rich: String
    let lyrics: String
    var placeholder = "Start writing…"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.font = EditorBridge.baseFont
        tv.typingAttributes = EditorBridge.baseAttributes
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 18, bottom: 120, right: 18)
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        tv.autocapitalizationType = .sentences
        tv.smartDashesType = .no
        tv.smartQuotesType = .yes
        tv.allowsEditingTextAttributes = true
        tv.delegate = context.coordinator
        context.coordinator.bridge = bridge
        bridge.textView = tv
        load(tv, context.coordinator)
        context.coordinator.placeholder.text = placeholder
        context.coordinator.attachPlaceholder(to: tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        bridge.textView = tv
        context.coordinator.bridge = bridge
        let key = rich + "\u{0}" + lyrics
        // reload only for changes that didn't come from this view (another device, a restore)
        if key != bridge.lastKey && !(tv.isFirstResponder && Date().timeIntervalSince(bridge.lastEdit) < 4) {
            load(tv, context.coordinator)
        }
    }

    private func load(_ tv: UITextView, _ c: Coordinator) {
        let sel = tv.selectedRange
        let a = NSMutableAttributedString(attributedString: RichText.attributed(html: rich, plain: lyrics, font: EditorBridge.baseFont, color: .label))
        let p = NSMutableParagraphStyle(); p.lineSpacing = 6
        a.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: a.length))
        tv.attributedText = a
        tv.typingAttributes = EditorBridge.baseAttributes
        if sel.location <= a.length { tv.selectedRange = NSRange(location: min(sel.location, a.length), length: 0) }
        bridge.lastKey = rich + "\u{0}" + lyrics
        c.updatePlaceholder(tv)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        weak var bridge: EditorBridge?
        let placeholder = UILabel()

        func attachPlaceholder(to tv: UITextView) {
            placeholder.font = EditorBridge.baseFont
            placeholder.textColor = .tertiaryLabel
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            tv.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 18 + tv.textContainer.lineFragmentPadding),
                placeholder.topAnchor.constraint(equalTo: tv.topAnchor, constant: 8)
            ])
            updatePlaceholder(tv)
        }

        func updatePlaceholder(_ tv: UITextView) { placeholder.isHidden = !tv.text.isEmpty }

        func textViewDidChange(_ tv: UITextView) {
            bridge?.lastEdit = Date()
            styleSectionTags(tv)
            updatePlaceholder(tv)
            bridge?.emit()
        }

        /// Lines like [Chorus] are bold and slate, the way the web styles them (tagBold).
        private func styleSectionTags(_ tv: UITextView) {
            let s = tv.textStorage
            let ns = s.string as NSString
            let sel = tv.selectedRange
            var changed = false
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, r, _, _ in
                guard r.length > 0 else { return }
                let line = ns.substring(with: r)
                let isTag = line.range(of: #"^\s*\[[^\]]+\]\s*$"#, options: .regularExpression) != nil
                let slate = (s.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? UIColor).map { $0 == EditorBridge.slate } ?? false
                if isTag && !slate {
                    let bold = UIFont(descriptor: EditorBridge.baseFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? EditorBridge.baseFont.fontDescriptor, size: EditorBridge.baseFont.pointSize)
                    s.addAttributes([.foregroundColor: EditorBridge.slate, .font: bold], range: r); changed = true
                } else if !isTag && slate {
                    s.addAttributes([.foregroundColor: UIColor.label, .font: EditorBridge.baseFont], range: r); changed = true
                }
            }
            if changed { tv.selectedRange = sel; tv.typingAttributes = EditorBridge.baseAttributes }
        }
    }
}
