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
    /// The text and selection whenever either changes (the rhyme bar follows it).
    var onSelection: ((String, NSRange) -> Void)?
    weak var coordinator: RichTextEditor.Coordinator?
    /// Rhyme map and syllable counts (`songpad:view`).
    var showMap = UserDefaults.standard.bool(forKey: "view.map") { didSet { UserDefaults.standard.set(showMap, forKey: "view.map"); coordinator?.scheduleViews(now: true) } }
    var showSyl = UserDefaults.standard.bool(forKey: "view.syl") { didSet { UserDefaults.standard.set(showSyl, forKey: "view.syl"); coordinator?.scheduleViews(now: true) } }

    var caretLocation: Int { textView?.selectedRange.location ?? 0 }
    /// Rate mode: quotes to mark in the lyrics, green for what's working and red for issues.
    var rateMarks: [(quote: String, good: Bool)] = [] { didSet { coordinator?.scheduleViews(now: true) } }

    // MARK: inserting words

    /// A rhyme chip: replaces the selection, or the word at the caret, or goes in at the caret (with a
    /// space before it when needed), keeping the capitalisation of what it replaces.
    func insertWord(_ w: String, viaPartner: Bool) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        var target = tv.selectedRange
        if target.length == 0 && !viaPartner, let wr = wordRange(at: target.location, in: ns) { target = wr }
        let orig = ns.substring(with: target)
        var rep = Self.matchCase(w, orig)
        if target.length == 0, target.location > 0, let prev = Unicode.Scalar(ns.character(at: target.location - 1)), !CharacterSet.whitespacesAndNewlines.contains(prev) {
            rep = " " + rep
        }
        let end = replace(target, with: rep)
        tv.selectedRange = NSRange(location: end, length: 0)
        Haptics.tap()
    }

    /// Plain insertion at a given point (the Dictionary), returning where the caret ends up.
    @discardableResult
    func insertPlain(_ w: String, at loc: Int) -> Int {
        guard let tv = textView else { return loc }
        let ns = tv.text as NSString
        let at = min(loc, ns.length)
        var rep = w
        if at > 0, let prev = Unicode.Scalar(ns.character(at: at - 1)), !CharacterSet.whitespacesAndNewlines.contains(prev) { rep = " " + rep }
        let end = replace(NSRange(location: at, length: 0), with: rep)
        Haptics.tap()
        return end
    }

    /// A section tag on the caret's empty line; "[Chorus] + lyrics" brings the chorus's lines too.
    func insertSection(_ label: String) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let lr = ns.lineRange(for: NSRange(location: tv.selectedRange.location, length: 0))
        var content = NSRange(location: lr.location, length: lr.length)
        if content.length > 0 && ns.character(at: content.location + content.length - 1) == 10 { content.length -= 1 }
        var text = label.hasPrefix("[Chorus]") ? "[Chorus]" : label
        if label.contains("+ lyrics"), let ch = chorusText() { text += "\n" + ch }
        // a newline after it, unless a lyric line follows straight away
        let after = content.location + content.length
        var nextIsLyric = false
        if after < ns.length {
            let nr = ns.lineRange(for: NSRange(location: after + 1 <= ns.length ? min(after + 1, ns.length) : after, length: 0))
            nextIsLyric = !ns.substring(with: nr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !nextIsLyric { text += "\n" }
        let end = replace(content, with: text)
        tv.selectedRange = NSRange(location: end, length: 0)
        Haptics.tap()
    }

    /// The lines after the first [Chorus], up to a blank line or another tag.
    func chorusText(before limit: Int? = nil) -> String? {
        guard let t = textView?.text else { return nil }
        let lines = t.components(separatedBy: "\n")
        var pos = 0
        for (i, l) in lines.enumerated() {
            if l.trimmingCharacters(in: .whitespaces) == "[Chorus]" {
                if let limit, pos >= limit { return nil }
                var out: [String] = []
                for x in lines.dropFirst(i + 1) {
                    let tr = x.trimmingCharacters(in: .whitespaces)
                    if tr.isEmpty || tr.hasPrefix("[") { break }
                    out.append(x)
                }
                return out.isEmpty ? nil : out.joined(separator: "\n")
            }
            pos += (l as NSString).length + 1
        }
        return nil
    }

    private func wordRange(at loc: Int, in ns: NSString) -> NSRange? {
        let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z']+") else { return nil }
        for m in re.matches(in: ns as String, range: lr) where loc >= m.range.location && loc <= m.range.location + m.range.length {
            return m.range
        }
        return nil
    }

    static func matchCase(_ w: String, _ orig: String) -> String {
        let letters = orig.filter { $0.isLetter }
        if letters.count > 1 && letters == letters.uppercased() && letters != letters.lowercased() { return w.uppercased() }
        if let f = letters.first, f.isUppercase { return w.prefix(1).uppercased() + w.dropFirst() }
        return w
    }

    /// Replaces text through UIKit's text input, so it can be undone, and saves. Returns the end of the new text.
    @discardableResult
    func replace(_ range: NSRange, with text: String) -> Int {
        guard let tv = textView,
              let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let end = tv.position(from: start, offset: range.length),
              let tr = tv.textRange(from: start, to: end) else { return range.location }
        tv.replace(tr, withText: text)
        lastEdit = Date()
        coordinator?.afterChange(tv)
        return range.location + (text as NSString).length
    }

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

    /// Whether a style is on at the caret (or at the start of the selection), for the format buttons.
    func isOn(_ t: Trait) -> Bool {
        guard let tv = textView else { return false }
        let r = tv.selectedRange
        if r.length == 0 || tv.textStorage.length == 0 { return Self.has(t, tv.typingAttributes) }
        return Self.has(t, tv.textStorage.attributes(at: min(r.location, tv.textStorage.length - 1), effectiveRange: nil))
    }

    /// The attributes at the caret (typing attributes), or at the start of the selection.
    private var attributesHere: [NSAttributedString.Key: Any] {
        guard let tv = textView else { return [:] }
        let r = tv.selectedRange
        if r.length == 0 || tv.textStorage.length == 0 { return tv.typingAttributes }
        return tv.textStorage.attributes(at: min(r.location, tv.textStorage.length - 1), effectiveRange: nil)
    }

    /// The text colour in use here: one of RichText.textColors, or nil for the default (black / white).
    var activeColor: UIColor? {
        guard let c = attributesHere[.foregroundColor] as? UIColor else { return nil }
        return RichText.textColors.map(\.1).first { RichText.sameSwatch(c, $0) }
    }

    /// The highlight here, if it's one of the three.
    var activeHighlight: UIColor? {
        guard let c = attributesHere[.backgroundColor] as? UIColor else { return nil }
        return RichText.highlights.map(\.1).first { RichText.sameSwatch(c.withAlphaComponent(1), $0.withAlphaComponent(1)) }
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
    /// The song's cover and title: drawn inside the text view's scroll, above the lyrics, so they scroll away with it.
    var header: AnyView? = nil
    /// Space for the glass bars floating over the text; the text scrolls under them.
    var insets: UIEdgeInsets = .zero

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = LyricsTextView()
        tv.backgroundColor = .clear
        tv.font = EditorBridge.baseFont
        tv.typingAttributes = EditorBridge.baseAttributes
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 18, bottom: 24, right: 18)
        tv.contentInsetAdjustmentBehavior = .never
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        tv.autocapitalizationType = .sentences
        tv.smartDashesType = .no
        tv.smartQuotesType = .yes
        tv.allowsEditingTextAttributes = true
        tv.delegate = context.coordinator
        context.coordinator.bridge = bridge
        bridge.textView = tv
        bridge.coordinator = context.coordinator
        load(tv, context.coordinator)
        context.coordinator.placeholder.text = placeholder
        context.coordinator.attachPlaceholder(to: tv)
        if let header {
            let hc = UIHostingController(rootView: Self.pinned(header, tv))
            hc.view.backgroundColor = .clear
            hc.view.clipsToBounds = false
            hc.safeAreaRegions = []
            context.coordinator.headerHost = hc
            tv.header = hc
            tv.addSubview(hc.view)
            tv.onHeaderHeight = { [weak c = context.coordinator] h in c?.placeholderTop?.constant = h }
        }
        return tv
    }

    /// The header, pinned to the top of its host and reporting its own height whenever it changes
    /// (the player opening, a title wrapping), so it grows downward and the lyrics follow it.
    static func pinned(_ header: AnyView, _ tv: UITextView) -> AnyView {
        AnyView(
            header
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak tv] h in
                    (tv as? LyricsTextView)?.setHeaderHeight(h)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        bridge.textView = tv
        context.coordinator.bridge = bridge
        // the room for the top bar is part of the page (the header starts below it), so the title can
        // never end up under the bar however the view first scrolls; the bottom is a normal inset
        if let lt = tv as? LyricsTextView, abs(lt.topSpace - insets.top) > 0.5 {
            lt.topSpace = insets.top
            lt.setNeedsLayout()
        }
        if insets.bottom > 0 && abs(tv.contentInset.bottom - insets.bottom) > 0.5 {
            tv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: insets.bottom, right: 0)
            tv.verticalScrollIndicatorInsets.bottom = insets.bottom
            // the rhyme bar moved (keyboard, formatting row, Lines): keep the caret above it
            DispatchQueue.main.async { (tv as? LyricsTextView)?.keepCaretVisible(animated: true) }
        }
        if let header, let hc = context.coordinator.headerHost {
            hc.rootView = Self.pinned(header, tv)
        }
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
        c.scheduleViews(now: true)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        weak var bridge: EditorBridge?
        let placeholder = UILabel()
        var placeholderTop: NSLayoutConstraint?
        var headerHost: UIHostingController<AnyView>?

        func attachPlaceholder(to tv: UITextView) {
            placeholder.font = EditorBridge.baseFont
            placeholder.textColor = .tertiaryLabel
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            tv.addSubview(placeholder)
            let top = placeholder.topAnchor.constraint(equalTo: tv.topAnchor, constant: tv.textContainerInset.top)
            placeholderTop = top
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 18 + tv.textContainer.lineFragmentPadding),
                top
            ])
            updatePlaceholder(tv)
        }

        func updatePlaceholder(_ tv: UITextView) { placeholder.isHidden = !tv.text.isEmpty }

        func textViewDidChange(_ tv: UITextView) {
            bridge?.lastEdit = Date()
            afterChange(tv)
            // after the system's own scrolling, make sure the new text sits above the rhyme bar
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { (tv as? LyricsTextView)?.keepCaretVisible(animated: true) }
        }

        func afterChange(_ tv: UITextView) {
            normalizeBreaks(tv)
            styleSectionTags(tv)
            updatePlaceholder(tv)
            bridge?.emit()
            bridge?.onSelection?(tv.text, tv.selectedRange)
            scheduleViews()
        }

        /// Pasted text can carry \r\n, \r or Unicode line separators: they look like line breaks here but not on the
        /// Mac or web, so they become plain \n in place (the caret stays where it was).
        private func normalizeBreaks(_ tv: UITextView) {
            let str = tv.textStorage.string
            guard str.contains(where: { $0 == "\r\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }),
                  let re = try? NSRegularExpression(pattern: "\r\n|[\r\u{2028}\u{2029}]") else { return }
            let ms = re.matches(in: str, range: NSRange(location: 0, length: (str as NSString).length))
            guard !ms.isEmpty else { return }
            var caret = tv.selectedRange.location
            tv.textStorage.beginEditing()
            for m in ms.reversed() {
                tv.textStorage.replaceCharacters(in: m.range, with: "\n")
                if m.range.location < caret { caret -= max(0, min(m.range.length, caret - m.range.location) - 1) }
            }
            tv.textStorage.endEditing()
            tv.selectedRange = NSRange(location: min(caret, tv.textStorage.length), length: 0)
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            bridge?.onSelection?(tv.text, tv.selectedRange)
            // only while typing (an empty selection); a drag-selection is left where the finger put it
            if tv.selectedRange.length == 0, !tv.isTracking, !tv.isDragging, !tv.isDecelerating {
                DispatchQueue.main.async { (tv as? LyricsTextView)?.keepCaretVisible(animated: true) }
            }
        }

        /// Return on a [Chorus] line, when an earlier chorus exists, brings that chorus's lines (spec §4.3).
        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", range.length == 0, let bridge else { return true }
            let ns = tv.text as NSString
            let lr = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line == "[Chorus]", let ch = bridge.chorusText(before: lr.location) else { return true }
            let end = bridge.replace(range, with: "\n" + ch + "\n")
            tv.selectedRange = NSRange(location: end, length: 0)
            Haptics.tap()
            return false
        }

        // MARK: rhyme map and syllable counts (drawn over the text, never saved into it)

        private var viewsTask: Task<Void, Never>?
        private let gutter = UIView()
        static let mapColours: [UIColor] = [
            UIColor(red: 1, green: 149 / 255, blue: 0, alpha: 0.30), UIColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 0.28),
            UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 0.24), UIColor(red: 175 / 255, green: 82 / 255, blue: 222 / 255, alpha: 0.26),
            UIColor(red: 1, green: 45 / 255, blue: 85 / 255, alpha: 0.24), UIColor(red: 90 / 255, green: 200 / 255, blue: 250 / 255, alpha: 0.34),
            UIColor(red: 1, green: 204 / 255, blue: 0, alpha: 0.38), UIColor(red: 162 / 255, green: 132 / 255, blue: 94 / 255, alpha: 0.32)
        ]

        func scheduleViews(now: Bool = false) {
            viewsTask?.cancel()
            viewsTask = Task { [weak self] in
                if !now { try? await Task.sleep(for: .milliseconds(140)) }
                guard !Task.isCancelled, let self, let tv = self.bridge?.textView else { return }
                self.applyViews(tv)
            }
        }

        private func applyViews(_ tv: UITextView) {
            guard let bridge, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return }
            let text = tv.text ?? ""
            // rhyme map
            tlm.removeRenderingAttribute(.backgroundColor, for: tlm.documentRange)
            if bridge.showMap {
                for (r, ci) in RhymeMap.ranges(text) {
                    guard let s = tcm.location(tcm.documentRange.location, offsetBy: r.location),
                          let e = tcm.location(s, offsetBy: r.length), let tr = NSTextRange(location: s, end: e) else { continue }
                    tlm.addRenderingAttribute(.backgroundColor, value: Self.mapColours[ci], for: tr)
                }
            }
            // Rate's marks (rkgood / rkbad)
            for m in bridge.rateMarks {
                guard let r = EditorBridge.findQuote(m.quote, in: text),
                      let s = tcm.location(tcm.documentRange.location, offsetBy: r.location),
                      let e = tcm.location(s, offsetBy: r.length), let tr = NSTextRange(location: s, end: e) else { continue }
                tlm.addRenderingAttribute(.backgroundColor, value: m.good ? UIColor.systemGreen.withAlphaComponent(0.2) : UIColor.systemRed.withAlphaComponent(0.18), for: tr)
            }
            // syllable gutter
            let wantLeft: CGFloat = bridge.showSyl ? 50 : 18
            if tv.textContainerInset.left != wantLeft { tv.textContainerInset.left = wantLeft }
            gutter.subviews.forEach { $0.removeFromSuperview() }
            guard bridge.showSyl else { gutter.removeFromSuperview(); return }
            if gutter.superview == nil { tv.addSubview(gutter) }
            gutter.frame = CGRect(x: 0, y: 0, width: 44, height: max(tv.contentSize.height, tv.bounds.height))
            tlm.ensureLayout(for: tlm.documentRange)
            var pos = 0
            for l in text.components(separatedBy: "\n") {
                let len = (l as NSString).length
                let tr = l.trimmingCharacters(in: .whitespaces)
                if !tr.isEmpty && !tr.hasPrefix("["),
                   let loc = tcm.location(tcm.documentRange.location, offsetBy: pos),
                   let frag = tlm.textLayoutFragment(for: loc) {
                    let f = frag.layoutFragmentFrame
                    let lineH = frag.textLineFragments.first?.typographicBounds.height ?? f.height
                    let lab = UILabel(frame: CGRect(x: 6, y: f.minY + tv.textContainerInset.top, width: 34, height: lineH))
                    lab.text = "\(RhymeEngine.shared.lineSyllables(l))"
                    lab.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
                    lab.textColor = .tertiaryLabel
                    lab.textAlignment = .right
                    gutter.addSubview(lab)
                }
                pos += len + 1
            }
        }

        static func near(_ a: UIColor, _ b: UIColor) -> Bool {
            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0, r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1); b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return abs(r1 - r2) < 0.02 && abs(g1 - g2) < 0.02 && abs(b1 - b2) < 0.02
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
                let slate = (s.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? UIColor).map { Self.near($0, EditorBridge.slate) } ?? false
                // only ever adds the tag style (never takes it away: Slate is also a colour people pick)
                if isTag && !slate {
                    let bold = UIFont(descriptor: EditorBridge.baseFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? EditorBridge.baseFont.fontDescriptor, size: EditorBridge.baseFont.pointSize)
                    s.addAttributes([.foregroundColor: EditorBridge.slate, .font: bold], range: r); changed = true
                }
            }
            if changed { tv.selectedRange = sel; tv.typingAttributes = EditorBridge.baseAttributes }
        }
    }
}

