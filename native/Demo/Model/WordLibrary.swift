import Foundation

/// The built-in word library (scripts/words/build.py): 146,000 words and phrases from WordNet with their synonyms,
/// related words, opposites and definitions, plus phrases that rhyme. It ships in the app (Words.txt) so the word
/// tools answer instantly and offline; Datamuse and the AI only fill in what it doesn't have. The web app reads the
/// same file (wlLoad in www/index.html).
///
/// Format: "#words-v1 W G", then W lines "word \t synonyms \t related \t opposites \t definitions" (single words a-z,
/// then phrases a-z, so lookups binary-search; the lists are base-36 line numbers, definitions are a part-of-speech
/// letter and a base-36 definition number), then the G definitions.
nonisolated final class WordLibrary: @unchecked Sendable {
    static let shared = WordLibrary()

    private var lines: [Substring] = []
    private var count = 0
    /// The first phrase's line (everything before it is a single word).
    private var firstPhrase = 0
    private var phraseIndex: [Int: [(phrase: String, worst: Int, words: Int, mean: Double)]]?
    private let lock = NSLock()
    private(set) var loaded = false

    private init() {}

    /// Reads Words.txt from the app bundle. Safe to call more than once; call it off the main thread.
    func load() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded, let url = Bundle.main.url(forResource: "Words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let l = text.split(separator: "\n", omittingEmptySubsequences: false)
        let head = l.first?.split(separator: " ") ?? []
        guard head.count == 3, head[0] == "#words-v1", let n = Int(head[1]), l.count > n else { return }
        lines = l; count = n
        // single words come first: find where the phrases start
        var lo = 0, hi = n
        while lo < hi {
            let m = (lo + hi) / 2
            if word(m).contains(" ") { hi = m } else { lo = m + 1 }
        }
        firstPhrase = lo
        loaded = true
    }

    private func word(_ i: Int) -> Substring {
        let l = lines[i + 1]
        return l[..<(l.firstIndex(of: "\t") ?? l.endIndex)]
    }

    private func field(_ i: Int, _ f: Int) -> Substring {
        let parts = lines[i + 1].split(separator: "\t", omittingEmptySubsequences: false)
        return f < parts.count ? parts[f] : ""
    }

    private func at(_ w: String) -> Int? {
        let phrase = w.contains(" ")
        var lo = phrase ? firstPhrase : 0, hi = phrase ? count : firstPhrase
        while lo < hi {
            let m = (lo + hi) / 2, x = word(m)
            if x == w { return m }
            if x < w { lo = m + 1 } else { hi = m }
        }
        return nil
    }

    /// The word's own entry first, then its base forms ("hearts" → heart, "dreaming" → dream, "cried" → cry).
    private func find(_ raw: String) -> [Int] {
        guard loaded else { return [] }
        let w = raw.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) || " '-".unicodeScalars.contains($0) }
            .map(String.init).joined().split(separator: " ").joined(separator: " ")
        guard !w.isEmpty else { return [] }
        var c = [w]
        func cut(_ n: Int) -> String { String(w.dropLast(n)) }
        if w.hasSuffix("ies") { c.append(cut(3) + "y") }
        if w.hasSuffix("s") { c.append(cut(1)) }
        if w.hasSuffix("es") { c.append(cut(2)) }
        if w.hasSuffix("ied") { c.append(cut(3) + "y") }
        if w.hasSuffix("ed") {
            c += [cut(2), cut(1)]
            let a = Array(w)
            if a.count > 4, a[a.count - 3] == a[a.count - 4] { c.append(cut(3)) }
        }
        if w.hasSuffix("ing") {
            c += [cut(3), cut(3) + "e"]
            let a = Array(w)
            if a.count > 5, a[a.count - 4] == a[a.count - 5] { c.append(cut(4)) }
        }
        if w.hasSuffix("in") { c.append(w + "g") }
        for s in ["er", "est"] where w.hasSuffix(s) {
            let b = String(w.dropLast(s.count))
            c += [b, b + "e"]
            if b.hasSuffix("i") { c.append(String(b.dropLast()) + "y") }
        }
        var out: [Int] = []
        for x in c { if let i = at(x), !out.contains(i) { out.append(i) } }
        return out
    }

    /// Synonyms ("syn"), related words ("rel") or opposites ("ant"). An inflected word ("hearts") leads with its
    /// base form's words, since that's almost always the sense a lyric means.
    func list(_ mode: String, _ w: String) -> [String] {
        guard let f = ["syn": 1, "rel": 2, "ant": 3][mode] else { return [] }
        var ix = find(w)
        guard !ix.isEmpty else { return [] }
        if ix.count > 1 { ix = Array(ix.dropFirst()) + [ix[0]] }
        var seen = Set(ix.map { String(word($0)) })
        seen.insert(RhymeEngine.normalise(w))
        var out: [String] = []
        for i in ix {
            for x in field(i, f).split(separator: ",") {
                guard let n = Int(x, radix: 36), n < count else { continue }
                let y = String(word(n))
                if seen.insert(y).inserted { out.append(y) }
            }
        }
        return out
    }

    /// Up to 6 definitions as (part of speech, text): n, v, adj or adv, like Datamuse's.
    func definitions(_ w: String) -> [(String, String)] {
        let pos: [Character: String] = ["n": "n", "v": "v", "a": "adj", "r": "adv"]
        var out: [(String, String)] = [], seen = Set<String>()
        for i in find(w) {
            for d in field(i, 4).split(separator: ",") {
                guard let p = d.first, let n = Int(d.dropFirst(), radix: 36), count + 1 + n < lines.count else { continue }
                let t = String(lines[count + 1 + n])
                if !t.isEmpty, seen.insert(t).inserted { out.append((pos[p] ?? "", t)) }
            }
        }
        return Array(out.prefix(6))
    }

    /// Phrases whose last word rhymes: the word's own rhyme group first, then the near groups, everyday phrases first.
    func phrases(rhymingWith w: String) -> [String] {
        let eng = RhymeEngine.shared
        guard loaded, eng.loaded else { return [] }
        lock.lock()
        if phraseIndex == nil {
            var idx: [Int: [(phrase: String, worst: Int, words: Int, mean: Double)]] = [:]
            for i in firstPhrase..<count {
                let p = String(word(i))
                guard !p.contains("-"), !p.contains("'") else { continue }
                let ws = p.split(separator: " ")
                guard ws.count <= 4, let last = ws.last, let e = eng.words[RhymeEngine.normalise(String(last))] else { continue }
                let tiers = ws.map { eng.words[RhymeEngine.normalise(String($0))]?.tier ?? 10 }
                let worst = tiers.max() ?? 10
                guard worst <= 9 else { continue }
                idx[e.group, default: []].append((p, worst, ws.count, Double(tiers.reduce(0, +)) / Double(ws.count)))
            }
            // rarest word first, then shorter, then the more everyday overall ("on fire" before "call fire")
            for k in idx.keys {
                idx[k]?.sort { $0.worst != $1.worst ? $0.worst < $1.worst : ($0.words != $1.words ? $0.words < $1.words : $0.mean < $1.mean) }
            }
            phraseIndex = idx
        }
        let index = phraseIndex ?? [:]
        lock.unlock()
        let s = eng.sets(w)
        guard let gi = s.group else { return [] }
        let me = RhymeEngine.normalise(w)
        var out: [String] = [], seen = Set<String>()
        func take(_ g: Int) {
            for x in index[g] ?? [] where RhymeEngine.normalise(x.phrase) != me && seen.insert(x.phrase).inserted { out.append(x.phrase) }
        }
        take(gi)
        var near = Set<Int>()
        for x in s.near {
            guard out.count < 200, let g = eng.words[x]?.group, near.insert(g).inserted else { continue }
            take(g)
        }
        return out
    }
}
