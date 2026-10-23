import SwiftUI
import UIKit

/// Clean up's rules (engines.md §3.1, `cleanLyrics`). Deterministic, no AI.
nonisolated enum CleanLyrics {
    static let tagRx = try! NSRegularExpression(pattern: #"^\s*[\[(]?\s*(intro|verse|pre[\s-]?chorus|chorus|post[\s-]?chorus|refrain|hook|bridge|break|interlude|instrumental|solo|tag|outro|coda|ad[\s-]?libs?)\s*(\d+)?\s*[\])]?\s*:?\s*$"#, options: .caseInsensitive)

    static func tagMatch(_ l: String) -> (String, String?)? {
        let ns = l as NSString
        guard let m = tagRx.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let num = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
        return (ns.substring(with: m.range(at: 1)), num)
    }

    static func tagName(_ name: String, _ num: String?) -> String {
        let n = name.lowercased().replacingOccurrences(of: #"[\s-]+"#, with: "-", options: .regularExpression)
        let map = ["pre-chorus": "Pre-Chorus", "post-chorus": "Post-Chorus", "ad-lib": "Ad-Libs", "ad-libs": "Ad-Libs"]
        let base = map[n] ?? (n.prefix(1).uppercased() + n.dropFirst())
        return "[" + base + (num.map { " " + $0 } ?? "") + "]"
    }

    static func lineCase(_ l: String) -> String? {
        let letters = l.filter { $0.isASCII && $0.isLetter }
        guard letters.count >= 2 else { return nil }
        if letters == letters.uppercased() { return "caps" }
        if letters == letters.lowercased() { return "lower" }
        return l.range(of: "^[^A-Za-z]*[A-Z]", options: .regularExpression) != nil ? "sentence" : "mixed"
    }

    static func detectCase(_ text: String) -> String {
        var n = ["caps": 0, "lower": 0, "sentence": 0, "mixed": 0]
        for l in text.components(separatedBy: "\n") {
            if l.trimmingCharacters(in: .whitespaces).isEmpty || tagMatch(l) != nil || l.range(of: #"^\s*\["#, options: .regularExpression) != nil { continue }
            if let c = lineCase(l) { n[c, default: 0] += 1 }
        }
        let tot = n.values.reduce(0, +)
        guard tot > 0 else { return "sentence" }
        if Double(n["caps"]!) / Double(tot) >= 0.5 { return "caps" }
        if Double(n["lower"]!) / Double(tot) >= 0.5 { return "lower" }
        return "sentence"
    }

    struct Options { var caseMode = "sentence"; var stream = false; var tags = true }

    static func clean(_ text: String, _ o: Options) -> String {
        enum Item { case blank, tag(String), line(String) }
        var out: [Item] = []
        let L = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: " ").components(separatedBy: "\n")
        for raw in L {
            var l = raw.replacingOccurrences(of: "[\u{00A0}\u{2000}-\u{200B}]", with: " ", options: .regularExpression)
                .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if let (name, num) = tagMatch(l) {
                if o.tags { out.append(.tag(tagName(name, num))) }
                continue
            }
            if l.hasPrefix("["), l.hasSuffix("]"), l.count >= 2 {
                if o.tags {
                    let inner = String(l.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    out.append(.tag("[" + inner.capitalizedWords + "]"))
                }
                continue
            }
            if l.isEmpty { out.append(.blank); continue }
            l = l.replacingOccurrences(of: "[‘’ʼ]", with: "'", options: .regularExpression)
                .replacingOccurrences(of: "[“”]", with: "\"", options: .regularExpression)
                .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"([,!?;:])(?=[A-Za-z])"#, with: "$1 ", options: .regularExpression)
            var rep = 1
            if let m = l.firstMatch(of: #/\s*[\(\[]?\s*[xX×]\s?(\d)\s*[\)\]]?\s*$/#), let n = Int(m.1), n > 1, n < 9 {
                rep = n
                l = String(l[..<m.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if o.caseMode == "caps" { l = l.uppercased() }
            else if o.caseMode == "lower" { l = l.lowercased() }
            else {
                if lineCase(l) == "caps" { l = l.lowercased() }
                l = l.replacingOccurrences(of: #"\bi(?=\b|'(m|ll|ve|d|s)\b)"#, with: "I", options: .regularExpression)
                if let m = l.firstMatch(of: #/^([^A-Za-z]*)([a-z])/#) {
                    l = String(m.1) + String(m.2).uppercased() + String(l[m.range.upperBound...])
                }
            }
            if o.stream {
                l = l.replacingOccurrences(of: #"[,.;:\-–—]+$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\.{2,}$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            }
            if o.stream && rep > 1 { for _ in 0..<rep { out.append(.line(l)) } }
            else { out.append(.line(l + (rep > 1 ? " (x\(rep))" : ""))) }
        }
        var res: [String] = []
        for x in out {
            switch x {
            case .blank:
                if let last = res.last, last != "", !last.hasPrefix("[") { res.append("") }
            case .tag(let t):
                if let last = res.last, last != "" { res.append("") }
                res.append(t)
            case .line(let s): res.append(s)
            }
        }
        while res.last == "" { res.removeLast() }
        return res.joined(separator: "\n")
    }

    /// "N lines will change": lines that differ by position (cuDiff).
    static func diff(_ a: String, _ b: String) -> Int {
        let A = a.components(separatedBy: "\n"), B = b.components(separatedBy: "\n")
        return (0..<max(A.count, B.count)).filter { ($0 < A.count ? A[$0] : "") != ($0 < B.count ? B[$0] : "") }.count
    }
}

nonisolated extension String {
    /// Upper-cases the first letter after every word boundary, like JS's `replace(/\b\w/g, …)`.
    var capitalizedWords: String {
        var out = "", prevWord = false
        for ch in self {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            out += isWord && !prevWord ? ch.uppercased() : String(ch)
            prevWord = isWord
        }
        return out
    }
}

/// Clean up (spec §2.5).
struct CleanupSheet: View {
    let songID: String
    var onApplied: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var caseMode = "sentence"
    @State private var stream = false
    @State private var tags = true
    @State private var ready = false

    var body: some View {
        let lyrics = library.song(songID)?.lyrics ?? ""
        let detected = CleanLyrics.detectCase(lyrics)
        let cleaned = CleanLyrics.clean(lyrics, .init(caseMode: caseMode, stream: stream, tags: tags))
        let changes = CleanLyrics.diff(lyrics, cleaned)
        NavigationStack {
            Form {
                if lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write some lyrics first, then clean them up.").foregroundStyle(.secondary)
                } else {
                    Section("Capitals (mostly " + (detected == "caps" ? "ALL CAPS" : detected == "lower" ? "lowercase" : "sentence case") + " now)") {
                        Picker("Capitals", selection: $caseMode) {
                            Text("Sentence case").tag("sentence"); Text("ALL CAPS").tag("caps"); Text("lowercase").tag("lower")
                        }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    }
                    Section {
                        Picker("Style", selection: $stream) { Text("Tidy").tag(false); Text("Streaming-ready").tag(true) }
                            .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    } header: { Text("Style") } footer: {
                        Text(stream ? "Capitals at line starts, no end punctuation, repeats written out, tidy spacing." : "Consistent capitals and section tags, “I” fixed, single spaces.")
                    }
                    Section("Section tags") {
                        Picker("Section tags", selection: $tags) { Text("Keep").tag(true); Text("Remove").tag(false) }
                            .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    }
                    Section(changes == 0 ? "Already clean" : "\(changes) \(changes == 1 ? "line" : "lines") will change") {
                        Text(cleaned).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    Section {
                        Button("Apply to Song") { apply(cleaned) }.disabled(changes == 0)
                        Button("Copy Cleaned Text") {
                            UIPasteboard.general.string = cleaned
                            Haptics.success(); session.toast = "Copied cleaned lyrics"
                        }
                    } footer: { Text("Removes colours, bold and highlights.") }
                }
            }
            .navigationTitle("Clean up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
        }
        // full height: a shorter, floating sheet re-sizes (and looks like it zooms) when the keyboard comes up
        .presentationDetents([.large])
        .onAppear { if !ready { caseMode = detected; ready = true } }
    }

    private func apply(_ cleaned: String) {
        guard var s = library.song(songID) else { return }
        s.snap("Before clean-up")
        s.setText(lyrics: cleaned, rich: "")
        onApplied()
        library.put(s)
        Haptics.success()
        session.toast = "Cleaned up. The original is saved in Versions."
        dismiss()
    }
}
