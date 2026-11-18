import Foundation

/// Co-writing offline (data spec §3.5a): a three-way merge instead of "newest copy wins".
///
/// Each shared song remembers (device-only keys) the shared copy as it last stood here: `_srv` is that copy's
/// `updated` and `_base` its words and details. If the shared copy has moved on since and this device has changes
/// of its own (written offline, say), the two are merged against `_base`: each field someone changed keeps their
/// change; lyrics, chords and notes merge line by line. Where both changed the same lines differently, the longer
/// one is kept if it contains the other, otherwise both (yours first), and your words from before the merge go
/// into Versions. Same rules as the web app's shMergeInto.
nonisolated enum SharedMerge {
    static let skip: Set<String> = ["updated", "lastEditBy", "lastEditAt", "owner", "ownerEmail", "members", "shared",
                                    "versions", "audio", "files", "rmFiles", "rich"]
    static let lineFields: Set<String> = ["lyrics", "chords", "notes"]

    static func base(_ d: [String: JSONValue]) -> JSONValue {
        .object(d.filter { !$0.key.hasPrefix("_") && !skip.contains($0.key) })
    }

    /// Records the shared copy as it stands now.
    static func keep(_ raw: inout [String: JSONValue], _ d: [String: JSONValue]) {
        raw["_srv"] = .number(d["updated"]?.number ?? 0)
        raw["_base"] = base(d)
    }

    static func str(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .null: return ""
        case .string(let s): return s
        default: return CanonicalJSON.string(v)
        }
    }

    /// For each line of a, the index of its matching line in b (or -1): longest common subsequence.
    static func lcs(_ a: [String], _ b: [String]) -> [Int] {
        let n = a.count, m = b.count
        var p = 0; while p < n && p < m && a[p] == b[p] { p += 1 }
        var q = 0; while q < n - p && q < m - p && a[n - 1 - q] == b[m - 1 - q] { q += 1 }
        var map = [Int](repeating: -1, count: n)
        for i in 0..<p { map[i] = i }
        for i in 0..<q { map[n - q + i] = m - q + i }
        let N = n - p - q, M = m - p - q
        if N == 0 || M == 0 || N * M > 4_000_000 { return map }
        let A = Array(a[p..<(n - q)]), B = Array(b[p..<(m - q)])
        let W = M + 1
        var L = [Int32](repeating: 0, count: (N + 1) * W)
        for i in stride(from: N - 1, through: 0, by: -1) {
            for j in stride(from: M - 1, through: 0, by: -1) {
                L[i * W + j] = A[i] == B[j] ? L[(i + 1) * W + j + 1] + 1 : max(L[(i + 1) * W + j], L[i * W + j + 1])
            }
        }
        var i = 0, j = 0
        while i < N && j < M {
            if A[i] == B[j] { map[p + i] = p + j; i += 1; j += 1 }
            else if L[(i + 1) * W + j] >= L[i * W + j + 1] { i += 1 } else { j += 1 }
        }
        return map
    }

    /// diff3 on lines: the merged text, and whether both sides changed the same lines.
    static func merge3(_ o: String, _ a: String, _ b: String) -> (text: String, clash: Bool) {
        if a == b { return (a, false) }
        if a == o { return (b, false) }
        if b == o { return (a, false) }
        let O = o.components(separatedBy: "\n"), A = a.components(separatedBy: "\n"), B = b.components(separatedBy: "\n")
        let ma = lcs(O, A), mb = lcs(O, B)
        var out: [String] = [], i = 0, j = 0, k = 0, clash = false
        func chunk(_ i2: Int, _ j2: Int, _ k2: Int) {
            let o2 = Array(O[i..<i2]), a2 = Array(A[j..<j2]), b2 = Array(B[k..<k2])
            if a2 == b2 || b2 == o2 { out += a2 }
            else if a2 == o2 { out += b2 }
            else {
                clash = true
                let s1 = a2.joined(separator: "\n"), s2 = b2.joined(separator: "\n")
                if !s1.trimmingCharacters(in: .whitespaces).isEmpty && s2.contains(s1) { out += b2 }
                else if !s2.trimmingCharacters(in: .whitespaces).isEmpty && s1.contains(s2) { out += a2 }
                else { out += a2; for l in b2 where l.trimmingCharacters(in: .whitespaces).isEmpty || !a2.contains(l) { out.append(l) } }
            }
        }
        for x in 0..<O.count {
            guard ma[x] >= 0, mb[x] >= 0, ma[x] >= j, mb[x] >= k else { continue }
            chunk(x, ma[x], mb[x]); out.append(O[x])
            i = x + 1; j = ma[x] + 1; k = mb[x] + 1
        }
        chunk(O.count, A.count, B.count)
        return (out.joined(separator: "\n"), clash)
    }

    /// Merges the shared copy `d` into `s` (which has changes of its own). True if anything of theirs came in.
    @MainActor @discardableResult
    static func mergeInto(_ s: inout Song, _ d: [String: JSONValue]) -> Bool {
        let o = s.raw["_base"]?.object ?? [:]
        let mine = s.raw
        let newer = (d["updated"]?.number ?? 0) > s.updated
        var took = false, clash = false
        let keys = Set(d.keys).union(s.raw.keys).filter { !$0.hasPrefix("_") && !skip.contains($0) }
        for k in keys {
            let ov = str(o[k]), mv = str(s.raw[k]), tv = str(d[k])
            if tv == mv || tv == ov { continue }
            if mv == ov {
                if let v = d[k] { s.raw[k] = v } else { s.raw.removeValue(forKey: k) }
                took = true; continue
            }
            let mineIsText = s.raw[k] == nil || s.raw[k] == .null || s.raw[k]?.isString == true
            let theirsIsText = d[k] == nil || d[k] == .null || d[k]?.isString == true
            if lineFields.contains(k) && mineIsText && theirsIsText {
                let r = merge3(ov, mv, tv)
                if r.clash { clash = true }
                if r.text != mv { s.raw[k] = .string(r.text); took = true }
                continue
            }
            if newer { s.raw[k] = d[k] ?? .null; took = true }
        }
        // the formatted words follow the words: whichever side's text won keeps its formatting, a mix starts plain
        let myLyrics = str(mine["lyrics"]), nowLyrics = str(s.raw["lyrics"]), theirLyrics = str(d["lyrics"])
        if nowLyrics != myLyrics {
            s.raw["rich"] = .string(nowLyrics == theirLyrics ? str(d["rich"]) : "")
        } else if newer, nowLyrics == theirLyrics, let r = d["rich"], r != s.raw["rich"] {
            s.raw["rich"] = r; took = true
        }
        // versions: everyone's, by time
        var vs: [String: JSONValue] = [:]
        for v in (mine["versions"]?.array ?? []) + (d["versions"]?.array ?? []) {
            guard let t = v["t"]?.number else { continue }
            vs["\(Int64(t))|\(str(v["lyrics"]).utf16.count)"] = v
        }
        var vl = vs.values.sorted { ($0["t"]?.number ?? 0) < ($1["t"]?.number ?? 0) }
        if clash && myLyrics != nowLyrics {
            vl.append(.object(["t": .number(Clock.nowMs), "lyrics": .string(myLyrics), "rich": mine["rich"] ?? .string(""),
                               "label": .string("Your words before merging")]))
        }
        if !vl.isEmpty { s.raw["versions"] = .array(Array(vl.suffix(30))) }
        Collab.fileMerge(&s, rm: d["rmFiles"]?.object ?? [:], audio: d["audio"]?.array ?? [], files: d["files"]?.array ?? [])
        if took, let by = d["lastEditBy"] { s.raw["lastEditBy"] = by }
        return took
    }
}

extension JSONValue {
    nonisolated var isString: Bool { if case .string = self { return true }; return false }
}
