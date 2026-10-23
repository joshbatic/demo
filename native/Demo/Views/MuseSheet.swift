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
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var out: Output = .none
    @State private var seq = 0
    @State private var whyFor: String?

    enum Output: Equatable {
        case none, busy(String), error(String), read(Read), stare(String), card(String)
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
            Form {
                if out != .none { Section { output } }
                Section {
                    NavigationLink { BriefForm(songID: songID) } label: {
                        card(Prompts.brief(song ?? Song(raw: [:])).isEmpty ? "Tell the muse about this song" : "About this song",
                             briefSummary.isEmpty ? "Who’s singing, to whom, where, one real detail." : briefSummary, icon: "person.text.rectangle", color: Theme.Tile.indigo)
                    }
                    Button { readSong() } label: {
                        card("Read my song", "What this is really about, where it stalls, and a few doors out", icon: "book", color: Theme.Tile.purple)
                    }
                    Button {
                        if rateOn { onRateOff(); session.toast = "Rate mode off"; dismiss(); return }
                        guard session.plan.isPro else { Haptics.warning(); session.toast = "Rate is part of *[demo] Pro"; return }
                        dismiss(); onRate()
                    } label: {
                        card(rateOn ? "Rate mode is on" : "Rate my song", rateOn ? "Notes are marked in your lyrics. Tap to hide them." : "Scores and notes on what’s landing and what isn’t",
                             icon: "star", color: Theme.Tile.orange, locked: !session.plan.isPro && !rateOn)
                    }
                }
                Section {
                    Button { stare() } label: { card("Stare at a thing", "90 seconds on one object. Every sense. No rhyming.", icon: "eye", color: Theme.Tile.teal) }
                    Button { Haptics.tap(); out = .card(Self.cards.randomElement()!) } label: { card("Wild card", "One odd instruction. Just do it.", icon: "suit.club", color: Theme.Tile.pink) }
                    Button { dismiss(); onSprint(300, nil) } label: { card("Pen never stops", "Five minutes. No deleting. No rhyme bar. Go.", icon: "timer", color: Theme.Tile.green) }
                }
            }
            .navigationTitle("Muse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
        }
        .presentationDetents([.fraction(0.84)])
    }

    private var briefSummary: String {
        guard let b = song?.raw["brief"]?.object else { return "" }
        let who = b["who"]?.string ?? "", to = b["to"]?.string ?? "", wh = b["where"]?.string ?? ""
        return [who, to.isEmpty ? "" : "to " + to, wh].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func card(_ title: String, _ sub: String, icon: String, color: Color, locked: Bool = false) -> some View {
        HStack(spacing: 12) {
            TileIcon(icon, color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).foregroundStyle(.primary)
                    if locked {
                        Text("Pro").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.proGreen, in: Capsule()).foregroundStyle(.white)
                    }
                }
                Text(sub).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: output

    @ViewBuilder private var output: some View {
        switch out {
        case .none: EmptyView()
        case .busy(let t):
            HStack(spacing: 10) { ProgressView(); Text(t).foregroundStyle(.secondary) }
        case .error(let t):
            Text(t).foregroundStyle(.secondary)
        case .card(let t):
            VStack(alignment: .leading, spacing: 10) {
                Text("Strategy card").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(t).font(.title3.weight(.semibold))
                Button("Another card") { Haptics.tap(); out = .card(Self.cards.filter { $0 != t }.randomElement()!) }
            }
        case .stare(let noun):
            VStack(alignment: .leading, spacing: 10) {
                Text("Zoom in on").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(noun).font(.system(size: 30, weight: .bold))
                Text("90 seconds on just this: how it looks, sounds, smells and feels. No rhyming. It goes in a scratch section.").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("Start 90 seconds") { dismiss(); onSprint(90, noun) }.buttonStyle(.borderedProminent).tint(Theme.tint)
                    Button("Another object") { stare() }.buttonStyle(.bordered)
                }
            }
        case .read(let r):
            VStack(alignment: .leading, spacing: 10) {
                Text(r.text)
                if !r.questions.isEmpty {
                    Text("Answer one of these in your head").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    ForEach(r.questions, id: \.self) { Text("• " + $0).font(.subheadline) }
                }
                Text("Ways forward (tap to add the line)").font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(r.moves) { m in moveRow(m) }
                Button("Read again") { readSong() }.padding(.top, 4)
            }
        }
    }

    @ViewBuilder private func moveRow(_ m: Move) -> some View {
        if whyFor == m.line {
            FlowLayout(spacing: 6) {
                Text("Why not?").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).frame(height: 30)
                ForEach(MuseMemory.whyReasons, id: \.0) { r in
                    Button(r.1) { reject(m, r.0) }.buttonStyle(.bordered).controlSize(.small)
                }
                Button("Just Hide It") { reject(m, "") }.buttonStyle(.bordered).controlSize(.small)
            }
        } else {
            HStack(alignment: .top) {
                Button {
                    MuseMemory.shared.used(m.line, src: "muse", song: songID)
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        bridge.textView?.becomeFirstResponder()
                        bridge.insertLine(m.line)
                        session.toast = "Added to your song"
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        if !m.idea.isEmpty { Text(m.idea).font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                        Text(m.line).foregroundStyle(.primary)
                        Text("\(RhymeEngine.shared.lineSyllables(m.line)) syl · tap to add").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(BarFill.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressScale())
                Button { Haptics.selection(); withAnimation(.snappy) { whyFor = m.line } } label: {
                    Icon("ic-close", 12).foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not this one")
            }
        }
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
                let r = try await AIService.shared.json(prompt)
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

/// The song brief: what the muse knows about this song (spec §2.3).
struct BriefForm: View {
    let songID: String
    @Environment(LibraryStore.self) private var library
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var who = ""
    @State private var to = ""
    @State private var place = ""
    @State private var thing = ""
    @State private var more = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section { Text("Fill in what you like.").foregroundStyle(.secondary) }
            Section("Who’s singing") { TextField("e.g. me at 19, my dad, a bartender closing up", text: limited($who, 160)) }
            Section("Singing to") { TextField("e.g. my ex, my brother, nobody", text: limited($to, 160)) }
            Section("Where and when") { TextField("e.g. Glenelg, the night before I moved", text: limited($place, 160)) }
            Section("One real detail from it") { TextField("e.g. her blue Corolla with the cracked windscreen", text: limited($thing, 160)) }
            Section("Anything else that’s true") { TextField("what actually happened, what you can’t say out loud", text: limited($more, 600), axis: .vertical).lineLimit(3...10) }
            Section {
                Button("Save") { save() }
                Button("Clear", role: .destructive) { who = ""; to = ""; place = ""; thing = ""; more = ""; save() }
                    .disabled(allEmpty && library.song(songID)?.raw["brief"] == nil)
            }
        }
        .navigationTitle("Tell the muse about this song")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded, let b = library.song(songID)?.raw["brief"]?.object else { loaded = true; return }
            who = b["who"]?.string ?? ""; to = b["to"]?.string ?? ""; place = b["where"]?.string ?? ""
            thing = b["thing"]?.string ?? ""; more = b["more"]?.string ?? ""
            loaded = true
        }
    }

    private var allEmpty: Bool { [who, to, place, thing, more].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    private func limited(_ b: Binding<String>, _ n: Int) -> Binding<String> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = String($0.prefix(n)) })
    }

    private func save() {
        guard var s = library.song(songID) else { return }
        if allEmpty { s.raw.removeValue(forKey: "brief") }
        else {
            s.raw["brief"] = .object(["who": .string(who.trimmingCharacters(in: .whitespaces)), "to": .string(to.trimmingCharacters(in: .whitespaces)),
                                      "where": .string(place.trimmingCharacters(in: .whitespaces)), "thing": .string(thing.trimmingCharacters(in: .whitespaces)),
                                      "more": .string(more.trimmingCharacters(in: .whitespacesAndNewlines))])
        }
        s.touch()
        library.put(s)
        Haptics.success()
        session.toast = allEmpty ? "Song brief cleared" : "The muse knows this song now"
        dismiss()
    }
}
