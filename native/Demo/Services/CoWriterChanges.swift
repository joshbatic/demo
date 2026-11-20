import Foundation

/// What a co-writer changed in a shared song since you last had it open on this device.
/// Each device keeps the song's words as you last left them (SeenLyrics, the same `songpad:seen` the web uses).
/// Opening the song again compares against them: the changed words of each edited line (or a whole new line)
/// get a light tint and a cursor with the co-writer's photo, until you start typing, after a minute and a half,
/// or when you leave the song. Your own edits never count: leaving a song you were in saves its words as seen.
@MainActor
enum SeenLyrics {
    static let key = "songpad:seen"
    static func get(_ id: String) -> String? { (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id] }
    static func set(_ id: String, _ v: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d[id] = v
        UserDefaults.standard.set(d, forKey: key)
    }
}

nonisolated enum ChangeDiff {
    /// The changed parts of `new` (UTF-16 ranges), line by line against `old`: an edited line marks the words
    /// that differ, a new line is marked whole. Blank lines don't count. Same as the web's cwDiff.
    static func ranges(old: String, new: String) -> [NSRange] {
        let A = old.components(separatedBy: "\n"), B = new.components(separatedBy: "\n")
        let n = A.count, m = B.count
        guard n * m <= 400_000 else { return [] }
        let at = A.map { $0.trimmingCharacters(in: .whitespaces) }, bt = B.map { $0.trimmingCharacters(in: .whitespaces) }
        var L = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    L[i][j] = at[i] == bt[j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
                }
            }
        }
        var starts: [Int] = [], p = 0
        for b in B { starts.append(p); p += (b as NSString).length + 1 }
        var out: [NSRange] = [], del: [Int] = [], ins: [Int] = []
        func space(_ c: UInt16) -> Bool { c == 32 || c == 9 }
        // an edited line pairs with the removed line it shares the most of (start and end), so only its new words are marked
        func sim(_ a: [UInt16], _ b: [UInt16]) -> Int {
            var x = 0; while x < a.count && x < b.count && a[x] == b[x] { x += 1 }
            var y = 0; while y < a.count - x && y < b.count - x && a[a.count - 1 - y] == b[b.count - 1 - y] { y += 1 }
            return x + y
        }
        func flush() {
            var used = Set<Int>()
            for bj in ins where !bt[bj].isEmpty {
                let b = Array(B[bj].utf16)
                var s = 0, e = b.count
                var best = -1, bs = 3
                for di in del where !used.contains(di) {
                    let v = sim(Array(A[di].utf16), b)
                    if v > bs { bs = v; best = di }
                }
                if best >= 0 {
                    used.insert(best)
                    let a = Array(A[best].utf16)
                    while s < a.count && s < b.count && a[s] == b[s] { s += 1 }
                    var t = 0
                    while t < a.count - s && t < b.count - s && a[a.count - 1 - t] == b[b.count - 1 - t] { t += 1 }
                    e = b.count - t
                    while s > 0 && !space(b[s - 1]) { s -= 1 }
                    while e < b.count && !space(b[e]) { e += 1 }
                    if e < s { e = s }
                }
                out.append(NSRange(location: starts[bj] + s, length: e - s))
            }
            del = []; ins = []
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && at[i] == bt[j] { flush(); i += 1; j += 1 }
            else if j < m && (i >= n || L[i][j + 1] >= L[i + 1][j]) { ins.append(j); j += 1 }
            else { del.append(i); i += 1 }
        }
        flush()
        return out
    }

    /// How many lines the ranges touch.
    static func lineCount(_ ranges: [NSRange], in text: String) -> Int {
        let ns = text as NSString
        return Set(ranges.map { ns.lineRange(for: NSRange(location: min($0.location, ns.length), length: 0)).location }).count
    }
}

/// Who made the changes, for the cursor's photo and the pill.
struct ChangeAuthor: Equatable {
    var name: String
    var avatar: String?
    var id: String?
}
