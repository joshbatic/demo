import Foundation

/// The built-in rhyme dictionary and engine, ported line for line from the web app (engines.md §1):
/// 45,230 words in 13,441 rhyme groups (CMU pronunciations), perfect and near rhymes, syllables,
/// the word the rhyme bar targets, chip ordering and the rhyme map.
nonisolated final class RhymeEngine: @unchecked Sendable {
    static let shared = RhymeEngine()

    struct Entry { let group: Int; let tier: Int; let syl: Int; let flag: Character? }
    struct Sets { let group: Int?; let perfect: [String]; let near: [String] }

    private(set) var words: [String: Entry] = [:]
    private(set) var groups: [[String]] = []
    private(set) var keys: [[String]] = []
    private var byTier: [String] = []
    private var suffixBest: [String: String]?
    private var cache: [String: Sets] = [:]
    private let lock = NSLock()
    private(set) var loaded = false

    static let vowels: Set<String> = ["AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"]
    static let consonantClass: [String: String] = ["M": "n", "N": "n", "NG": "n", "P": "t", "B": "t", "T": "t", "D": "t", "K": "t", "G": "t", "F": "s", "V": "s", "S": "s", "Z": "s", "SH": "s", "ZH": "s", "TH": "s", "DH": "s", "CH": "c", "JH": "c", "L": "l", "R": "r", "HH": "h", "W": "w", "Y": "w"]
    static let vowelFamily: [String: Int] = ["IH": 1, "IY": 1, "EH": 2, "AE": 2, "EY": 2, "AA": 3, "AO": 3, "AH": 4, "UH": 4, "UW": 4, "OW": 5, "AW": 5, "AY": 6, "OY": 7, "ER": 8]
    /// Words the rhyme map never colours (engines.md §1.10).
    static let stop: Set<String> = Set("a an the and or but to of in on at by for with as is it its be am are was were i me my we us our you your he him his she her they them their this that these those so do did does not no just oh if then than from can will would could should have has had there what when where who how im ive id dont cant wont aint like".split(separator: " ").map(String.init))

    private init() {}

    /// Parses the dictionary (Rhymes.tsv in the app bundle). Safe to call more than once.
    func load() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded, let url = Bundle.main.url(forResource: "Rhymes", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var w: [String: Entry] = [:]; w.reserveCapacity(46000)
        var g: [[String]] = [], k: [[String]] = [], all: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let gi = g.count
            var ws: [String] = []
            for tok in parts[1].split(separator: " ") {
                var t = Substring(tok)
                var flag: Character? = nil
                if let last = t.last, last == "c" || last == "s" { flag = last; t = t.dropLast() }
                guard t.count >= 3, let tier = t.dropLast().last?.wholeNumberValue, let syl = t.last?.wholeNumberValue else { continue }
                let word = String(t.dropLast(2))
                w[word] = Entry(group: gi, tier: tier, syl: syl, flag: flag)
                ws.append(word); all.append(word)
            }
            g.append(ws)
            k.append(parts[0].split(separator: "-").map(String.init))
        }
        // every word by frequency tier, keeping file order within a tier (JS sort is stable)
        let tiers = all.enumerated().map { (i: $0.offset, w: $0.element, t: w[$0.element]?.tier ?? 9) }
        byTier = tiers.sorted { $0.t != $1.t ? $0.t < $1.t : $0.i < $1.i }.map(\.w)
        words = w; groups = g; keys = k
        loaded = true
    }

    // MARK: words

    /// `nw`: lowercase, letters only ("Don't" → "dont").
    static func normalise(_ w: String) -> String { String(w.lowercased().unicodeScalars.filter { $0.value >= 97 && $0.value <= 122 }.map(Character.init)) }

    /// `hsyl`: the syllable rule for words not in the dictionary.
    static func guessSyllables(_ word: String) -> Int {
        var s = word
        if s.count <= 3 { return 1 }
        if let r = s.range(of: #"(?:[^laeiouy]es|[^td]ed|[^laeiouy]e)$"#, options: .regularExpression) { s.removeSubrange(r) }
        if s.hasPrefix("y") { s.removeFirst() }
        let n = s.matches(of: #/[aeiouy]{1,2}/#).count
        return n > 0 ? n : 1
    }

    func syllables(_ w: String) -> Int {
        let n = Self.normalise(w)
        if n.isEmpty { return 0 }
        if let e = words[n] { return e.syl }
        return Self.guessSyllables(n)
    }

    /// `lsyl`: syllables in a line.
    func lineSyllables(_ l: String) -> Int {
        l.matches(of: #/[A-Za-z']+/#).reduce(0) { $0 + syllables(String(l[$1.range])) }
    }

    /// `guess`: an unknown word takes the group of the most common word sharing its longest ending (2+ letters).
    func guessGroup(_ w: String) -> Int? {
        lock.lock()
        if suffixBest == nil {
            var m: [String: String] = [:]
            for x in byTier {
                let cs = Array(x)
                for len in stride(from: 2, through: min(cs.count, 12), by: 1) {
                    let suf = String(cs[(cs.count - len)...])
                    if m[suf] == nil { m[suf] = x }
                }
            }
            suffixBest = m
        }
        let m = suffixBest!
        lock.unlock()
        let cs = Array(w)
        var len = min(cs.count, 12)
        while len >= 2 {
            if let x = m[String(cs[(cs.count - len)...])] { return words[x]?.group }
            len -= 1
        }
        return nil
    }

    // MARK: rhymes

    private static func isV(_ p: String) -> Bool { vowels.contains(p) }
    private static func cls(_ a: [String]) -> String { a.map { consonantClass[$0] ?? $0 }.joined() }

    /// `gscore`: how near two rhyme parts are (6+ counts as a near rhyme).
    static func score(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a.filter(isV).count != b.filter(isV).count { return 0 }
        let ca = a.dropFirst().filter { !isV($0) }, cb = b.dropFirst().filter { !isV($0) }
        var s = 0
        if a[0] == b[0] { s += 4 }
        else if let fa = vowelFamily[a[0]], fa == vowelFamily[b[0]] { s += 2 }
        else { return 0 }
        if ca == cb { s += 4 }
        else if cls(Array(ca)) == cls(Array(cb)) { s += 3 }
        else if let x = ca.last, let y = cb.last, x == y { s += 2 }
        if a.dropFirst().filter(isV) == b.dropFirst().filter(isV) { s += 1 }
        return s
    }

    /// `rsets`: perfect rhymes (same group) and near rhymes (groups scoring 6+, best first, up to 500).
    func sets(_ word: String) -> Sets {
        let w = Self.normalise(word)
        lock.lock()
        if let c = cache[w] { lock.unlock(); return c }
        lock.unlock()
        guard loaded, !w.isEmpty else { return Sets(group: nil, perfect: [], near: []) }
        let gi = words[w]?.group ?? guessGroup(w)
        var p: [String] = [], n: [String] = []
        if let gi {
            p = groups[gi].filter { $0 != w }
            var scored: [(w: String, s: Int, t: Int, i: Int)] = []
            var idx = 0
            for g in 0..<keys.count where g != gi {
                let s = Self.score(keys[gi], keys[g])
                if s >= 6 {
                    for x in groups[g] { scored.append((x, s, words[x]?.tier ?? 9, idx)); idx += 1 }
                }
            }
            scored.sort { $0.s != $1.s ? $0.s > $1.s : ($0.t != $1.t ? $0.t < $1.t : $0.i < $1.i) }
            n = scored.prefix(500).map(\.w).filter { $0 != w }
        }
        let r = Sets(group: gi, perfect: p, near: n)
        lock.lock(); cache[w] = r; lock.unlock()
        return r
    }

    /// `fl`: casual words are hidden only for Poetic language; slang only shows for Slang or Explicit.
    func filter(_ list: [String], register: String) -> [String] {
        list.filter { x in
            guard let f = words[x]?.flag else { return true }
            return (f == "c" && register != "Poetic") || (f == "s" && (register == "Slang" || register == "Explicit"))
        }
    }

    /// `order`: rare words last; when the line needs exactly `left` more syllables, those words first.
    func order(_ a: [String], left: Int, syl: (String) -> Int) -> [String] {
        func rare(_ x: String) -> Bool {
            let w = Self.normalise(x)
            guard let e = words[w] else { return false }
            return e.tier >= 8 || (e.syl >= 2 && w.count <= e.syl)
        }
        let o = a.filter { !rare($0) } + a.filter(rare)
        guard left > 0 else { return o }
        let fit = { (x: String) in syl(x) == left && !rare(x) }
        return o.filter(fit) + o.filter { !fit($0) }
    }

    func rhymesWith(_ a: String, _ b: String) -> Bool {
        let x = Self.normalise(a), y = Self.normalise(b)
        if x.isEmpty || y.isEmpty { return false }
        if x == y { return true }
        let s = sets(x)
        return s.perfect.contains(y) || s.near.contains(y)
    }
}

/// What the rhyme bar is working on: the word, its line and the rhyme scheme (engines.md §1.8, `ctx()`).
nonisolated struct RhymeContext: Equatable {
    var line = ""            // the caret's line ("" for a [Section] line)
    var lineRange = NSRange(location: 0, length: 0)
    var selection = ""
    var word = ""
    var stanza: [String] = []
    var scheme = "ABAB"
    var partnerIndex = -1    // 0-based line within the stanza this line should rhyme with
    var partner = ""
    var via = ""             // "line N" when the word came from the partner line
    var ref = ""             // the line whose syllables to match

    static func make(text: String, selection sel: NSRange, scheme: String) -> RhymeContext {
        let v = text as NSString
        let a = min(sel.location, v.length), b = min(sel.location + sel.length, v.length)
        var ls = 0
        if a > 0 {
            let r = v.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: a))
            if r.location != NSNotFound { ls = r.location + 1 }
        }
        var le = v.length
        let rr = v.range(of: "\n", options: [], range: NSRange(location: a, length: v.length - a))
        if rr.location != NSNotFound { le = rr.location }
        let c = v.substring(with: NSRange(location: ls, length: le - ls))
        let cl = c.trimmingCharacters(in: .whitespaces).hasPrefix("[") ? "" : c
        let st = stanza(v.substring(to: ls))
        let p = st.count, q = p % 4, base = p - q
        let sch = scheme == "auto" ? autoScheme(st, q, base) : scheme
        let r = relIndex(sch, q)
        let ti = r >= 0 ? base + r : -1
        let tl = ti >= 0 && ti < st.count ? st[ti] : ""
        let selText = b > a ? v.substring(with: NSRange(location: a, length: b - a)) : ""
        var word = "", via = ""
        if !selText.isEmpty { word = lastWord(selText) }
        else if !cl.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmedEnd = (cl.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) as NSString).length
            let end = ls + trimmedEnd
            if a >= end && !tl.isEmpty { word = lastWord(tl); via = "line \(ti + 1)" }
            else { word = wordAt(cl, a - ls) ?? "" }
        }
        var ctx = RhymeContext()
        ctx.line = cl; ctx.lineRange = NSRange(location: ls, length: le - ls); ctx.selection = selText
        ctx.word = word; ctx.stanza = st; ctx.scheme = sch; ctx.partnerIndex = ti; ctx.partner = tl
        ctx.via = via; ctx.ref = !tl.isEmpty ? tl : (st.last ?? "")
        return ctx
    }

    /// The lines above the caret's line, back to a blank line or a [Section] tag.
    static func stanza(_ before: String) -> [String] {
        var lines = before.components(separatedBy: "\n")
        lines.removeLast()
        var out: [String] = []
        for l in lines.reversed() {
            let s = l.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("[") { break }
            out.insert(l, at: 0)
        }
        return out
    }

    static func lastWord(_ l: String) -> String {
        guard let m = l.matches(of: #/[A-Za-z']+/#).last else { return "" }
        return String(l[m.range])
    }

    /// The word containing column `c` (UTF-16), else the last word before it.
    static func wordAt(_ l: String, _ c: Int) -> String? {
        let ns = l as NSString
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z']+") else { return nil }
        var before: String?
        for m in re.matches(in: l, range: NSRange(location: 0, length: ns.length)) {
            let s = m.range.location, e = s + m.range.length
            if c >= s && c <= e { return ns.substring(with: m.range) }
            if e <= c { before = ns.substring(with: m.range) }
        }
        return before
    }

    static func endMatch(_ a: String, _ b: String) -> Bool { RhymeEngine.shared.rhymesWith(lastWord(a), lastWord(b)) }

    static func relIndex(_ s: String, _ q: Int) -> Int {
        switch s {
        case "AABB": return q % 2 == 1 ? q - 1 : -1
        case "ABAB": return q >= 2 ? q - 2 : -1
        case "ABBA": return q == 2 ? 1 : q == 3 ? 0 : -1
        case "ABCB": return q == 3 ? 1 : -1
        case "AAAA": return q >= 1 ? q - 1 : -1
        default: return -1
        }
    }

    /// Picks the scheme the stanza's existing line endings fit best (ties keep ABAB).
    static func autoScheme(_ st: [String], _ q: Int, _ base: Int) -> String {
        let ex: [(String, [(Int, Int)])] = [("ABAB", [(0, 2), (1, 3)]), ("AABB", [(0, 1), (2, 3)]), ("ABBA", [(1, 2), (0, 3)]), ("ABCB", [(1, 3)])]
        var best = "ABAB", bs = -1
        for (k, pairs) in ex {
            var sc = 0
            for (x, y) in pairs {
                let i = base + x, j = base + y
                if j < st.count && endMatch(st[i], st[j]) { sc += 1 }
            }
            if sc > bs { bs = sc; best = k }
        }
        return best
    }
}

