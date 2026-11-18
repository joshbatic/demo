import Foundation

/// Ranks rhymes and word lists without the AI (the web's rankWords). Each word gets a score, lowest first:
/// - syllables: words with as many syllables as the word you're rhyming come first (one-syllable "light" → "night",
///   "bright" before "tonight"), 3 points for each syllable off. A word with exactly the syllables the line still
///   needs (`left`) counts as a match too.
/// - how common: 0.5 a step through the dictionary's ten tiers, so everyday words lead.
/// - this song: ties to the song's other words (the word library's synonyms and related words, both ways; the word
///   being rhymed doesn't count): -1.5 for one, -3.5 for two or more, so a less usual word that fits what the song is
///   about can jump ahead.
/// - +3 for a rhyme that's just the same word inside a longer one ("time" → "sometime"), +2 for a word already
///   ending another line of the song.
/// - rare words (the two rarest tiers) and abbreviations read letter by letter still go last.
nonisolated enum WordRank {
    private struct Song { var key = ""; var has = Set<String>(); var related: [String: Int] = [:]; var ends: [String: Int] = [:] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached = Song()

    private static func song(_ text: String, skip: String) -> Song {
        let lib = WordLibrary.shared
        let key = text + "\u{0}" + skip
        lock.lock(); defer { lock.unlock() }
        if cached.key == key { return cached }
        var n: [String: Int] = [:], ends: [String: Int] = [:]
        for l in text.split(separator: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("[") else { continue }
            let ws = t.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'") }).map { RhymeEngine.normalise(String($0)) }.filter { !$0.isEmpty }
            for w in ws where w.count > 2 && !RhymeEngine.stop.contains(w) && w != skip { n[w, default: 0] += 1 }
            if let e = ws.last { ends[e, default: 0] += 1 }
        }
        let words = n.keys.sorted { n[$0]! != n[$1]! ? n[$0]! > n[$1]! : $0 < $1 }.prefix(40)
        var r: [String: Int] = [:]
        if lib.loaded {
            for w in words { for x in lib.list("syn", w) + lib.list("rel", w) { r[RhymeEngine.normalise(x), default: 0] += 1 } }
        }
        let s = Song(key: lib.loaded ? key : "", has: Set(words), related: r, ends: ends)
        cached = s
        return s
    }

    static func rank(_ a: [String], word: String, left: Int, song text: String, line: String, syl: (String) -> Int) -> [String] {
        let eng = RhymeEngine.shared, lib = WordLibrary.shared
        let w = RhymeEngine.normalise(word)
        let sw = word.isEmpty ? 0 : (word.contains(" ") ? eng.lineSyllables(word) : eng.syllables(word))
        let c = song(text, skip: w)
        let lastWord = line.split(whereSeparator: { !($0.isLetter || $0 == "'") }).last.map { RhymeEngine.normalise(String($0)) } ?? ""
        let scored = a.enumerated().map { (i, x) -> (String, Double, Int) in
            let k = RhymeEngine.normalise(x), e = eng.words[k], s = syl(x)
            var v = 0.0
            if let e, e.tier >= 8 || (e.syl >= 2 && k.count <= e.syl) { v += 100 }
            if sw > 0 { v += (left > 0 && s == left) ? 0 : Double(min(9, abs(s - sw) * 3)) }
            v += Double(e?.tier ?? (x.contains(" ") ? 4 : 7)) * 0.5
            if lib.loaded {
                var tie = c.related[k] != nil ? 1 : 0
                for y in lib.list("syn", x) + lib.list("rel", x) where tie < 2 {
                    if c.has.contains(RhymeEngine.normalise(y)) { tie += 1 }
                }
                v -= tie >= 2 ? 3.5 : Double(tie) * 1.5
            }
            if !w.isEmpty, k != w, (k.count > w.count && k.hasSuffix(w)) || (w.count > k.count && w.hasSuffix(k)) { v += 3 }
            if c.ends[k] != nil, k != lastWord { v += 2 }
            return (x, v, i)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }.map(\.0)
    }
}
