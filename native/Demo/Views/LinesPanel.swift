import SwiftUI

/// Lines mode's results and cache (engines.md §2.3, `runGen`).
@MainActor @Observable
final class LinesModel {
    struct Option: Identifiable, Hashable {
        let id = UUID()
        var line: String
        var n: Int
        var d: Int
        var type: String      // perfect | near | loose | new
        var sc: Double
        var angle = ""        // image | move | twist | plain
        var meta: String {
            var m = (Self.angles[angle].map { $0 + " · " } ?? "") + "\(n) syl" + (d != 0 ? " (" + (d > 0 ? "+" : "") + "\(d))" : "")
            if type != "new" { m += " · " + (type == "loose" ? "loose rhyme" : type == "near" ? "near rhyme" : type) }
            return m
        }
        static let angles = ["image": "Image", "move": "Action", "twist": "Twist", "plain": "Plain talk"]
    }
    struct Entry {
        var busy = false
        var judging = false
        var list: [Option] = []
        var err: String?
        var kind = "line"     // line | next | rw | tighten
        var range = NSRange(location: 0, length: 0)
        var src = ""
        var judged = false
        var best: Double = 0
        var used = false
        var read = ""         // the thread the AI is following, shown above the lines
    }

    private(set) var cache: [String: Entry] = [:]
    var current: String?
    @ObservationIgnored private var history: [String: [String]] = [:]

    func entry(_ k: String) -> Entry? { cache[k] }
    func markUsed(_ k: String) { cache[k]?.used = true }
    func remove(_ k: String, _ o: Option) { cache[k]?.list.removeAll { $0.id == o.id } }
    func clear() { cache = [:]; current = nil }

    struct Request {
        var key: String
        var kind: String
        var n: Int
        var lw: String
        var keep: Bool
        var task: String
        var at: Int
        var section: [String]
        var range = NSRange(location: 0, length: 0)
        var src = ""
        var rewrite: NSRange?
        var prev = ""         // the line the new one follows on from
    }

    func run(_ o: Request, again: Bool, env: PromptEnv) {
        current = o.key
        if !again, let e = cache[o.key], !e.busy { return }
        if again, let e = cache[o.key], !e.list.isEmpty {
            if !e.used { MuseMemory.shared.passed(e.list.map(\.line), src: "lines", song: env.song.id) }
            var h = history[o.key] ?? []
            for x in e.list where !h.contains(x.line) { h.append(x.line) }
            if h.count > 30 { h.removeFirst(h.count - 30) }
            history[o.key] = h
        }
        cache[o.key] = Entry(busy: true, kind: o.kind, range: o.range, src: o.src)
        Task { await generate(o, again: again, env: env) }
    }

