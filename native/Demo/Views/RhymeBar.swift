import SwiftUI
import UIKit

/// The word modes (WMODES), in the web's order.
enum WordMode: String, CaseIterable, Identifiable {
    case rhy, per, near, phr, syn, rel, adj, ant, snd, def
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rhy: "Rhymes"; case .per: "Perfect"; case .near: "Near"; case .phr: "Phrases"; case .syn: "Synonyms"
        case .rel: "Related"; case .adj: "Describe"; case .ant: "Opposites"; case .snd: "Sounds like"; case .def: "Define"
        }
    }
    var isRhyme: Bool { self == .rhy || self == .per || self == .near }
    /// What the empty / busy messages call the list.
    var noun: String {
        switch self {
        case .rhy: "rhymes"; case .per: "perfect rhymes"; case .near: "near rhymes"; case .phr: "phrases"; case .syn: "synonyms"
        case .rel: "related words"; case .adj: "describing words"; case .ant: "opposites"; case .snd: "sound-alikes"; case .def: "definition"
        }
    }
}

struct WordChip: Identifiable, Hashable {
    let word: String
    let syl: Int
    var fits = false
    var nearStart = false   // the first near rhyme: the "near" label goes before it
    var id: String { word }
}

/// Works out the chips for a word and mode: built-in results straight away, Datamuse when it answers.
@MainActor @Observable
final class WordResults {
    var mode: WordMode = .rhy
    private(set) var word = ""
    private(set) var chips: [WordChip] = []
    private(set) var definitions: [(String, String)] = []
    private(set) var message: String?
    private(set) var busy = false
    /// Syllables the line still needs to match its partner (0 = none).
    var left = 0
    var register = "Conversational"
    var perfectOnly = true
    var big = false                // the Dictionary shows longer lists
    @ObservationIgnored private var dmSyl: [String: Int] = [:]
    @ObservationIgnored private var token = 0

    func show(_ w: String) {
        word = w
        refresh()
    }

    func refresh() {
        token += 1
        let t = token, w = word, mode = mode
        definitions = []
        guard !w.isEmpty else { chips = []; message = nil; busy = false; return }
        if mode.isRhyme {
            build(local: true)
            busy = false
            Task {
                if let r = await Datamuse.shared.rhymes(w) {
                    let s = await Datamuse.shared.syllables
                    remember(w, r)
                    guard t == token else { return }
                    dmSyl = s; build(local: false)
                }
            }
        } else if mode == .phr {
            chips = []; message = nil; busy = true
            Task {
                let r = await Datamuse.shared.rhymes(w)
                let s = await Datamuse.shared.syllables
                guard t == token else { return }
                busy = false; dmSyl = s
                guard let r else { message = "Phrases need a connection. Perfect and Near work offline."; return }
                let list = (r.perfect + r.near).filter { $0.contains(" ") }
                chips = list.prefix(big ? 80 : 40).map { WordChip(word: $0, syl: syl($0)) }
                message = chips.isEmpty ? "No phrases found for “\(w)”." : nil
            }
        } else if mode == .def {
            chips = []; message = nil; busy = true
            Task {
                let d = await Datamuse.shared.define(w)
                guard t == token else { return }
                busy = false
                if let d, !d.isEmpty { definitions = d } else { message = d == nil ? "Definitions need a connection." : "No definition found for “\(w)”." }
            }
        } else {
            chips = []; message = nil; busy = true
            Task {
                let l = await Datamuse.shared.list(mode.rawValue, w, topics: [])
                let s = await Datamuse.shared.syllables
                guard t == token else { return }
                busy = false; dmSyl = s
                guard let l else { message = "Meaning-based lists need a connection, and it isn’t reachable right now."; return }
                chips = RhymeEngine.shared.filter(l, register: register).prefix(big ? 80 : 60).map { WordChip(word: $0, syl: syl($0)) }
                message = chips.isEmpty ? "Nothing found for “\(w)”." : nil
            }
        }
    }

    private func syl(_ x: String) -> Int {
        if let n = dmSyl[x] { return n }
        return x.contains(" ") ? RhymeEngine.shared.lineSyllables(x) : RhymeEngine.shared.syllables(x)
    }

    /// Rhyme modes: Datamuse when it has answered for this word, otherwise the built-in dictionary.
    private func build(local: Bool) {
        let eng = RhymeEngine.shared
        var p: [String], n: [String]
        if !local, let s = dmCached { (p, n) = s } else { let s = eng.sets(word); p = s.perfect; n = s.near }
        p = eng.order(eng.filter(p, register: register), left: left, syl: syl)
        n = eng.order(eng.filter(n, register: register), left: left, syl: syl)
        let capP = big ? 60 : 40, capN = big ? (mode == .near ? 80 : 40) : (mode == .near ? 60 : 30)
        var out: [WordChip] = []
        switch mode {
        case .per: out = p.prefix(capP).map { chip($0) }
        case .near: out = n.prefix(capN).map { chip($0) }
        default:
            out = p.prefix(capP).map { chip($0) }
            if !perfectOnly || out.isEmpty {
                var near = n.prefix(capN).map { chip($0) }
                if !near.isEmpty && !out.isEmpty { near[0].nearStart = true }
                out += near
            }
        }
        chips = out
        message = out.isEmpty ? "No \(mode == .per ? "perfect " : mode == .near ? "near " : "")rhymes found for “\(word)”." : nil
    }

