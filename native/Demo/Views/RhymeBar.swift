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

/// The web's fill colour (--fill): the grey behind chips, tag buttons and the mode track.
enum BarFill {
    static let color = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 118/255, green: 118/255, blue: 128/255, alpha: 0.28) : UIColor(red: 118/255, green: 118/255, blue: 128/255, alpha: 0.12) })
}

/// A horizontal scroller that stays inside its container and fades its edges once there's more to see (the web's mask).
struct FadingHScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var fadeL = false
    @State private var fadeR = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { content }
            .onScrollGeometryChange(for: [Bool].self) { g in
                [g.contentOffset.x + g.contentInsets.leading > 1,
                 g.contentOffset.x + g.containerSize.width < g.contentSize.width - 1]
            } action: { _, v in
                withAnimation(.easeOut(duration: 0.15)) { fadeL = v[0]; fadeR = v[1] }
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: fadeL ? 22 : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: fadeR ? 22 : 0)
                }
            }
    }
}

struct RhymeBar: View {
    let bridge: EditorBridge
    let context: RhymeContext
    let results: WordResults
    var onOpenDictionary: () -> Void
    @AppStorage("view.fmt") private var showFormat = false
    @Namespace private var modeNS

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 34, height: 4)
                .frame(maxWidth: .infinity, minHeight: 18)
                .contentShape(Rectangle())
                .onTapGesture { Haptics.tap(); onOpenDictionary() }
                .padding(.top, -4).padding(.bottom, 4)
                .accessibilityLabel("Open dictionary").accessibilityAddTraits(.isButton)

            // status on the left, the tag buttons on the right
            HStack(spacing: 10) {
                status.lineLimit(1).truncationMode(.tail).padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { Haptics.selection(); withAnimation(.snappy(duration: 0.25)) { showFormat.toggle() } } label: {
                    Icon("ic-brush", 17)
                        .foregroundStyle(showFormat ? Theme.onTint : Theme.tint)
                        .frame(width: 32, height: 32)
                        .background(showFormat ? Theme.tint : BarFill.color, in: Circle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Text formatting").accessibilityAddTraits(showFormat ? .isSelected : [])
            }
            .padding(.bottom, 10)

            if showFormat {
                FormatRow(bridge: bridge, context: context)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }

            if !context.word.isEmpty && !tooLong {
                modeTrack.padding(.bottom, 8)
            }

            resultsRow
        }
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var tooLong: Bool {
        context.selection.split(whereSeparator: { $0 == " " || $0 == "\n" }).count > 8 || context.selection.contains("\n")
    }

    /// The word modes on a grey track, the chosen one on a raised glass pill (the web's #wm).
    private var modeTrack: some View {
        FadingHScroll {
            HStack(spacing: 2) {
                ForEach(WordMode.allCases) { m in
                    let on = results.mode == m
                    Button {
                        guard !on else { return }
                        Haptics.selection()
                        withAnimation(.snappy(duration: 0.28)) { results.mode = m }
                        results.refresh()
                    } label: {
                        Text(m.title)
                            .font(.system(size: 13, weight: on ? .semibold : .medium))
                            .foregroundStyle(Theme.tint)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background {
                                if on {
                                    Capsule()
                                        .fill(Color(uiColor: .tertiarySystemBackground))
                                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                                        .matchedGeometryEffect(id: "mode", in: modeNS)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2)
            .background(BarFill.color, in: Capsule())
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(Capsule())
    }

    @ViewBuilder private var status: some View {
        let eng = RhymeEngine.shared
        if !context.selection.isEmpty && context.selection.split(whereSeparator: { $0 == " " || $0 == "\n" }).count > 1 {
            (Text(shortSel(context.selection)).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.tint)
             + Text(" · \(eng.lineSyllables(context.selection)) syl · ends “\(context.word)”"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
        } else if !context.word.isEmpty {
            let parts = ["\(eng.syllables(context.word)) syl", context.via, results.left > 0 ? "\(results.left) to match" : ""].filter { !$0.isEmpty }
            (Text(context.word).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.tint)
             + Text(" · " + parts.joined(separator: " · ")))
                .font(.system(size: 14)).foregroundStyle(.secondary)
        } else {
            Text("Tap any word for rhymes").font(.system(size: 14)).foregroundStyle(.secondary)
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
            } else {
                Color.clear.frame(height: 0)
            }
        } else if tooLong {
            Text("Select a word or short phrase to see rhymes.").font(.subheadline).foregroundStyle(.secondary)
                .frame(minHeight: 38).padding(.leading, 8)
        } else if results.mode == .def {
            if !results.definitions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(results.definitions.enumerated()), id: \.offset) { _, d in
                            (Text(d.0.isEmpty ? "" : d.0 + ". ").italic().foregroundStyle(.secondary) + Text(d.1)).font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
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
        .padding(.leading, 8)
        .frame(minHeight: 38)
    }

    /// On an empty line: section tags (the Chorus one brings the chorus's lines when there already is one).
    private var sectionChips: [(String, String)] {
        let hasChorus = bridge.chorusText() != nil
        return [("[Verse]", "[Verse]"), ("[Pre-Chorus]", "[Pre-Chorus]"), (hasChorus ? "[Chorus] + lyrics" : "[Chorus]", "[Chorus]"), ("[Bridge]", "[Bridge]"), ("[Outro]", "[Outro]")]
    }

    private func chipsRow(_ items: [(String, Int?, Bool, Bool)], tap: @escaping (String) -> Void) -> some View {
        ScrollViewReader { proxy in
            FadingHScroll {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                        if it.3 {
                            Text("near").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
                        }
                        Button { tap(it.0) } label: {
                            HStack(spacing: 6) {
                                Text(it.0).font(.system(size: 17, weight: .medium))
                                if let s = it.1 {
                                    Text("\(s)").font(.system(size: 11)).opacity(it.2 ? 0.6 : 1)
                                        .foregroundStyle(it.2 ? AnyShapeStyle(Theme.onTint) : AnyShapeStyle(.secondary))
                                }
                            }
                            .foregroundStyle(it.2 ? Theme.onTint : Theme.tint)
                            .padding(.horizontal, 15).frame(height: 38)
                            .background(it.2 ? Theme.tint : BarFill.color, in: Capsule())
                        }
                        .buttonStyle(PressScale())
                        .id(i)
                    }
                }
            }
            .frame(height: 38)
            .onChange(of: context.word) { _, _ in proxy.scrollTo(0, anchor: .leading) }
        }
    }
}

/// The web's press: a quick shrink while held.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The Aa row: B / I / U / S, default colour plus the seven colours, the three highlights and clear (the web's #fmt).
struct FormatRow: View {
    let bridge: EditorBridge
    let context: RhymeContext   // changes as the caret moves, so the B / I / U / S states refresh
    @State private var tick = 0

    var body: some View {
        let _ = tick
        FadingHScroll {
            HStack(spacing: 6) {
                letter(Text("B").font(.system(size: 17, weight: .bold)), "Bold", .bold)
                letter(Text("I").font(.system(size: 18, design: .serif)).italic(), "Italic", .italic)
                letter(Text("U").font(.system(size: 17)).underline(), "Underline", .underline)
                letter(Text("S").font(.system(size: 17)).strikethrough(), "Strikethrough", .strike)
                sep
                Button { bridge.setColor(nil); tick += 1 } label: {
                    Circle()
                        .fill(LinearGradient(stops: [.init(color: Color(hex: 0x1C1C1E), location: 0.5), .init(color: .white, location: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                        .frame(width: 30, height: 30)
                        .padding(3).background(BarFill.color, in: Circle())
                }
                .buttonStyle(PressScale()).accessibilityLabel("Default colour")
                ForEach(RichText.textColors, id: \.0) { name, c in
                    Button { bridge.setColor(c); tick += 1 } label: {
                        Circle().fill(Color(uiColor: c))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                            .frame(width: 30, height: 30)
                            .padding(3).background(BarFill.color, in: Circle())
                    }
                    .buttonStyle(PressScale()).accessibilityLabel(name)
                }
                sep
                ForEach(RichText.highlights, id: \.0) { name, c in
                    Button { bridge.setHighlight(c); tick += 1 } label: {
                        Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.tint)
                            .padding(.horizontal, 15).frame(height: 38)
                            .background(Color(uiColor: c), in: Capsule())
                    }
                    .buttonStyle(PressScale()).accessibilityLabel("Mark as \(name)")
                }
                sep
                Button { bridge.clearFormatting(); tick += 1 } label: {
                    Icon("ic-close", 15).foregroundStyle(Theme.tint)
                        .frame(width: 38, height: 38).background(BarFill.color, in: Circle())
                }
                .buttonStyle(PressScale()).accessibilityLabel("Clear formatting")
            }
        }
        .frame(height: 38)
    }

    private var sep: some View {
        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    /// The web's B / I / U / S buttons are letters; they fill in when that style is on at the caret.
    private func letter(_ t: Text, _ label: String, _ trait: EditorBridge.Trait) -> some View {
        let on = bridge.isOn(trait)
        return Button { bridge.toggle(trait); tick += 1 } label: {
            t.foregroundStyle(on ? Theme.onTint : Theme.tint)
                .frame(width: 38, height: 38)
                .background(on ? Theme.tint : BarFill.color, in: Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
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
                    DoneButton { dismiss() }
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