    private func generate(_ o: Request, again: Bool, env: PromptEnv) async {
        let eng = RhymeEngine.shared
        var P: [String] = [], N: [String] = []
        if !o.lw.isEmpty {
            if let r = await Datamuse.shared.rhymes(o.lw) { P = r.perfect; N = r.near }
            else { let s = eng.sets(o.lw); P = s.perfect; N = s.near }
        }
        let strict = env.song.voice["strict"]?.bool ?? true
        P = Array(P.prefix(40)); N = strict ? [] : Array(N.prefix(16))
        var ps = Set(P.map(RhymeEngine.normalise)), ns = Set(N.map(RhymeEngine.normalise))
        if o.keep && !o.lw.isEmpty { ps.insert(RhymeEngine.normalise(o.lw)) }
        _ = ns
        let rule: String
        if !o.lw.isEmpty {
            rule = !P.isEmpty || !N.isEmpty
                ? "End words that rhyme with \"" + o.lw + "\" (pick the ones that serve what the line is saying; skip any that would sound forced): " + P.joined(separator: ", ") + (N.isEmpty ? "" : "\nNear rhymes you may also use: " + N.joined(separator: ", ")) + "\nA strong word that isn't listed is fine if it rhymes to the ear."
                : "Rhyme with \"" + o.lw + "\" by ear."
        } else { rule = "No rhyme is required; end on a word that gives the next line somewhere to go." }
        let hist = history[o.key] ?? []
        let skip = hist.isEmpty ? "" : "\n\nAlready suggested and passed over. Don't repeat or reword these, and take different routes (different image, end word and structure): " + hist.map { "\"" + $0 + "\"" }.joined(separator: " / ")
        var prompt = "You are a sharp, tasteful co-writer helping a songwriter find the next line. Your lines have to be good enough that they'd actually keep one."
        prompt += Prompts.pfx(env)
        prompt += "\n\n"
        prompt += Prompts.songCtx(env, at: o.at, section: o.section, rewrite: o.rewrite)
        prompt += Prompts.museCtx(env, section: o.section)
        prompt += "\n\n"
        prompt += o.task
        prompt += "\n\n" + rule
        let prev = o.prev.trimmingCharacters(in: .whitespaces)
        if !prev.isEmpty {
            prompt += "\n\nThe line right before the new one: \"" + prev + "\"\nRead it like a co-writer before writing anything. What is it saying, and what does it leave hanging? A line like \"so i'd rather sleep alone\" raises questions: rather than what? why? since when? who isn't there anymore? Work out the thread the writer is most likely pulling (the reason, the alternative, the person, what happens next) and have the new line pick it up, so the two lines read as one thought. Then match that line's voice exactly: same person (I, you, we) and tense, the same plainness or poetry, its contractions, slang and capitalisation, and a similar sentence shape."
        } else {
            prompt += "\n\nBefore writing, work out what the section is saying, who is speaking to whom, and what the next line needs to do (land the feeling, add a detail, turn the thought, set up the next line)."
        }
        prompt += "\n\nWrite 12 lines, 3 for each of these approaches. Every line follows the same thread; the approach is only the way in:\n- image: one concrete, specific picture (an object, a place, a small physical detail) that carries the feeling without naming it.\n- move: an action or a moment, something someone does or says.\n- twist: turns the thought, a contrast, an admission or a line that reframes what came before.\n- plain: says it straight, in plain words the way a person would actually talk; simple and true, not clever."
        prompt += "\n\nRules for every line:\n- It must make sense as a sentence and follow on from the line before. Sense comes before rhyme: never bend word order or pick a word just to hit the rhyme.\n- Match the tone, vocabulary and imagery of the section, so it sounds like the same writer.\n- About \(o.n) syllables (within 2), natural to sing.\n- No filler or padding (\"oh\", \"yeah\", \"baby\", \"tonight\", \"I know\", \"you see\" tacked on), no clichés (\"heart of gold\", \"tears like rain\", \"set me free\"), no greeting-card abstractions (soul, destiny, forever) unless the song already uses them.\n- Use at least 6 different end words across the 12 lines.\n- Never repeat, reword or echo a line already in the song; only the end sound should match the line it rhymes with.\n- Just the lyric line: no quotes, notes or the rhyme word in brackets."
        prompt += skip
        prompt += "\n\nReturn ONLY JSON: {\"read\": \"the thread the next line picks up, under 10 words, in plain words (e.g. why she'd rather sleep alone)\", \"lines\": [{\"line\":\"...\",\"angle\":\"image\"}, ...]} with the best line first."
        do {
            let r = try await AIService.shared.json(prompt, tier: "write")
            var seen = Set<String>()
            // the reply is [{"line","angle"}]; plain strings still work
            let raw: [(String, String)] = (r.array ?? r["lines"]?.array ?? []).compactMap { x in
                if let t = x.string { return (t, "") }
                if let t = x["line"]?.string { return (t, x["angle"]?.string?.lowercased() ?? "") }
                return nil
            }
            let read = (r["read"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var l: [Option] = raw.enumerated().map { (i, x) in
                let line = Self.deparen(x.0, lw: o.lw)
                let w = RhymeEngine.normalise(RhymeContext.lastWord(line))
                let n = eng.lineSyllables(line), d = n - o.n
                let ty = o.lw.isEmpty ? "new" : ps.contains(w) ? "perfect" : (Set(N.map(RhymeEngine.normalise)).contains(w) ? "near" : "loose")
                // the AI's own order counts a little: it puts its best first
                return Option(line: line, n: n, d: d, type: ty, sc: Double(max(0, abs(d) - 1)) + (ty == "near" ? 1 : ty == "loose" ? 2 : 0) + Double(i) * 0.08, angle: x.1)
            }.filter { !$0.line.isEmpty && seen.insert($0.line).inserted }
            l.sort { $0.sc < $1.sc }
            l = Prompts.filter(l, text: env.text, min: 6) { $0.line }
            guard l.count >= 4 else { finish(o, l, judged: false, read: read); return }
            cache[o.key]?.judging = true
            let top = Array(l.prefix(14))
            if let js = await Prompts.judge(top.map(\.line), env: env, section: o.section, what: String(o.task.prefix(600))) {
                let ranked = top.enumerated().map { (i, x) in (x, (js[i] ?? 0) - x.sc * 0.55) }.sorted { $0.1 > $1.1 }.map(\.0)
                finish(o, ranked, judged: true, read: read)
            } else {
                finish(o, l, judged: false, read: read)
            }
        } catch {
            var off = false
            if let e = error as? AIService.AIError, case .off = e { off = true }
            cache[o.key] = Entry(err: off ? "Allow access to get line suggestions." : "Could not get suggestions.", kind: o.kind, range: o.range, src: o.src)
        }
    }

    private func finish(_ o: Request, _ list: [Option], judged: Bool, read: String = "") {
        // keep the order, but no more than two lines landing on the same end word
        var ends: [String: Int] = [:], out: [Option] = [], rest: [Option] = []
        for x in list {
            let w = RhymeEngine.normalise(RhymeContext.lastWord(x.line))
            if ends[w, default: 0] < 2 { ends[w, default: 0] += 1; out.append(x) } else { rest.append(x) }
        }
        out = Array((out + rest).prefix(6))
        if out.isEmpty {
            cache[o.key] = Entry(err: "No lines came back. Try again.", kind: o.kind, range: o.range, src: o.src)
        } else {
            cache[o.key] = Entry(list: out, kind: o.kind, range: o.range, src: o.src, judged: judged, best: out.map(\.sc).min() ?? 0, read: o.kind == "line" || o.kind == "next" ? String(read.prefix(90)) : "")
        }
    }

    /// Strips a trailing "(word)" that only repeats the line's own last word or the target word.
    static func deparen(_ x: String, lw: String) -> String {
        guard let m = x.firstMatch(of: #/^(.*?)\s*\(([^()]{1,30})\)\s*$/#) else { return x }
        let core = String(m.1).trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return x }
        let paren = RhymeEngine.normalise(String(m.2).trimmingCharacters(in: .whitespaces))
        if paren == RhymeEngine.normalise(RhymeContext.lastWord(core)) || (!lw.isEmpty && paren == RhymeEngine.normalise(lw)) { return core }
        return x
    }
}

/// What the rhyme bar shows in Lines mode (spec §4.9).
struct LinesPanel: View {
    let bridge: EditorBridge
    let context: RhymeContext
    let model: LinesModel
    let env: () -> PromptEnv?
    var onScheme: (String) -> Void
    var savedScheme: String

    @State private var whyFor: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let sel = context.selection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sel.isEmpty { selectionView(sel) } else { lineView }
        }
    }