/// The rhyme map (engines.md §1.10): words that rhyme within a stanza share one of 8 colours.
nonisolated enum RhymeMap {
    /// (UTF-16 range, colour index 0…7) for every word to colour.
    static func ranges(_ text: String) -> [(NSRange, Int)] {
        let eng = RhymeEngine.shared
        guard eng.loaded else { return [] }
        struct Tok { let w: String; let r: NSRange; let s: Int; var gi = -1 }
        var toks: [Tok] = []
        let ns = text as NSString
        var pos = 0, stz = 0
        let re = try! NSRegularExpression(pattern: "[A-Za-z']+")
        for l in text.components(separatedBy: "\n") {
            let ll = (l as NSString).length
            let tr = l.trimmingCharacters(in: .whitespaces)
            if tr.isEmpty || tr.hasPrefix("[") { stz += 1; pos += ll + 1; continue }
            for m in re.matches(in: l, range: NSRange(location: 0, length: ll)) {
                let w = RhymeEngine.normalise((l as NSString).substring(with: m.range))
                if w.count > 1 && !RhymeEngine.stop.contains(w) {
                    toks.append(Tok(w: w, r: NSRange(location: pos + m.range.location, length: m.range.length), s: stz))
                }
            }
            pos += ll + 1
        }
        _ = ns
        var byStanza: [Int: [Tok]] = [:], order: [Int] = []
        for var t in toks {
            guard let gi = eng.sets(t.w).group else { continue }
            t.gi = gi
            if byStanza[t.s] == nil { order.append(t.s) }
            byStanza[t.s, default: []].append(t)
        }
        var out: [(NSRange, Int)] = []
        var colourFor: [String: Int] = [:], next = 0
        for sk in order {
            let items = byStanza[sk]!
            var gis: [Int] = []
            for x in items where !gis.contains(x.gi) { gis.append(x.gi) }
            var parent: [Int: Int] = [:]
            for g in gis { parent[g] = g }
            func find(_ g0: Int) -> Int { var g = g0; while parent[g]! != g { parent[g] = parent[parent[g]!]!; g = parent[g]! }; return g }
            for i in 0..<gis.count { for j in (i + 1)..<max(i + 1, gis.count) where RhymeEngine.score(eng.keys[gis[i]], eng.keys[gis[j]]) >= 6 {
                let ra = find(gis[i]), rb = find(gis[j]); if ra != rb { parent[ra] = rb }
            } }
            var grp: [Int: [Tok]] = [:], gorder: [Int] = []
            for x in items { let rk = find(x.gi); if grp[rk] == nil { gorder.append(rk) }; grp[rk, default: []].append(x) }
            // JS walks these number keys in ascending order, which decides which colour each set gets
            _ = gorder
            for rk in grp.keys.sorted() {
                let g = grp[rk]!
                guard Set(g.map(\.w)).count >= 2 else { continue }
                let ck = "\(sk)|\(rk)"
                if colourFor[ck] == nil { colourFor[ck] = next % 8; next += 1 }
                for x in g { out.append((x.r, colourFor[ck]!)) }
            }
        }
        return out
    }
}
