import SwiftUI

/// The Muse (spec §2.3): tell it about the song, have it read the song, or try a card.
struct MuseSheet: View {
    let songID: String
    let bridge: EditorBridge
    let section: [String]
    let env: () -> PromptEnv?
    var rateOn: Bool
    var onRate: () -> Void
    var onRateOff: () -> Void
    var onSprint: (_ seconds: Int, _ scratch: String?) -> Void
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var out: Output = .none
    @State private var seq = 0
    @State private var whyFor: String?
    @State private var who = ""
    @State private var to = ""
    @State private var place = ""
    @State private var thing = ""
    @State private var more = ""
    /// The list's content height, so the sheet opens just tall enough for it.
    @State private var contentHeight: CGFloat = 520
    /// typing in the brief: the sheet holds its size so it doesn't jump with every line
    @FocusState private var typing: Bool

    enum Output: Equatable {
        case none, busy(String), error(String), read(Read), stare(String), card(String), brief
    }
    struct Read: Equatable {
        var text: String
        var questions: [String]
        var moves: [Move]
    }
    struct Move: Equatable, Identifiable { var id: String { line }; var idea: String; var line: String }

    static let cards = ["Say the quiet part out loud.", "Write the line you would never sing to their face.", "Swap the feeling for an object you could hold.", "Move the scene to a kitchen at 3am.", "What is the smallest true detail you remember?", "Write the next line as a text you never sent.", "Change the tense. Then change it back.", "Cut your first line and start at the second.", "Give the “you” a name.", "Write the opposite of what you mean.", "Put the weather in it.", "Count something.", "Name a real street, shop or brand.", "Ask a question you can’t answer.", "Turn the next four lines into a list.", "Write what happened five minutes before this.", "What is the shortest version of this song? Say it in six words.", "Let a stranger say the next line.", "Lie in the next line.", "Use something someone actually said to you.", "Tell it from the point of view of the room.", "Rhyme on the first word of the line, not the last.", "Make it smaller: one room, one minute.", "Repeat your best line and change one word.", "What’s on the floor?", "Hum the melody first. Find words for the vowels.", "Write the bridge before the chorus.", "Argue with your own title.", "Write the ending first.", "What does this song want that it can’t have?"]
    static let nouns = ["matchbook", "porch light", "ferry", "radio", "ash tray", "car keys", "hospital bed", "church hall", "bus shelter", "motel pool", "windscreen", "wedding dress", "fishing line", "loose tooth", "phone charger", "backyard", "hairbrush", "ticket stub", "mirror", "tram", "rain gutter", "screen door", "kitchen table", "petrol station", "stairwell", "bedsheet", "lighthouse", "paper cup", "jukebox", "overcoat"]

    private var song: Song? { library.song(songID) }