    private var position: Int { context.stanza.count }

    // MARK: no selection

    @ViewBuilder private var lineView: some View {
        let key = keyFor()
        chipRow([("auto", "Auto" + (savedScheme == "auto" ? " · " + context.scheme : "")), ("ABAB", "ABAB"), ("AABB", "AABB"), ("ABBA", "ABBA"), ("ABCB", "ABCB")],
                on: savedScheme) { s in model.clear(); onScheme(s) }
        if let e = model.entry(key), model.current == key || model.current == nil {
            if e.busy { busyHint(e.judging ? "Picking the best ones for you" : "Writing line \(position + 1)") }
            else if let err = e.err {
                hint(err)
                goButton("Try again") { write(again: true) }
            } else {
                results(e, key: key) { o in bridge.applyLine(o.line) }
                goButton("New ideas") { write(again: true) }
            }
        } else {
            hint(introHint)
            goButton("Write line \(position + 1)") { write(again: false) }
        }
    }

    private var introHint: String {
        if !context.partner.isEmpty {
            return "Line \(position + 1) will rhyme with “\(RhymeContext.lastWord(context.partner))” (line \(context.partnerIndex + 1)) and match its \(RhymeEngine.shared.lineSyllables(context.partner)) syllables. Select words to work from just those."
        }
        return position > 0 ? "This line starts a new rhyme. I’ll match the syllables of the line above." : "Start a stanza. Write line 1, then press return for line 2."
    }