    @ObservationIgnored private var dmSnapshot: [String: ([String], [String])] = [:]
    private var dmCached: ([String], [String])? {
        // the Datamuse actor's cache is read asynchronously; keep the last answer for this word here
        dmSnapshot[RhymeEngine.normalise(word)]
    }

    private func chip(_ x: String) -> WordChip {
        let s = syl(x)
        return WordChip(word: x, syl: s, fits: left > 0 && s == left)
    }

    /// Called when Datamuse answers, so rhyme modes can use it without awaiting.
    func remember(_ w: String, _ r: (perfect: [String], near: [String])) { dmSnapshot[RhymeEngine.normalise(w)] = (r.perfect, r.near) }
}

// MARK: - the rhyme bar

struct RhymeBar: View {
    let bridge: EditorBridge
    let context: RhymeContext
    let results: WordResults
    var onOpenDictionary: () -> Void
    @State private var showFormat = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle().inset(by: -10))
                .onTapGesture { Haptics.tap(); onOpenDictionary() }
                .accessibilityLabel("Open dictionary").accessibilityAddTraits(.isButton)

            HStack(spacing: 8) {
                status.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button { Haptics.selection(); withAnimation(.snappy) { showFormat.toggle() } } label: {
                    Image(systemName: "textformat").frame(width: 34, height: 34)
                        .background(showFormat ? Color.primary.opacity(0.12) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Text formatting")
            }

            if showFormat { FormatRow(bridge: bridge).transition(.move(edge: .top).combined(with: .opacity)) }

            if !context.word.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(WordMode.allCases) { m in
                            Button { Haptics.selection(); results.mode = m; results.refresh() } label: {
                                Text(m.title).font(.subheadline.weight(results.mode == m ? .semibold : .regular))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(results.mode == m ? Color.primary.opacity(0.12) : .clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()
            }

            resultsRow
        }
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    @ViewBuilder private var status: some View {
        let eng = RhymeEngine.shared
        if !context.selection.isEmpty && context.selection.split(whereSeparator: { $0 == " " || $0 == "\n" }).count > 1 {
            Text(shortSel(context.selection)).bold() + Text(" · \(eng.lineSyllables(context.selection)) syl · ends “\(context.word)”").foregroundStyle(.secondary)
        } else if !context.word.isEmpty {
            let parts = ["\(eng.syllables(context.word)) syl", context.via, results.left > 0 ? "\(results.left) to match" : ""].filter { !$0.isEmpty }
            Text(context.word).font(.body.weight(.semibold)) + Text(" · " + parts.joined(separator: " · ")).foregroundStyle(.secondary)
        } else {
            Text("Tap any word for rhymes").foregroundStyle(.secondary)
        }
    }

    private func shortSel(_ s: String) -> String {
        let t = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if t.count <= 22 { return t }
        let cut = String(t.prefix(22))
        if let sp = cut.lastIndex(of: " ") { return String(cut[..<sp]) + "…" }
        return cut + "…"
    }

    @ViewBuilder private var resultsRow: some View {
        if context.word.isEmpty {
            if context.line.trimmingCharacters(in: .whitespaces).isEmpty && context.selection.isEmpty {
                chipsRow(sectionChips.map { ($0.0, nil, false, false) }) { label in bridge.insertSection(label) }
            }
        } else if context.selection.split(whereSeparator: { $0 == " " || $0 == "\n" }).count > 8 || context.selection.contains("\n") {
            Text("Select a word or short phrase to see rhymes.").font(.subheadline).foregroundStyle(.secondary)
        } else if results.mode == .def {
            if !results.definitions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(results.definitions.enumerated()), id: \.offset) { _, d in
                            (Text(d.0.isEmpty ? "" : d.0 + ". ").italic().foregroundStyle(.secondary) + Text(d.1)).font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 96)
            } else { messageRow }
        } else if !results.chips.isEmpty {
            chipsRow(results.chips.map { ($0.word, $0.syl, $0.fits, $0.nearStart) }) { w in bridge.insertWord(w, viaPartner: !context.via.isEmpty) }
        } else { messageRow }
    }

    @ViewBuilder private var messageRow: some View {
        HStack(spacing: 8) {
            if results.busy { ProgressView().controlSize(.small) }
            Text(results.busy ? "Finding \(results.mode.noun) for “\(context.word)”" : (results.message ?? ""))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(minHeight: 36)
    }

    /// On an empty line: section tags (the Chorus one brings the chorus's lines when there already is one).
    private var sectionChips: [(String, String)] {
        let hasChorus = bridge.chorusText() != nil
        return [("[Verse]", "[Verse]"), ("[Pre-Chorus]", "[Pre-Chorus]"), (hasChorus ? "[Chorus] + lyrics" : "[Chorus]", "[Chorus]"), ("[Bridge]", "[Bridge]"), ("[Outro]", "[Outro]")]
    }

    private func chipsRow(_ items: [(String, Int?, Bool, Bool)], tap: @escaping (String) -> Void) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        if it.3 {
                            Text("near").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.leading, 4)
                        }
                        Button { tap(it.0) } label: {
                            HStack(spacing: 5) {
                                Text(it.0).font(.system(size: 17, weight: .medium))
                                if let s = it.1 { Text("\(s)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 14).frame(height: 38)
                            .background(it.2 ? Theme.tint.opacity(0.16) : Color.primary.opacity(0.07), in: Capsule())
                            .overlay(Capsule().strokeBorder(it.2 ? Theme.tint.opacity(0.5) : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
            .onChange(of: context.word) { _, _ in proxy.scrollTo(0, anchor: .leading) }
        }
    }
}

/// The Aa row: bold, italic, underline, strikethrough, the colours, the highlights and clear.
struct FormatRow: View {
    let bridge: EditorBridge
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                fmt("bold") { bridge.toggle(.bold) }
                fmt("italic") { bridge.toggle(.italic) }
                fmt("underline") { bridge.toggle(.underline) }
                fmt("strikethrough") { bridge.toggle(.strike) }
                Divider().frame(height: 22).padding(.horizontal, 2)
                ForEach(RichText.textColors, id: \.0) { name, c in
                    Button { bridge.setColor(c) } label: { Circle().fill(Color(uiColor: c)).frame(width: 24, height: 24).padding(5) }
                        .buttonStyle(.plain).accessibilityLabel(name)
                }
                Divider().frame(height: 22).padding(.horizontal, 2)
                ForEach(RichText.highlights, id: \.0) { name, c in
                    Button { bridge.setHighlight(c) } label: {
                        Text(name).font(.subheadline.weight(.medium)).padding(.horizontal, 10).frame(height: 32)
                            .background(Color(uiColor: c), in: Capsule())
                    }.buttonStyle(.plain)
                }
                fmt("xmark") { bridge.clearFormatting() }.accessibilityLabel("Clear formatting")
            }
        }
        .scrollClipDisabled()
    }
    private func fmt(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 34) }
            .buttonStyle(.plain)
    }
}