/// A text view that carries the song's header (cover and title) at the top of its scroll,
/// and pushes the lyrics down below it.
final class LyricsTextView: UITextView {
    var header: UIHostingController<AnyView>?
    var onHeaderHeight: ((CGFloat) -> Void)?
    /// Empty space at the top of the page for the floating top bar.
    var topSpace: CGFloat = 0
    private var lastTop: CGFloat = -1
    /// Reported by the header itself (0 until it first lays out).
    private var headerHeight: CGFloat = 0
    /// The room the floating top bar takes (status bar + bar), worked out in layout.
    private(set) var barSpace: CGFloat = 0
    private var keyboardWatch: [NSObjectProtocol] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        keyboardWatch.forEach(NotificationCenter.default.removeObserver)
        keyboardWatch = []
        guard window != nil else { return }
        // the keyboard (and the rhyme bar riding on it) came up or changed size: bring the caret back into view
        for n in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidChangeFrameNotification] {
            keyboardWatch.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                // once the rhyme bar has settled on the keyboard (the web waits 260 ms)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(260))
                    self?.keepCaretVisible(animated: true)
                }
            })
        }
    }

    /// The web's reveal(): while typing (an empty selection), the line you're on is centred between the top bar
    /// and the rhyme bar (which rides on the keyboard), so you never type off screen and the page keeps a steady
    /// rhythm; with words selected it only scrolls when the end of the selection goes off screen.
    func keepCaretVisible(animated: Bool, center: Bool? = nil) {
        guard isFirstResponder, let r = selectedTextRange else { return }
        let caret = caretRect(for: r.end)
        guard !caret.isNull, !caret.isInfinite, caret.height > 0 else { return }
        let centre = center ?? r.isEmpty
        let top = contentOffset.y + barSpace + 12
        let bottom = contentOffset.y + bounds.height - contentInset.bottom - 14
        guard bottom > top else { return }
        var y = contentOffset.y
        if centre {
            y += caret.midY - (top + bottom) / 2
        } else if caret.maxY > bottom {
            y += caret.maxY - bottom
        } else if caret.minY < top {
            y -= top - caret.minY
        } else { return }
        let maxY = max(0, contentSize.height + contentInset.bottom - bounds.height)
        y = min(max(0, y), maxY)
        guard abs(y - contentOffset.y) > 0.5 else { return }
        revealing = true
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: animated)
        revealing = false
    }

    private var revealing = false

    /// UIKit's own "scroll the caret into view" doesn't know about the floating bars: while typing, ours runs instead.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        if isFirstResponder && !revealing && !isTracking && !isDragging {
            DispatchQueue.main.async { [weak self] in self?.keepCaretVisible(animated: true) }
            return
        }
        super.scrollRectToVisible(rect, animated: animated)
    }

    /// The header's new height: the lyrics move down (or up) to match, animated like the header.
    func setHeaderHeight(_ h: CGFloat) {
        let h = ceil(h)
        guard abs(h - headerHeight) > 0.5 else { return }
        let first = headerHeight == 0
        headerHeight = h
        if first || window == nil {
            setNeedsLayout()
        } else {
            UIView.animate(withDuration: 0.33, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        // the floating top bar: the status bar, then 8 + 48 + 12 pt (EditorScreen.topBar)
        let barRoom = (window?.safeAreaInsets.top ?? safeAreaInsets.top) + 68
        let space = max(topSpace, barRoom)
        barSpace = space
        var h: CGFloat = 0
        if let hc = header {
            if headerHeight == 0 {
                // until the header reports in, measure it once so the first frame is right
                headerHeight = ceil(hc.sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude)).height)
            }
            h = headerHeight
            let f = CGRect(x: 0, y: space, width: w, height: max(1, h))
            if hc.view.frame != f { hc.view.frame = f }
        }
        if abs(verticalScrollIndicatorInsets.top - space) > 0.5 { verticalScrollIndicatorInsets.top = space }
        if contentInset.bottom < 1 { contentInset.bottom = 240 }   // the rhyme bar, until it's measured
        let top = space + h + 8
        if abs(textContainerInset.top - top) > 0.5 {
            textContainerInset.top = top
        }
        if top != lastTop {
            lastTop = top
            onHeaderHeight?(top)
        }
    }
}