    private func keyFor() -> String {
        guard let e = env() else { return "" }
        return context.partner + "#\(position)#" + context.scheme + Prompts.pfk(e)
    }

    private func write(again: Bool) {
        guard let e = env() else { return }
        let t = context.partner
        let before = bridge.caretLine()?.before.trimmingCharacters(in: .whitespaces) ?? ""
        let n = !t.isEmpty ? RhymeEngine.shared.lineSyllables(t) : (context.stanza.last.map { RhymeEngine.shared.lineSyllables($0) } ?? 0)
        let prev = context.stanza.last ?? ""
        let task = "You are writing line \(position + 1) of this stanza (rhyme scheme \(context.scheme))."
            + (!t.isEmpty ? " It should rhyme with line \(context.partnerIndex + 1): \"" + t + "\"." : " It starts a new rhyme, so end on a common word that is easy to rhyme.")
            + (before.isEmpty ? "" : " The line must begin with: \"" + before + "\".")
        Haptics.tap()
        model.run(.init(key: keyFor(), kind: "line", n: n > 0 ? n : 8, lw: t.isEmpty ? "" : RhymeContext.lastWord(t), keep: false, task: task,
                        at: context.lineRange.location, section: context.stanza, prev: prev), again: again, env: e)
    }

    // MARK: with a selection

    @ViewBuilder private func selectionView(_ sel: String) -> some View {
        let kinds: [(String, String)] = [("next", "Lines that rhyme"), ("rw", "Rewrite selection"), ("tighten", "Tighten")]
        let keys = Dictionary(uniqueKeysWithValues: kinds.map { ($0.0, selKey($0.0, sel)) })
        let activeKind = kinds.first { keys[$0.0] == model.current }?.0
        chipRow(kinds, on: activeKind ?? "") { k in gen(k, sel, again: model.current == keys[k]) }
        if let k = activeKind, let key = keys[k], let e = model.entry(key) {
            if e.busy {
                busyHint(e.judging ? "Picking the best ones for you" : k == "next" ? "Writing lines that rhyme with your selection" : k == "tighten" ? "Tightening your selection" : "Rewriting your selection")
            } else if let err = e.err {
                hint(err)
            } else {
                results(e, key: key) { o in
                    if e.kind == "rw" || e.kind == "tighten" {
                        if !bridge.replaceSelection(e.src, at: e.range, with: o.line) { AppToast.post("The selected text has changed") }
                    } else {
                        bridge.insertAfter(e.range.location + e.range.length, o.line)
                    }
                }
            }
        } else {
            hint("Uses only what you selected: \(RhymeEngine.shared.lineSyllables(sel)) syllables, ending on “\(RhymeContext.lastWord(sel))”.")
        }
    }

    private func selKey(_ kind: String, _ sel: String) -> String {
        guard let e = env() else { return "" }
        return "S#" + kind + "#" + sel + Prompts.pfk(e)
    }

