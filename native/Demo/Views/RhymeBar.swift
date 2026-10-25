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

    // the AI on top (engines.md §2.7): ranking for the song, and fallbacks when Datamuse can't answer
    struct AIContext { var pro: Bool; var ctxOn: Bool; var env: PromptEnv? }
    @ObservationIgnored var ai: (() -> AIContext)?
    /// The caret's line, for ranking and meaning lookups.
    var line = ""
    /// A multi-word selection: Phrases rhymes it with the AI (Pro).
    var phrase = ""
    private(set) var ranking = false
    private(set) var ranked = false
    @ObservationIgnored private var rankCache: [String: [String]] = [:]
    @ObservationIgnored private var aiCache: [String: [String]] = [:]
    @ObservationIgnored private var defCache: [String: [(String, String)]] = [:]

    func show(_ w: String) {
        word = w
        refresh()
    }

    func refresh() {
        token += 1
        let t = token, w = word, mode = mode
        definitions = []
        ranked = false; ranking = false
        guard !w.isEmpty else { chips = []; message = nil; busy = false; return }
        if mode.isRhyme {
            build(local: true)
            busy = false
            rank(t)
            Task {
                if let r = await Datamuse.shared.rhymes(w) {
                    let s = await Datamuse.shared.syllables
                    remember(w, r)
                    guard t == token else { return }
                    dmSyl = s; build(local: false)
                    rank(t)
                }
            }
        } else if mode == .phr, !phrase.isEmpty, let a = ai?(), a.pro, let env = a.env {
            chips = []; message = nil; busy = true
            let sel = phrase
            Task {
                let list = await aiPhrases(sel, env: env)
                guard t == token else { return }
                busy = false
                chips = list.map { WordChip(word: $0, syl: syl($0)) }
                message = chips.isEmpty ? "No phrases found for “\(sel)”." : nil
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
                var d = await Datamuse.shared.define(w)
                if d == nil || d?.isEmpty == true, let a = ai?(), a.pro, let env = a.env {
                    let x = await aiDefine(w, env: env)
                    if !x.isEmpty { d = x }
                }
                guard t == token else { return }
                busy = false
                if let d, !d.isEmpty { definitions = d } else { message = d == nil ? "Definitions need a connection." : "No definition found for “\(w)”." }
            }
        } else {
            chips = []; message = nil; busy = true
            Task {
                var l = await Datamuse.shared.list(mode.rawValue, w, topics: [])
                if l == nil, let a = ai?(), a.pro, let env = a.env { let x = await aiList(mode, w, env: env, ctxOn: a.ctxOn); if !x.isEmpty { l = x } }
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

    // MARK: AI

    /// Re-ranks the rhymes for this song (Pro, "Listen to the whole song" on, ≥ 4 chips).
    private func rank(_ t: Int) {
        guard let a = ai?(), a.pro, a.ctxOn, let env = a.env, chips.count >= 4 else { return }
        let list = chips.map(\.word)
        let key = RhymeEngine.normalise(word) + "|" + RhymeEngine.normalise(line) + Prompts.pfk(env)
        if let r = rankCache[key] { apply(r); ranked = true; return }
        ranking = true
        let w = word, ln = line
        var p = "Songwriting helper." + Prompts.pfx(env) + "\n\n" + Prompts.songCtx(env, at: nil, section: [])
        p += "\n\nThe writer wants a word that rhymes with \"" + w + "\" for the line: \"" + ln + "\". From the candidates below, choose the 30 that best fit this song's meaning, imagery and voice, best first. Use only words from the list, exactly as written.\nCandidates: " + list.joined(separator: ", ")
        p += "\n\nReturn ONLY a JSON array of strings."
        let prompt = p
        Task {
            let r = (try? await AIService.shared.json(prompt, ask: false))?.stringList.map { $0.lowercased() } ?? []
            let ok = Set(list)
            let picked = r.filter { ok.contains($0) }
            rankCache[key] = picked
            guard t == token else { return }
            ranking = false
            if !picked.isEmpty { apply(picked); ranked = true }
        }
    }

    private func apply(_ order: [String]) {
        var byWord: [String: WordChip] = [:]
        for c in chips { byWord[c.word] = c }
        var out: [WordChip] = order.compactMap { byWord.removeValue(forKey: $0) }
        out += chips.filter { byWord[$0.word] != nil }
        chips = out.map { var c = $0; c.nearStart = false; return c }
    }

    static let aiQ: [WordMode: String] = [
        .phr: "short phrases (2 to 4 words) whose final word rhymes with it, to end a lyric line",
        .syn: "synonyms and words with a similar meaning that could replace it in the line",
        .rel: "words strongly associated with it (images, objects, places, feelings) to spark the next line",
        .adj: "vivid adjectives that could describe it", .ant: "opposites and contrasting words",
        .snd: "words that sound similar through assonance or consonance but are not exact rhymes"
    ]

    private func aiList(_ m: WordMode, _ w: String, env: PromptEnv, ctxOn: Bool) async -> [String] {
        guard let what = Self.aiQ[m] else { return [] }
        let k = m.rawValue + "|" + w + (ctxOn ? "|c" : "")
        if let c = aiCache[k] { return c }
        var p = "Songwriting helper." + Prompts.pfx(env) + "\n\nWord: \"" + w + "\"\nLyric line it appears in: \"" + line + "\""
        if ctxOn { p += "\n\n" + Prompts.songCtx(env, at: nil, section: []) + "\nPick words that suit this song." }
        p += "\n\nList 24 " + what + ". Fit the voice above. Lowercase, no duplicates, no explanations. Return ONLY a JSON array of strings."
        let r = (try? await AIService.shared.json(p))?.stringList.map { $0.lowercased() }.filter { $0 != RhymeEngine.normalise(w) } ?? []
        aiCache[k] = r
        return r
    }

    private func aiDefine(_ w: String, env: PromptEnv) async -> [(String, String)] {
        if let c = defCache[w] { return c }
        let p = "You are a dictionary." + Prompts.pfx(env) + "\n\nDefine the word \"" + w + "\" as it is normally used, ordinary dictionary style. Give up to 3 concise senses, each under 18 words, no song-specific invention and no example sentences. Return ONLY a JSON array of objects like {\"pos\":\"noun\",\"text\":\"...\"}; pos may be empty if unsure."
        let r = (try? await AIService.shared.json(p))?.array ?? []
        let out = r.compactMap { x -> (String, String)? in
            guard let t = x["text"]?.string?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return ((x["pos"]?.string ?? "").trimmingCharacters(in: .whitespaces), t)
        }.prefix(6)
        defCache[w] = Array(out)
        return Array(out)
    }

    private func aiPhrases(_ sel: String, env: PromptEnv) async -> [String] {
        let n = RhymeEngine.shared.lineSyllables(sel), endw = RhymeContext.lastWord(sel)
        let k = "PHR#" + RhymeEngine.normalise(sel) + "#\(n)" + Prompts.pfk(env)
        if let c = aiCache[k] { return c }
        var p = "Songwriting helper." + Prompts.pfx(env) + "\n\n" + Prompts.songCtx(env, at: nil, section: [])
        p += "\n\nThe writer selected this phrase from the line: \"" + sel + "\" (\(n) syllables, ending in a word that rhymes with \"" + endw + "\"). Suggest 16 short alternative phrases of about the same length (\(n) syllables, give or take one) that end in a word rhyming with \"" + endw + "\" — match the ending sound closely, syllable by syllable — and fit the song's voice and context above, so swapping the phrase in keeps the line's rhythm and meaning going in the same direction. Avoid using the exact same end word on more than two or three of the sixteen — spread them across different words that share that rhyme, mixing perfect rhymes with slant/near rhymes (same vowel sound or final consonant, not identical) so the options feel varied, not repetitive. Return ONLY a JSON array of strings, each a short phrase, no explanations or numbering."
        let r = (try? await AIService.shared.json(p))?.stringList.filter { RhymeEngine.normalise($0) != RhymeEngine.normalise(sel) } ?? []
        aiCache[k] = r
        return r
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
    var voiceTouched = false
    var onVoice: () -> Void = {}
    // the AI pieces (spec §4.5): Muse, Listen to the whole song, Lines
    var isPro = false
    var onMuse: () -> Void = {}
    var ctxOn = false
    var onToggleCtx: () -> Void = {}
    var linesOn = false
    var onToggleLines: () -> Void = {}
    var lines: LinesModel?
    var env: () -> PromptEnv? = { nil }
    var scheme = "auto"
    var onScheme: (String) -> Void = { _ in }
    var onCleanup: () -> Void = {}
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
                (linesOn ? AnyView(linesStatus) : AnyView(status)).lineLimit(1).truncationMode(.tail).padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                HStack(spacing: 6) { tagButtons }
                    .fixedSize()
            }
            .padding(.bottom, 10)

            if showFormat {
                FormatRow(bridge: bridge, context: context, onCleanup: onCleanup)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }

            if linesOn, let lines {
                LinesPanel(bridge: bridge, context: context, model: lines, env: env, onScheme: onScheme, savedScheme: scheme)
            } else if !showFormat {
                // with the formatting row open the rhymes step aside, to keep the bar short
                Group {
                    if !context.word.isEmpty && !tooLong {
                        modeTrack.padding(.bottom, 8)
                    }
                    resultsRow
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
        }
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    @ViewBuilder private var tagButtons: some View {
        Button { Haptics.tap(); onMuse() } label: {
            Icon("ic-muse", 18)
                .foregroundStyle(Theme.tint)
                .frame(width: 32, height: 32)
                .background(BarFill.color, in: Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Muse")
        Button { Haptics.selection(); withAnimation(.snappy(duration: 0.25)) { showFormat.toggle() } } label: {
                    Icon("ic-brush", 17)
                        .foregroundStyle(showFormat ? Theme.onTint : Theme.tint)
                        .frame(width: 32, height: 32)
                        .background(showFormat ? Theme.tint : BarFill.color, in: Circle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Text formatting").accessibilityAddTraits(showFormat ? .isSelected : [])

                Button { Haptics.selection(); onToggleCtx() } label: {
                    Icon("ic-listen", 17)
                        .foregroundStyle(ctxOn ? Theme.onTint : Theme.tint)
                        .frame(width: 32, height: 32)
                        .background(ctxOn ? Theme.tint : BarFill.color, in: Circle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Listen to the whole song").accessibilityAddTraits(ctxOn ? .isSelected : [])

                // Writing voice, with a dot when it's been changed from the defaults
                Button { Haptics.tap(); onVoice() } label: {
                    Icon("ic-voice", 16)
                        .foregroundStyle(Theme.tint)
                        .frame(width: 32, height: 32)
                        .background(BarFill.color, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if voiceTouched {
                                Circle().fill(Theme.tint).frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                                    .offset(x: -2, y: 2)
                            }
                        }
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Writing voice")

                Button { Haptics.selection(); onToggleLines() } label: {
                    HStack(spacing: 5) {
                        Text("Lines").font(.system(size: 14, weight: .semibold))
                        if !isPro {
                            Text("Pro").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.proGreen, in: Capsule()).foregroundStyle(.white)
                        }
                    }
                    .foregroundStyle(linesOn ? Theme.onTint : Theme.tint)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(linesOn ? Theme.tint : BarFill.color, in: Capsule())
                }
                .buttonStyle(PressScale())
                .accessibilityAddTraits(linesOn ? .isSelected : [])
    }

    /// Lines mode's status: "Line 3 · rhymes with line 1 · 8 syl", or about the selection.
    private var linesStatus: some View {
        let eng = RhymeEngine.shared
        let sel = context.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if !sel.isEmpty {
            let n = sel.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            text = (n > 1 ? "\(n) lines" : "Selection") + " · \(eng.lineSyllables(sel)) syl · ends “\(RhymeContext.lastWord(sel))”"
        } else {
            let p = context.stanza.count + 1
            text = "Line \(p) · " + (context.partner.isEmpty ? "new rhyme" : "rhymes with line \(context.partnerIndex + 1)") + " · \(eng.lineSyllables(context.line)) syl"
        }
        return Text(text).font(.system(size: 14)).foregroundStyle(.secondary)
    }

    private var tooLong: Bool {
        context.selection.split(whereSeparator: { $0 == " " || $0 == "\n" }).count > 8 || context.selection.contains("\n")
    }

    /// The word modes on a grey track, the chosen one on a raised glass pill (the web's #wm).
    private var modeTrack: some View {
        ScrollViewReader { proxy in
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
                    .id(m)
                }
            }
            .padding(2)
            .background(BarFill.color, in: Capsule())
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(Capsule())
        // the chosen mode slides to the middle (or as far as it goes at either end), so it's always fully in view
        .onChange(of: results.mode, initial: true) { _, m in
            withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(m, anchor: .center) }
        }
        }
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
             + Text(" · " + parts.joined(separator: " · ") + (results.ranking ? " · … ranking for this song" : results.ranked ? " · ranked for this song" : "")))
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
                                Text(it.0).font(.system(size: 15.5, weight: .medium))
                                if let s = it.1 {
                                    Text("\(s)").font(.system(size: 10.5)).opacity(it.2 ? 0.6 : 1)
                                        .foregroundStyle(it.2 ? AnyShapeStyle(Theme.onTint) : AnyShapeStyle(.secondary))
                                }
                            }
                            .foregroundStyle(it.2 ? Theme.onTint : Theme.tint)
                            .padding(.horizontal, 13).frame(height: 34)
                            .background(it.2 ? Theme.tint : BarFill.color, in: Capsule())
                        }
                        .buttonStyle(PressScale())
                        .id(i)
                    }
                }
            }
            .frame(height: 34)
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
    var onCleanup: () -> Void = {}
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
                let active = bridge.activeColor
                Button { bridge.setColor(nil); tick += 1 } label: {
                    Circle()
                        .fill(LinearGradient(stops: [.init(color: Color(hex: 0x1C1C1E), location: 0.5), .init(color: .white, location: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                        .frame(width: 30, height: 30)
                        .padding(3).background(BarFill.color, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.tint, lineWidth: active == nil ? 2 : 0))
                }
                .accessibilityAddTraits(active == nil ? .isSelected : [])
                .buttonStyle(PressScale()).accessibilityLabel("Default colour")
                ForEach(RichText.textColors, id: \.0) { name, c in
                    Button { bridge.setColor(c); tick += 1 } label: {
                        Circle().fill(Color(uiColor: c))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                            .frame(width: 30, height: 30)
                            .padding(3).background(BarFill.color, in: Circle())
                            // the colour in use where the cursor is gets a ring
                            .overlay(Circle().strokeBorder(Theme.tint, lineWidth: active == c ? 2 : 0))
                    }
                    .buttonStyle(PressScale()).accessibilityLabel(name)
                    .accessibilityAddTraits(active == c ? .isSelected : [])
                }
                sep
                let hl = bridge.activeHighlight
                ForEach(RichText.highlights, id: \.0) { name, c in
                    Button { bridge.setHighlight(hl == c ? nil : c); tick += 1 } label: {
                        Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.tint)
                            .padding(.horizontal, 15).frame(height: 38)
                            .background(Color(uiColor: c), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.tint, lineWidth: hl == c ? 2 : 0))
                    }
                    .accessibilityAddTraits(hl == c ? .isSelected : [])
                    .buttonStyle(PressScale()).accessibilityLabel("Mark as \(name)")
                }
                sep
                Button { Haptics.tap(); onCleanup() } label: {
                    HStack(spacing: 6) {
                        Icon("ic-clean", 16)
                        Text("Clean up").font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.tint)
                    .padding(.horizontal, 13).frame(height: 38)
                    .background(BarFill.color, in: Capsule())
                }
                .buttonStyle(PressScale()).accessibilityLabel("Clean up lyrics")
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
    /// where the song's top bar ends: the sheet stops just under it
    var belowY: CGFloat = 0
    @Environment(\.appSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results = WordResults()
    @State private var insertAt: Int?
    /// the word last looked up, so opening (and the typing debounce) never looks the same word up twice
    @State private var lastShown = ""
    /// what's on screen: kept while a new list loads and swapped in with a soft fade, never flashed empty
    @State private var shown: [WordChip] = []

    var body: some View {
        NavigationStack {
            ScrollView {
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
                    } else if results.mode != .def && !shown.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(shown) { c in
                                if c.nearStart { Text("near").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(height: 38) }
                                Button { insert(c.word) } label: {
                                    HStack(spacing: 5) {
                                        Text(c.word).font(.system(size: 17, weight: .medium))
                                        Text("\(c.syl)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 14).frame(height: 38)
                                    .background(BarFill.color, in: Capsule())
                                }
                                .buttonStyle(PressScale())
                            }
                        }
                        .opacity(results.busy ? 0.5 : 1)
                    } else {
                        HStack(spacing: 8) {
                            if results.busy { ProgressView().controlSize(.small) }
                            Text(results.busy ? "Looking up “\(query)”" : results.message ?? "").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            // the word modes stay pinned under the search field, on glass
            .topBar { ModeGlassBar(mode: results.mode) { m in pick(m) } }
            .navigationTitle("Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search any word")
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .onSubmit(of: .search) { look(query) }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(280))
                look(query)
            }
            .onChange(of: results.chips) { _, new in
                // keep the old list up while the new one loads; then fade it in
                guard !new.isEmpty || !results.busy else { return }
                withAnimation(.easeOut(duration: 0.18)) { shown = new }
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
            if !initialWord.isEmpty { query = initialWord; look(initialWord) }
        }
        .sheetBelow(belowY)
        .presentationDragIndicator(.visible)
    }

    private func look(_ q: String) {
        let w = q.trimmingCharacters(in: .whitespaces)
        guard w != lastShown else { return }
        lastShown = w
        results.show(w)
    }

    private func pick(_ m: WordMode) {
        guard results.mode != m else { return }
        Haptics.selection()
        results.mode = m
        results.refresh()
    }

    /// Inserts at the caret remembered when the Dictionary opened, and moves that point along (spec §2.8).
    private func insert(_ w: String) {
        guard let at = insertAt else { return }
        insertAt = bridge.insertPlain(w, at: at)
        session.toast = "Inserted “\(w)”"
    }
}

/// The Dictionary's word modes on Liquid Glass: each a glass capsule, the chosen one filled; on iOS 26 they
/// share one glass container, so the selection melts from one to the next.
struct ModeGlassBar: View {
    let mode: WordMode
    var onPick: (WordMode) -> Void
    @Namespace private var ns

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                GlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(WordMode.allCases) { m in chip(m).id(m) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .onChange(of: mode, initial: true) { _, m in withAnimation(.snappy) { proxy.scrollTo(m, anchor: .center) } }
        }
    }

    @ViewBuilder private func chip(_ m: WordMode) -> some View {
        let on = m == mode
        let label = Text(m.title)
            .font(.system(size: 15, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Theme.onTint : Theme.tint)
            .padding(.horizontal, 15).frame(height: 36)
        Button { withAnimation(.snappy(duration: 0.25)) { onPick(m) } } label: {
            if #available(iOS 26.0, *) {
                label
                    .glassEffect(on ? .regular.tint(Theme.tint).interactive() : .regular.interactive(), in: .capsule)
                    .glassEffectID(m.rawValue, in: ns)
            } else {
                label.background(on ? AnyShapeStyle(Theme.tint) : AnyShapeStyle(.regularMaterial), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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
