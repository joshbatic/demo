import UIKit

/// Converts between a song's `rich` HTML (the web editor's innerHTML, spec §1.2) and a native
/// attributed string, and back. Only the subset the web allows is understood; everything else is
/// dropped the same way the web's `clean()` does, so nothing unsafe from a co-writer gets rendered.
///
/// Written back as `<span style="…">` runs and `<br>`, exactly what the web editor produces, so the
/// formatting survives a round trip through every client.
nonisolated enum RichText {
    struct Style: Equatable {
        var bold = false, italic = false, underline = false, strike = false
        var color: UIColor? = nil
        var highlight: UIColor? = nil
    }

    // MARK: HTML → attributed

    static func attributed(html: String, plain: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let runs = html.isEmpty ? [(plain, Style())] : parse(html)
        let out = NSMutableAttributedString()
        for (text, st) in runs where !text.isEmpty {
            out.append(NSAttributedString(string: text, attributes: attrs(for: st, font: font, color: color)))
        }
        return out
    }

    static func attrs(for st: Style, font base: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if st.bold { traits.insert(.traitBold) }
        if st.italic { traits.insert(.traitItalic) }
        var f = base
        if !traits.isEmpty, let d = base.fontDescriptor.withSymbolicTraits(traits) { f = UIFont(descriptor: d, size: base.pointSize) }
        var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: st.color ?? color]
        if st.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if st.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let h = st.highlight { a[.backgroundColor] = h }
        return a
    }

    private static let allowed: Set<String> = ["b", "i", "u", "s", "strike", "strong", "em", "span", "br", "font", "mark", "div", "p"]

    /// Parses the HTML subset into styled text runs.
    static func parse(_ html: String) -> [(String, Style)] {
        var runs: [(String, Style)] = []
        var stack: [(tag: String, style: Style)] = [("", Style())]
        var skipDepth = 0            // inside a tag that's removed along with its content
        var text = ""
        var i = html.startIndex

        func cur() -> Style { stack.last!.style }
        func flush() { if !text.isEmpty { runs.append((text, cur())); text = "" } }
        func newline() { flush(); runs.append(("\n", cur())) }
        func lastChar() -> Character? { if let c = text.last { return c }; return runs.last?.0.last }

        while i < html.endIndex {
            let c = html[i]
            if c == "<", let close = html[i...].firstIndex(of: ">") {
                let inner = String(html[html.index(after: i)..<close])
                i = html.index(after: close)
                if inner.hasPrefix("!") { continue }               // comments, doctypes
                let isEnd = inner.hasPrefix("/")
                let body = isEnd ? String(inner.dropFirst()) : inner
                let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
                let selfClosing = inner.hasSuffix("/") || name == "br"
                if skipDepth > 0 {
                    if !allowed.contains(name) && !selfClosing { skipDepth += isEnd ? -1 : 1 }
                    continue
                }
                if !allowed.contains(name) {
                    if !isEnd && !selfClosing && !["img", "hr", "input", "meta", "link", "wbr"].contains(name) { skipDepth = 1 }
                    continue
                }
                if name == "br" { newline(); continue }
                if isEnd {
                    flush()
                    if let idx = stack.lastIndex(where: { $0.tag == name }), idx > 0 { stack.removeSubrange(idx...) }
                    if name == "div" || name == "p" { if lastChar() != "\n" { newline() } }
                    continue
                }
                flush()
                if (name == "div" || name == "p"), let lc = lastChar(), lc != "\n" { newline() }
                var st = cur()
                switch name {
                case "b", "strong": st.bold = true
                case "i", "em": st.italic = true
                case "u": st.underline = true
                case "s", "strike": st.strike = true
                case "mark": st.highlight = UIColor(red: 1, green: 0.8, blue: 0, alpha: 0.38)
                case "font": if let col = attr(body, "color"), let u = color(col) { st.color = u }
                default: break
                }
                if let style = attr(body, "style") { apply(css: style, to: &st) }
                stack.append((name, st))
            } else {
                if skipDepth > 0 { i = html.index(after: i); continue }
                if c == "&", let semi = html[i...].prefix(10).firstIndex(of: ";") {
                    let ent = String(html[html.index(after: i)..<semi])
                    if let d = entity(ent) { text += d; i = html.index(after: semi); continue }
                }
                if c != "\n" && c != "\r" { text.append(c) }       // raw newlines in HTML are not line breaks
                i = html.index(after: i)
            }
        }
        flush()
        // a trailing line break the editor keeps for the caret isn't part of the text
        if let last = runs.last, last.0 == "\n" { runs.removeLast() }
        return runs
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        let pattern = name + #"\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for g in 2...4 { if let r = Range(m.range(at: g), in: tag) { return decodeEntities(String(tag[r])) } }
        return nil
    }

    /// The web's style allow-list: refuse the whole style if it has anything odd in it.
    private static func apply(css: String, to st: inout Style) {
        let lower = css.lowercased()
        if lower.contains("url(") || lower.contains("expression") || css.contains("@") || css.contains("\\") { return }
        if css.range(of: #"[^\w\s:;#.,%()\-]"#, options: .regularExpression) != nil { return }
        for decl in css.split(separator: ";") {
            let parts = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2 else { continue }
            let (k, v) = (parts[0], parts[1])
            if v.contains("position") || v.contains("fixed") || v.contains("absolute") { continue }
            switch k {
            case "font-weight": st.bold = v == "bold" || v == "bolder" || (Int(v) ?? 400) >= 600
            case "font-style": st.italic = v.contains("italic") || v.contains("oblique")
            case "text-decoration", "text-decoration-line":
                if v.contains("underline") { st.underline = true }
                if v.contains("line-through") { st.strike = true }
                if v == "none" { st.underline = false; st.strike = false }
            case "color": if let c = color(v) { st.color = c }
            case "background-color", "background": if let c = color(v) { st.highlight = c.cgColor.alpha == 0 ? nil : c }
            default: break
            }
        }
    }

    static func color(_ v: String) -> UIColor? {
        let s = v.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            var h = String(s.dropFirst())
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6, let n = UInt32(h, radix: 16) else { return nil }
            return UIColor(red: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
        }
        if s.hasPrefix("rgb"), let o = s.firstIndex(of: "("), let c = s.firstIndex(of: ")") {
            let n = s[s.index(after: o)..<c].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            guard n.count >= 3 else { return nil }
            return UIColor(red: n[0] / 255, green: n[1] / 255, blue: n[2] / 255, alpha: n.count > 3 ? n[3] : 1)
        }
        let named: [String: UInt32] = ["red": 0xFF0000, "black": 0x000000, "white": 0xFFFFFF, "gray": 0x808080, "grey": 0x808080, "blue": 0x0000FF, "green": 0x008000, "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080]
        if s == "transparent" { return UIColor(white: 0, alpha: 0) }
        if let n = named[s] { return color(String(format: "#%06x", n)) }
        return nil
    }

    private static func entity(_ e: String) -> String? {
        switch e {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp", "#160": return " "
        default:
            if e.hasPrefix("#x"), let n = UInt32(e.dropFirst(2), radix: 16), let u = Unicode.Scalar(n) { return String(Character(u)) }
            if e.hasPrefix("#"), let n = UInt32(e.dropFirst()), let u = Unicode.Scalar(n) { return String(Character(u)) }
            return nil
        }
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(10).firstIndex(of: ";"), let d = entity(String(s[s.index(after: i)..<semi])) {
                out += d; i = s.index(after: semi)
            } else { out.append(s[i]); i = s.index(after: i) }
        }
        return out
    }

    // MARK: attributed → HTML

    /// The `rich` HTML for an attributed string: one `<span style>` per styled run, `<br>` for line
    /// breaks, plain text unwrapped. Returns "" when nothing is formatted, so plain songs stay plain.
    static func html(from s: NSAttributedString, baseColor: UIColor) -> String {
        var out = ""
        var anyStyle = false
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { a, range, _ in
            let text = (s.string as NSString).substring(with: range)
            var css: [String] = []
            if let f = a[.font] as? UIFont {
                let t = f.fontDescriptor.symbolicTraits
                if t.contains(.traitBold) { css.append("font-weight: bold") }
                if t.contains(.traitItalic) { css.append("font-style: italic") }
            }
            var deco: [String] = []
            if let u = a[.underlineStyle] as? Int, u != 0 { deco.append("underline") }
            if let st = a[.strikethroughStyle] as? Int, st != 0 { deco.append("line-through") }
            if !deco.isEmpty { css.append("text-decoration: " + deco.joined(separator: " ")) }
            if let c = a[.foregroundColor] as? UIColor, !same(c, baseColor) { css.append("color: " + rgb(c)) }
            if let h = a[.backgroundColor] as? UIColor, h.cgColor.alpha > 0 { css.append("background-color: " + rgb(h)) }
            let body = escape(text)
            if css.isEmpty { out += body } else { anyStyle = true; out += "<span style=\"" + css.joined(separator: "; ") + ";\">" + body + "</span>" }
        }
        return anyStyle ? out : ""
    }

    private static func escape(_ t: String) -> String {
        t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func comps(_ c: UIColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
    private static func same(_ x: UIColor, _ y: UIColor) -> Bool {
        let a = comps(x), b = comps(y)
        return abs(a.0 - b.0) < 0.01 && abs(a.1 - b.1) < 0.01 && abs(a.2 - b.2) < 0.01 && abs(a.3 - b.3) < 0.01
    }
    private static func rgb(_ c: UIColor) -> String {
        let (r, g, b, a) = comps(c)
        let R = Int((r * 255).rounded()), G = Int((g * 255).rounded()), B = Int((b * 255).rounded())
        if a < 0.999 { return "rgba(\(R), \(G), \(B), \(CanonicalJSON.number((Double(a) * 100).rounded() / 100)))" }
        return "rgb(\(R), \(G), \(B))"
    }

    // MARK: the web's palette (spec §1.2)

    static let textColors: [(String, UIColor)] = [
        ("Rose", UIColor(red: 0.898, green: 0.337, blue: 0.435, alpha: 1)), ("Amber", UIColor(red: 0.831, green: 0.533, blue: 0.110, alpha: 1)),
        ("Moss", UIColor(red: 0.306, green: 0.604, blue: 0.357, alpha: 1)), ("Tide", UIColor(red: 0.173, green: 0.553, blue: 0.749, alpha: 1)),
        ("Indigo", UIColor(red: 0.365, green: 0.420, blue: 0.878, alpha: 1)), ("Plum", UIColor(red: 0.639, green: 0.373, blue: 0.796, alpha: 1)),
        ("Slate", UIColor(red: 0.557, green: 0.557, blue: 0.588, alpha: 1))
    ]
    static let highlights: [(String, UIColor)] = [
        ("Hook", UIColor(red: 1, green: 0.8, blue: 0, alpha: 0.38)),
        ("Rework", UIColor(red: 1, green: 0.271, blue: 0.227, alpha: 0.24)),
        ("Idea", UIColor(red: 0.039, green: 0.518, blue: 1, alpha: 0.22))
    ]
}


extension RichText {
    /// Two colours are the same swatch if their RGB is within 2%.
    static func sameSwatch(_ a: UIColor, _ b: UIColor) -> Bool {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0, r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1); b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return abs(r1 - r2) < 0.02 && abs(g1 - g2) < 0.02 && abs(b1 - b2) < 0.02
    }
}