// MARK: - Dictionary

struct DictionarySheet: View {
    let bridge: EditorBridge
    let initialWord: String
    let register: String
    let perfectOnly: Bool
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results = WordResults()
    @State private var insertAt: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(WordMode.allCases) { m in
                                Button { Haptics.selection(); results.mode = m; results.refresh() } label: {
                                    Text(m.title).font(.subheadline.weight(results.mode == m ? .semibold : .regular))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(results.mode == m ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 20)
                    }
                    Group {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("Search any word to see rhymes, synonyms, definitions and more.").foregroundStyle(.secondary)
                        } else if results.mode == .def && !results.definitions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(results.definitions.enumerated()), id: \.offset) { _, d in
                                    VStack(alignment: .leading, spacing: 2) {
                                        if !d.0.isEmpty { Text(d.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                                        Text(d.1)
                                    }
                                }
                            }
                        } else if !results.chips.isEmpty {
                            FlowLayout(spacing: 8) {
                                ForEach(results.chips) { c in
                                    if c.nearStart { Text("near").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(height: 38) }
                                    Button { insert(c.word) } label: {
                                        HStack(spacing: 5) {
                                            Text(c.word).font(.system(size: 17, weight: .medium))
                                            Text("\(c.syl)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 14).frame(height: 38)
                                        .background(Color.primary.opacity(0.07), in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                if results.busy { ProgressView().controlSize(.small) }
                                Text(results.busy ? "Looking up “\(query)”" : results.message ?? "").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search any word")
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .onSubmit(of: .search) { results.show(query.trimmingCharacters(in: .whitespaces)) }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(280))
                results.show(query.trimmingCharacters(in: .whitespaces))
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { Haptics.tap(); dismiss() } label: { Image(systemName: "checkmark") }.accessibilityLabel("Done")
                }
            }
        }
        .onAppear {
            results.big = true
            results.register = register
            results.perfectOnly = perfectOnly
            insertAt = bridge.caretLocation
            if !initialWord.isEmpty { query = initialWord; results.show(initialWord) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Inserts at the caret remembered when the Dictionary opened, and moves that point along (spec §2.8).
    private func insert(_ w: String) {
        guard let at = insertAt else { return }
        insertAt = bridge.insertPlain(w, at: at)
        session.toast = "Inserted “\(w)”"
    }
}

/// Wraps chips onto lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > w { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}