    private func gen(_ kind: String, _ sel: String, again: Bool) {
        guard let e = env(), let tv = bridge.textView else { return }
        Haptics.selection()
        let r = tv.selectedRange
        let ns = e.text as NSString
        let a = min(r.location, ns.length), b = min(r.location + r.length, ns.length)
        let lsR = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: a))
        let ls = lsR.location == NSNotFound ? 0 : lsR.location + 1
        let leR = ns.range(of: "\n", options: [], range: NSRange(location: b, length: ns.length - b))
        let le = leR.location == NSNotFound ? ns.length : leR.location
        let line = ns.substring(with: NSRange(location: ls, length: le - ls))
        let lw = RhymeContext.lastWord(sel)
        let task: String
        switch kind {
        case "rw": task = "Rewrite only this phrase: \"" + sel + "\". It sits in the line: \"" + line + "\". Each option replaces just that phrase, so the full line must still read naturally. Keep roughly the same meaning and end on a word that rhymes with \"" + lw + "\" (keeping \"" + lw + "\" is allowed)."
        case "tighten": task = "Rewrite only this phrase: \"" + sel + "\". It sits in the line: \"" + line + "\". Each option replaces just that phrase with a noticeably shorter version — fewer syllables, same meaning, still ending on a word that rhymes with \"" + lw + "\" (keeping \"" + lw + "\" is allowed) — so the line sings tighter against the melody without losing what it says."
        default: task = "Write a new line that rhymes with this phrase: \"" + sel + "\". It will go right after the line: \"" + line + "\"."
        }
        let range = NSRange(location: a, length: b - a)
        model.run(.init(key: selKey(kind, sel), kind: kind, n: RhymeEngine.shared.lineSyllables(sel), lw: lw, keep: kind == "rw" || kind == "tighten", task: task,
                        at: le, section: context.stanza, range: range, src: ns.substring(with: range), rewrite: kind == "next" ? nil : range, prev: kind == "next" ? line : ""),
                  again: again, env: e)
    }

    // MARK: pieces

    @ViewBuilder private func results(_ e: LinesModel.Entry, key: String, apply: @escaping (LinesModel.Option) -> Void) -> some View {
        if !e.read.isEmpty { hint("Following: " + e.read) }
        if e.best > 0 && !e.judged { hint("No exact match this time. Closest fits first.") }
        // a native list so a suggestion can be swiped away (full width, no ✕)
        List {
            ForEach(e.list) { o in
                Group {
                    if whyFor == o.id {
                        FlowLayout(spacing: 6) {
                            Text("Why not?").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(height: 32)
                            ForEach(MuseMemory.whyReasons, id: \.0) { r in
                                chip(r.1, on: false) { reject(o, key: key, why: r.0) }
                            }
                            chip("Just Hide It", on: false) { reject(o, key: key, why: "") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Button {
                            model.markUsed(key)
                            if let env = env() { MuseMemory.shared.used(o.line, src: "lines", song: env.song.id) }
                            Prompts.recordLineAccept(o.type)
                            apply(o)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(o.line).font(.system(size: 17)).foregroundStyle(Theme.tint).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(o.meta).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                            .padding(.horizontal, 15).padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .background(BarFill.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { Haptics.thud(); withAnimation(.snappy) { whyFor = o.id } } label: {
                                Label("Not this one", systemImage: "xmark")
                            }
                            .tint(.red)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        // as tall as the options, up to about a third of the screen, then it scrolls
        .frame(height: min(e.list.reduce(0) { $0 + ($1.id == whyFor ? 92 : (CGFloat(max(1, $1.line.count / 34 + 1)) * 22 + 28)) }, 300))
    }

    private func reject(_ o: LinesModel.Option, key: String, why: String) {
        Haptics.tap()
        MuseMemory.shared.reject(o.line, why: why, src: "lines", song: env()?.song.id)
        withAnimation(.snappy) { model.remove(key, o); whyFor = nil }
    }

    private func chipRow(_ items: [(String, String)], on: String, tap: @escaping (String) -> Void) -> some View {
        FadingHScroll {
            HStack(spacing: 6) {
                ForEach(items, id: \.0) { k, label in chip(label, on: k == on) { tap(k) } }
            }
        }
        .frame(height: 34)
    }

    private func chip(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            Text(t).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Theme.onTint : Theme.tint)
                .padding(.horizontal, 14).frame(height: 32)
                .background(on ? Theme.tint : BarFill.color, in: Capsule())
        }
        .buttonStyle(PressScale())
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 14)).foregroundStyle(.secondary).padding(.horizontal, 8).fixedSize(horizontal: false, vertical: true)
    }

    private func busyHint(_ t: String) -> some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(t).font(.system(size: 14)).foregroundStyle(.secondary) }
            .padding(.horizontal, 8).frame(minHeight: 36)
    }

    private func goButton(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Text(t).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.onTint)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Theme.tint, in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}

/// A toast from places that don't hold the session.
@MainActor
enum AppToast {
    static weak var session: AppSession?
    static func post(_ t: String) { session?.toast = t }
}
