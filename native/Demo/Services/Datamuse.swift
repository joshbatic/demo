import Foundation

/// Online word lists from Datamuse (engines.md §1.11). The built-in dictionary answers instantly and
/// these upgrade the results when they arrive. Two failures in a row switch it off for the session.
actor Datamuse {
    static let shared = Datamuse()
    /// Datamuse asks for a key from 1 January 2027.
    static let key = ""

    private var rhymeCache: [String: (perfect: [String], near: [String])] = [:]
    private var listCache: [String: [String]] = [:]
    private(set) var syllables: [String: Int] = [:]
    private var failures = 0
    private(set) var off = false

    private nonisolated struct Item: Decodable { let word: String?; let numSyllables: Int?; let tags: [String]?; let defs: [String]? }

    private func fetch(_ query: String) async throws -> [Item] {
        var s = "https://api.datamuse.com/words?" + query
        if !Self.key.isEmpty { s += "&key=" + (Self.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") }
        guard let url = URL(string: s) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([Item].self, from: data)
    }

    private func failed() { failures += 1; if failures >= 2 { off = true } }

    func cachedRhymes(_ w: String) -> (perfect: [String], near: [String])? { rhymeCache[RhymeEngine.normalise(w)] }

    /// Perfect and near rhymes (single words first, then phrases), or nil when offline.
    func rhymes(_ word: String) async -> (perfect: [String], near: [String])? {
        let w = RhymeEngine.normalise(word)
        guard !w.isEmpty, !off else { return nil }
        if let c = rhymeCache[w] { return c }
        do {
            async let a = fetch("rel_rhy=\(w)&md=sf&max=250")
            async let b = fetch("rel_nry=\(w)&md=sf&max=150")
            let (pr, nr) = try await (a, b)
            failures = 0
            func freq(_ o: Item) -> Double {
                guard let t = o.tags?.first(where: { $0.hasPrefix("f:") }) else { return 0 }
                return Double(t.dropFirst(2)) ?? 0
            }
            func ok(_ o: Item) -> Bool {
                let x = (o.word ?? "").lowercased()
                guard x.range(of: "^[a-z' ]+$", options: .regularExpression) != nil, x != w else { return false }
                return x.contains(" ") || freq(o) >= 0.08
            }
            func take(_ a: [Item]) -> [String] {
                var one: [String] = [], many: [String] = []
                for o in a where ok(o) {
                    let x = (o.word ?? "").lowercased()
                    syllables[x] = o.numSyllables ?? RhymeEngine.shared.lineSyllables(x)
                    if x.contains(" ") { many.append(x) } else { one.append(x) }
                }
                return one + many
            }
            let p = take(pr)
            let seen = Set(p)
            let n = take(nr).filter { !seen.contains($0) }
            rhymeCache[w] = (p, n)
            return (p, n)
        } catch {
            failed()
            return nil
        }
    }

    /// Meaning lists: synonyms (ml), related (rel_trg), describe (rel_jjb), opposites (rel_ant), sounds like (sl).
    func list(_ mode: String, _ word: String, topics: [String]) async -> [String]? {
        let q: String
        switch mode {
        case "syn": q = "ml"
        case "rel": q = "rel_trg"
        case "adj": q = "rel_jjb"
        case "ant": q = "rel_ant"
        case "snd": q = "sl"
        default: return nil
        }
        let w = word.lowercased().trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !off else { return nil }
        let enc = w.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? w
        var query = "\(q)=\(enc)&md=sf&max=60"
        if !topics.isEmpty { query += "&topics=" + topics.prefix(5).joined(separator: ",") }
        if let c = listCache[query] { return c }
        do {
            let items = try await fetch(query)
            failures = 0
            let out = items.compactMap { o -> String? in
                let x = (o.word ?? "").lowercased()
                guard x.range(of: "^[a-z' -]+$", options: .regularExpression) != nil, x != w else { return nil }
                if let n = o.numSyllables { syllables[x] = n }
                return x
            }
            listCache[query] = out
            return out
        } catch { failed(); return nil }
    }

    /// Up to 6 definitions as (part of speech, text).
    func define(_ word: String) async -> [(String, String)]? {
        let w = RhymeEngine.normalise(word)
        guard !w.isEmpty, !off else { return nil }
        do {
            let items = try await fetch("sp=\(w)&md=d&max=1")
            failures = 0
            let defs = items.first?.defs ?? []
            return defs.prefix(6).map { d in
                let parts = d.split(separator: "\t", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : ("", d)
            }
        } catch { failed(); return nil }
    }
}