    var body: some View {
        NavigationStack {
            // a list (not a plain scroll) so the ways forward can be swiped away
            List {
                if out != .none {
                    outputCard.listRow(top: 4)
                    if case .read(let r) = out {
                        ForEach(r.moves) { m in moveRow(m).listRow(h: 20) }
                        acts([("Read again", true, { readSong() })]).padding(.horizontal, 20).listRow()
                    }
                }
                grid.listRow(top: 4, bottom: 24)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .animation(.snappy(duration: 0.25), value: out)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, h in if !typing { contentHeight = h } }
            .navigationTitle("Muse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
        }
        // content + the nav bar, never taller than most of the screen (results then scroll)
        .presentationDetents([.height(min(contentHeight + 64, UIScreen.main.bounds.height * 0.9))])
    }

    // MARK: the cards (the web's .stg grid of .stc buttons)

    /// The web's --row: a light card on the sheet.
    static let row = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.1) : UIColor(white: 1, alpha: 0.7) })

    private var grid: some View {
        VStack(spacing: 10) {
            // the song brief and Read my song run full width; the rest sit two to a row
            let bs = briefSummary
            stc(title: (bs.isEmpty ? "" : "✓ ") + (bs.isEmpty ? "Tell the muse about this song" : "About this song"),
                sub: bs.isEmpty ? "Who’s singing, to whom, where, one real detail." : bs,
                fill: BarFill.color, minH: 0) { openBrief() }
            stc(title: "Read my song", sub: "What this is really about, where it stalls, and a few doors out",
                fill: Theme.tint, ink: Theme.onTint, minH: 0) { readSong() }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            stc(title: rateOn ? "Rate mode is on" : "Rate my song",
                sub: rateOn ? "Notes are marked in your lyrics. Tap to hide them." : "Scores and notes on what’s landing and what isn’t",
                pro: !session.plan.isPro && !rateOn, ring: rateOn) {
                if rateOn { onRateOff(); session.toast = "Rate mode off"; dismiss(); return }
                guard session.plan.isPro else { session.upsell("rate"); return }
                dismiss(); onRate()
            }
            stc(title: "Stare at a thing", sub: "90 seconds on one object. Every sense. No rhyming.") { stare() }
            stc(title: "Wild card", sub: "One odd instruction. Just do it.") { Haptics.tap(); out = .card(Self.cards.randomElement()!) }
            stc(title: "Pen never stops", sub: "Five minutes. No deleting. No rhyme bar. Go.") { dismiss(); onSprint(300, nil) }
            }
        }
        .padding(.horizontal, 16)
    }

    /// One card: bold title, muted line under it.
    private func stc(title: String, sub: String, fill: Color = MuseSheet.row, ink: Color = .primary, pro: Bool = false, ring: Bool = false,
                     minH: CGFloat = 86, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                    if pro {
                        Text("Pro").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.proGreen, in: Capsule()).foregroundStyle(.white)
                    }
                }
                Text(sub).font(.system(size: 13)).foregroundStyle(ink.opacity(ink == .primary ? 0.55 : 0.7)).lineSpacing(1.5)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: minH, alignment: .topLeading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(fill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                if ring { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color(hex: 0xFF9F0A), lineWidth: 1.5) }
            }
        }
        .buttonStyle(PressScale())
    }

    // MARK: the output card (the web's #stk-out)

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) { output }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 20)
    }

    private func h4(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func acts(_ items: [(String, Bool, () -> Void)]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Button { Haptics.tap(); it.2() } label: {
                    Text(it.0).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(it.1 ? Theme.onTint : Theme.tint)
                        .padding(.horizontal, 16).frame(height: 38)
                        .background(it.1 ? Theme.tint : BarFill.color, in: Capsule())
                }
                .buttonStyle(PressScale())
            }
        }
        .padding(.top, 4)
    }

    private var briefSummary: String {
        guard let b = song?.raw["brief"]?.object else { return "" }
        let who = b["who"]?.string ?? "", to = b["to"]?.string ?? "", wh = b["where"]?.string ?? ""
        return [who, to.isEmpty ? "" : "to " + to, wh].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var output: some View {
        switch out {
        case .none: EmptyView()
        case .busy(let t):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(t).font(.system(size: 16)) }
        case .error(let t):
            Text(t).font(.system(size: 16))
        case .card(let t):
            h4("Strategy card")
            Text(t).font(.system(size: 22, weight: .semibold)).tracking(-0.2)
            acts([("Another card", true, { out = .card(Self.cards.filter { $0 != t }.randomElement()!) })])
        case .stare(let noun):
            h4("Zoom in on")
            Text(noun).font(.system(size: 22, weight: .semibold)).tracking(-0.2)
            Text("90 seconds on just this: how it looks, sounds, smells and feels. No rhyming. It goes in a scratch section.").font(.system(size: 16))
            acts([("Start 90 seconds", true, { dismiss(); onSprint(90, noun) }), ("Another object", false, { stare() })])
        case .brief:
            briefForm
        case .read(let r):
            Text(r.text).font(.system(size: 16))
            if !r.questions.isEmpty {
                h4("Answer one of these in your head")
                ForEach(r.questions, id: \.self) { Text("• " + $0).font(.system(size: 16)) }
            }
            h4("Ways forward (tap to add the line)")
        }
    }

    // MARK: the brief, inline (briefForm)

    @ViewBuilder private var briefForm: some View {
        h4("Tell the muse about this song")
        Text("Fill in what you like.").font(.system(size: 14)).foregroundStyle(.secondary)
        briefField("Who’s singing", "e.g. me at 19, my dad, a bartender closing up", $who, 160)
        briefField("Singing to", "e.g. my ex, my brother, nobody", $to, 160)
        briefField("Where and when", "e.g. Glenelg, the night before I moved", $place, 160)
        briefField("One real detail from it", "e.g. her blue Corolla with the cracked windscreen", $thing, 160)
        briefField("Anything else that’s true", "what actually happened, what you can’t say out loud", $more, 600, multi: true)
        HStack(spacing: 8) {
            Button { saveBrief() } label: {
                Text("Save").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.onTint)
                    .padding(.horizontal, 16).frame(height: 38).background(Theme.tint, in: Capsule())
            }
            .buttonStyle(PressScale())
            Button { clearBrief() } label: {
                Text("Clear").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.tint)
                    .padding(.horizontal, 16).frame(height: 38).background(BarFill.color, in: Capsule())
            }
            .buttonStyle(PressScale())
            .disabled(briefEmpty && song?.raw["brief"] == nil)
            .opacity(briefEmpty && song?.raw["brief"] == nil ? 0.4 : 1)
        }
        .padding(.top, 4)
    }

    private func briefField(_ label: String, _ ph: String, _ b: Binding<String>, _ max: Int, multi: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            TextField(ph, text: Binding(get: { b.wrappedValue }, set: { b.wrappedValue = String($0.prefix(max)) }), axis: multi ? .vertical : .horizontal)
                .lineLimit(multi ? 3...8 : 1...1)
                .font(.system(size: 16))
                .focused($typing)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(BarFill.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var briefEmpty: Bool { [who, to, place, thing, more].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    private func openBrief() {
        let b = song?.raw["brief"]?.object
        who = b?["who"]?.string ?? ""; to = b?["to"]?.string ?? ""; place = b?["where"]?.string ?? ""
        thing = b?["thing"]?.string ?? ""; more = b?["more"]?.string ?? ""
        seq += 1
        out = .brief
    }

    private func saveBrief() {
        guard var s = song else { return }
        let any = !briefEmpty
        if any {
            var o: [String: JSONValue] = [:]
            for (k, v) in [("who", who), ("to", to), ("where", place), ("thing", thing), ("more", more)] {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { o[k] = .string(t) }
            }
            s.raw["brief"] = .object(o)
        } else { s.raw.removeValue(forKey: "brief") }
        s.touch(); library.put(s)
        Haptics.success()
        session.toast = any ? "The muse knows this song now" : "Song brief cleared"
        out = .none
    }

    private func clearBrief() {
        who = ""; to = ""; place = ""; thing = ""; more = ""
        if var s = song, s.raw["brief"] != nil {
            s.raw.removeValue(forKey: "brief"); s.touch(); library.put(s)
            Haptics.tap(); session.toast = "Song brief cleared"
        }
    }

    @ViewBuilder private func moveRow(_ m: Move) -> some View {
        if whyFor == m.line {
            FlowLayout(spacing: 6) {
                Text("Why not?").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(height: 32)
                ForEach(MuseMemory.whyReasons, id: \.0) { r in reasonChip(r.1) { reject(m, r.0) } }
                reasonChip("Just Hide It") { reject(m, "") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                MuseMemory.shared.used(m.line, src: "muse", song: songID)
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    bridge.textView?.becomeFirstResponder()
                    bridge.insertLine(m.line)
                    session.toast = "Added to your song"
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    if !m.idea.isEmpty { Text(m.idea).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary) }
                    Text(m.line).font(.system(size: 16)).foregroundStyle(.primary)
                    Text("\(RhymeEngine.shared.lineSyllables(m.line)) syl · tap to add").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(BarFill.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { Haptics.thud(); withAnimation(.snappy) { whyFor = m.line } } label: {
                    Label("Not this one", systemImage: "xmark")
                }
                .tint(.red)
            }
        }
    }

    private func reasonChip(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            Text(t).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.tint)
                .padding(.horizontal, 14).frame(height: 32)
                .background(BarFill.color, in: Capsule())
        }
        .buttonStyle(PressScale())
    }

    private func reject(_ m: Move, _ why: String) {
        Haptics.tap()
        MuseMemory.shared.reject(m.line, why: why, src: "muse", song: songID)
        if case .read(var r) = out {
            r.moves.removeAll { $0.line == m.line }
            withAnimation(.snappy) { out = .read(r); whyFor = nil }
        }
    }

    // MARK: actions

    private func stare() {
        Haptics.tap()
        var noun = Self.nouns.randomElement()!
        if Bool.random(), let s = song {
            let words = Prompts.llines(s).flatMap { l in l.matches(of: #/[A-Za-z']+/#).map { String(l[$0.range]).lowercased() } }
                .filter { $0.count > 3 && !RhymeEngine.stop.contains($0) }
            var counts: [String: Int] = [:]
            words.forEach { counts[$0, default: 0] += 1 }
            if let top = counts.sorted(by: { $0.value > $1.value }).prefix(5).randomElement()?.key { noun = top }
        }
        out = .stare(noun)
    }

    /// Read my song (engines.md §2.4).
    private func readSong() {
        guard let e = env() else { return }
        Haptics.tap()
        seq += 1
        let mine = seq
        out = .busy("Reading your song")
        let at = bridge.textView?.selectedRange.location
        let prompt = "You are a songwriting mentor helping a writer who is stuck." + Prompts.pfx(e) + "\n\n" + Prompts.songCtx(e, at: at, section: section) + Prompts.museCtx(e, section: section)
            + "\n\nRespond as JSON: {\"read\": one or two plain sentences on what this song is really about so far and where it seems to stall, \"questions\": 3 short, specific questions about the song's subject that would dig up fresh material from the writer's real life, \"moves\": 8 objects {\"idea\": a short direction to take next (under 12 words), \"line\": a next line that starts that direction, in this writer's voice and matching the song's line length}}. The 8 moves must go in genuinely different directions. Be concrete, no flattery. If the song is empty, read the title, notes and brief and suggest openings."
        Task {
            do {
                let r = try await AIService.shared.json(prompt, tier: "write")
                guard mine == seq else { return }
                guard let moves = r["moves"]?.array else { out = .error("Couldn’t get a response. Try again in a moment."); return }
                var mv = moves.compactMap { m -> Move? in
                    guard let line = m["line"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
                    return Move(idea: m["idea"]?.string ?? "", line: line)
                }
                mv = Prompts.filter(mv, text: e.text, min: 4) { $0.line }
                out = .busy("Picking the best ways forward")
                if let js = await Prompts.judge(mv.map(\.line), env: e, section: section, what: "the next line for this song") {
                    mv = mv.enumerated().sorted { (js[$0.offset] ?? 0) > (js[$1.offset] ?? 0) }.map(\.element)
                }
                guard mine == seq else { return }
                var seen = Set<String>()
                withAnimation(.snappy) {
                    out = .read(Read(text: r["read"]?.string ?? "", questions: r["questions"]?.stringList ?? [], moves: Array(mv.filter { seen.insert($0.line).inserted }.prefix(4))))
                }
            } catch {
                guard mine == seq else { return }
                var msg = "Couldn’t get a response. Try again in a moment."
                if let e = error as? AIService.AIError, case .off = e { msg = e.errorDescription ?? msg }
                out = .error(msg)
            }
        }
    }
}

private extension View {
    /// A row in the Muse list: no separator or background, set insets.
    func listRow(h: CGFloat = 0, top: CGFloat = 3, bottom: CGFloat = 3) -> some View {
        self.listRowInsets(EdgeInsets(top: top, leading: h, bottom: bottom, trailing: h))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
