import SwiftUI

/// Rate (spec §2.4, engines.md §2.5): scores and notes on the song, marked in the lyrics while rate mode is on.
struct RateSheet: View {
    let songID: String
    let bridge: EditorBridge
    let env: () -> PromptEnv?
    var onRework: () -> Void
    var onExit: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("songpad:rtone") private var tone = "enc"
    @State private var scope = "song"
    @State private var busy = false
    @State private var note: String?
    @State private var meaning: String?      // the issue quote being explained
    @State private var why = ""
    @State private var selection: NSRange?
    @State private var section: (name: String, range: NSRange)?

    struct Tone { let label, head, who, cal, count: String }
    static let tones: [String: Tone] = [
        "enc": Tone(label: "Encouraging", head: "Could be even stronger",
                    who: "You are warm and encouraging: you believe in the song, you name what is working first and generously, and you frame anything weaker as an opportunity, never a verdict. Music is subjective and you hold that lightly — your read is one take on it, not a judgment.",
                    cal: "Calibrate generously. Someone who cares enough to ask has a song worth taking seriously: a working draft that does its job usually sits around 7 to 8.5; a strong, distinctive song 9 and up; below 6.5 only if it genuinely is not working yet.",
                    count: "Give 3-4 strengths and 0-2 opportunities, most valuable first — it is completely fine to raise nothing if the song is solid. Word each opportunity kindly and constructively, and only raise it if you are genuinely confident it would help."),
        "bal": Tone(label: "Balanced", head: "Could be stronger",
                    who: "You are fair and supportive: honest about weak spots, equally clear about what works. Music is subjective — you give your honest read, not a scorecard of flaws, and you stay generous about taste and genre choices you might not personally make.",
                    cal: "A working draft by a capable writer usually sits around 6.5 to 8; strong, finished, distinctive writing goes higher; below 5.5 only if it genuinely is not working yet.",
                    count: "Give 3-4 strengths and 1-3 issues, most important first."),
        "blunt": Tone(label: "Blunt", head: "Where it falls apart",
                      who: "You are direct and exacting, like a producer who respects the writer enough to be honest — but never cold, never cruel, and never forgetting that taste in music is subjective.",
                      cal: "6 is competent but forgettable, 7.5 is good enough for a record, 9 and up is rare.",
                      count: "Give 3 strengths and 2-3 issues, worst first — the ones genuinely worth a writer's time, not every nitpick.")
    ]

    private var song: Song? { library.song(songID) }
    private var rating: [String: JSONValue]? { song?.raw["rating"]?.object }

    var body: some View {
        NavigationStack {
            Form {
                head
                if busy {
                    Section { HStack(spacing: 10) { ProgressView(); Text("Reading " + scopeLabel + " like a listener would").foregroundStyle(.secondary) } }
                } else if let note {
                    Section { Text(note).foregroundStyle(.secondary) }
                }
                if let r = rating, !busy { result(r) }
                intents
                if rating != nil {
                    Section { Button("Exit Rate Mode") { onExit(); dismiss() } }
                }
            }
            .navigationTitle("Rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
        }
        // full height: a shorter, floating sheet re-sizes (and looks like it zooms) when the keyboard comes up
        .presentationDetents([.large])
        .onAppear(perform: locate)
    }

    // MARK: head

    @ViewBuilder private var head: some View {
        Section("What to rate") {
            Picker("What to rate", selection: $scope) {
                Text("Whole song").tag("song")
                if let s = section { Text("This " + s.name).tag("sec") }
                if selection != nil { Text("Selection").tag("sel") }
            }
            .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
        Section {
            Picker("Feedback", selection: $tone) {
                ForEach(["enc", "bal", "blunt"], id: \.self) { Text(Self.tones[$0]!.label).tag($0) }
            }
            .pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            .onChange(of: tone) { _, _ in Haptics.selection() }
        } header: { Text("Feedback") } footer: {
            let v = song?.voice ?? [:]
            let gm = [v["genre"]?.string ?? "Any", v["mood"]?.string ?? "Any"].filter { $0 != "Any" }
            Text("Judged on what this song is going for and how you write" + (gm.isEmpty ? "." : ", with your \(gm.joined(separator: ", ")) voice in mind."))
        }
        Section {
            Button { run() } label: {
                Text(busy ? "Reading…" : rating == nil ? "Rate" : "Rate Again").font(.headline).frame(maxWidth: .infinity)
            }
            .disabled(busy)
        }
    }

    private var scopeLabel: String {
        switch scope {
        case "sec": section.map { "the \($0.name) section" } ?? "the whole song"
        case "sel": "the selected lines"
        default: "the whole song"
        }
    }

    /// The section containing the caret (its tag's name, trailing number removed) and the selection.
    private func locate() {
        guard let tv = bridge.textView else { return }
        let text = tv.text ?? ""
        let ns = text as NSString
        let sel = tv.selectedRange
        selection = sel.length > 0 ? sel : nil
        var found: (String, NSRange)?
        var pos = 0
        var starts: [(String, Int)] = []
        for l in text.components(separatedBy: "\n") {
            if let m = l.firstMatch(of: #/^\s*\[([^\]]+)\]\s*$/#) { starts.append((String(m.1), pos)) }
            pos += (l as NSString).length + 1
        }
        for (i, st) in starts.enumerated() where st.1 <= sel.location {
            let end = i + 1 < starts.count ? starts[i + 1].1 : ns.length
            let name = st.0.replacingOccurrences(of: #"\s*(\d+|x\d+)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            found = (name, NSRange(location: st.1, length: end - st.1))
        }
        section = found.map { (name: $0.0, range: $0.1) }
        if let r = rating?["scope"]?.string, r == "sec" && section != nil || r == "sel" && selection != nil || r == "song" { scope = r }
    }

    // MARK: result

    @ViewBuilder private func result(_ r: [String: JSONValue]) -> some View {
        let overall = r["overall"]?.number ?? 0
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", overall)).font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("/ 10").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    if let p = r["prev"]?.number {
                        let d = ((overall - p) * 10).rounded() / 10
                        Text(d == 0 ? "Same as last time" : (d > 0 ? "+" : "−") + String(format: "%.1f", abs(d)) + " since last time")
                            .font(.footnote.weight(.semibold)).foregroundStyle(d > 0 ? Theme.proGreen : d < 0 ? .orange : .secondary)
                    }
                }
                if let v = r["verdict"]?.string { Text(v) }
                if let pot = r["potential"]?.object, let ps = pot["score"]?.number {
                    Label { VStack(alignment: .leading, spacing: 2) {
                        Text("Could reach " + String(format: "%.1f", ps)).font(.subheadline.weight(.semibold))
                        Text(pot["how"]?.string ?? "").font(.subheadline).foregroundStyle(.secondary)
                    } } icon: { TileIcon("sparkles", Theme.Tile.orange) }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
        Section("How it was read") {
            readRow("Reads as", r["intent"]?.string)
            readRow("Its world", r["world"]?.string)
            readRow("Your style", r["personality"]?.string)
        }
        Section("Scores") {
            ForEach([("cleverness", "Cleverness"), ("legibility", "Legibility"), ("cohesion", "Cohesion"), ("voice", "Voice fit")], id: \.0) { k, label in
                let sc = r["scores"]?[k]
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(label)
                        Spacer()
                        Text(String(format: "%.1f", sc?["score"]?.number ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BarFill.color)
                            Capsule().fill(Theme.tint).frame(width: g.size.width * min(1, (sc?["score"]?.number ?? 0) / 10))
                        }
                    }
                    .frame(height: 5)
                    if let w = sc?["why"]?.string, !w.isEmpty { Text(w).font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 3)
            }
        }
        let strengths = (r["strengths"]?.array ?? []).compactMap(\.object)
        if !strengths.isEmpty {
            Section("What’s working") {
                ForEach(Array(strengths.enumerated()), id: \.offset) { _, x in
                    Button { jump(x["quote"]?.string ?? "") } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("“" + (x["quote"]?.string ?? "") + "”").foregroundStyle(.primary)
                            Text([x["role"]?.string ?? "", x["note"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        let issues = (r["issues"]?.array ?? []).compactMap(\.object)
        if !issues.isEmpty {
            Section(Self.tones[r["tone"]?.string ?? tone]?.head ?? "Could be stronger") {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, x in issueRow(x) }
            }
        }
        Section {
            EmptyView()
        } footer: {
            let sc = r["scope"]?.string ?? "song"
            Text([sc == "sec" ? "This section" : sc == "sel" ? "Selection" : "Whole song", Self.tones[r["tone"]?.string ?? "enc"]?.label ?? "",
                  (r["t"]?.number).map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    @ViewBuilder private func readRow(_ label: String, _ v: String?) -> some View {
        if let v, !v.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text(v).font(.subheadline)
            }
        }
    }

    @ViewBuilder private func issueRow(_ x: [String: JSONValue]) -> some View {
        let q = x["quote"]?.string ?? ""
        VStack(alignment: .leading, spacing: 6) {
            Text("“" + q + "”")
            Text([x["role"]?.string ?? "", x["problem"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            if let f = x["fix"]?.string, !f.isEmpty { Text("Try: " + f).font(.footnote) }
            if meaning == q {
                TextField("What were you going for? (optional)", text: Binding(get: { why }, set: { why = String($0.prefix(200)) }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Keep It") { keepIntent(q) }.buttonStyle(.borderedProminent).tint(Theme.tint)
                    Button("Cancel") { meaning = nil; why = "" }.buttonStyle(.bordered)
                }
            } else {
                HStack {
                    Button("Rework This") { rework(q) }.buttonStyle(.bordered)
                    Button("I Meant That") { Haptics.tap(); meaning = q; why = "" }.buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var intents: some View {
        let list = (song?.raw["intents"]?.array ?? []).compactMap(\.object)
        if !list.isEmpty {
            Section("Kept as intended") {
                ForEach(Array(list.enumerated()), id: \.offset) { _, x in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“" + (x["quote"]?.string ?? "") + "”")
                            Text((x["why"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? "No reason given").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Undo") { undoIntent(x["quote"]?.string ?? "") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: actions

    private func jump(_ q: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if !bridge.selectQuote(q) { session.toast = "That line has changed since the rating" }
        }
    }

    private func rework(_ q: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if bridge.selectQuote(q) { onRework(); session.toast = "Selected. Tap Rewrite selection for options." }
            else { session.toast = "That line has changed since the rating" }
        }
    }

    private func keepIntent(_ q: String) {
        guard var s = song else { return }
        var list = (s.raw["intents"]?.array ?? []).filter { $0["quote"]?.string != q }
        list.append(.object(["quote": .string(q), "why": .string(why.trimmingCharacters(in: .whitespacesAndNewlines)), "t": .number(Clock.nowMs)]))
        s.raw["intents"] = .array(list)
        if var r = s.raw["rating"]?.object {
            r["issues"] = .array((r["issues"]?.array ?? []).filter { $0["quote"]?.string != q })
            s.raw["rating"] = .object(r)
        }
        s.touch(); library.put(s)
        meaning = nil; why = ""
        MuseMemory.shared.autoProfile()
        session.toast = "Got it. Re-rating with that in mind."
        run()
    }

    private func undoIntent(_ q: String) {
        guard var s = song else { return }
        s.raw["intents"] = .array((s.raw["intents"]?.array ?? []).filter { $0["quote"]?.string != q })
        s.touch(); library.put(s)
        session.toast = "Removed. Rate again to include it."
    }

    /// runRate: the long rubric, the writer's context, the lyrics; saved on the song.
    private func run() {
        guard let e = env(), let s = song else { return }
        let v = e.text
        guard !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { session.toast = "Write something to rate first"; return }
        let ns = v as NSString
        var part = ""
        if scope == "sec", let sec = section, sec.range.location + sec.range.length <= ns.length { part = ns.substring(with: sec.range) }
        if scope == "sel", let sel = selection, sel.location + sel.length <= ns.length { part = ns.substring(with: sel) }
        let t = Self.tones[tone] ?? Self.tones["enc"]!
        let prev: JSONValue = (rating?["scope"]?.string == scope && (rating?["tone"]?.string ?? "blunt") == tone) ? (rating?["overall"] ?? .null) : .null
        let lyricLines = v.components(separatedBy: "\n").filter { let x = $0.trimmingCharacters(in: .whitespaces); return !x.isEmpty && !x.hasPrefix("[") }.count
        Haptics.tap()
        busy = true; note = nil
        var prompt = "You are a seasoned co-writer giving notes on song lyrics, the kind of person writers want in the room. "
        prompt += t.who
        prompt += " Listen first, then judge.\n\nSTEP 1, understand before scoring. Work out what this song is going for: its genre and its conventions, the feeling it is chasing, who is singing to whom, and how finished it is (status: "
        prompt += (s.status.isEmpty ? "Idea" : s.status)
        prompt += "; \(lyricLines) lyric lines so far). Judge the song on its own terms. Simple words, repetition, a familiar phrase or a direct hook can be exactly right in pop, country, hip-hop or folk when they are earned; abstraction can be right in dreamy indie. Familiar is not the same as weak — a well-worn phrase, a simple rhyme, or a line that sounds like plenty of others in its genre can still be exactly the right line if it lands. Slang, colloquial speech, regional or genre dialect (AAVE in hip-hop and R&amp;B, Southern or Americana phrasing in country, text-speak or internet voice in pop, bent grammar used for rhythm, emphasis or attitude) is not a legibility or craft problem — judge it by how it sounds spoken or sung in that voice, never against formal grammar. Don't reward generic, workshop-polished, 'correct' writing over something rougher that actually sounds like a person and fits the genre; technically tidy is not automatically better than something out there that works. Don't punish a deliberate choice. A sketch is rated on what is there and where it is heading, not on what is missing.\n\nRead every line in context, never in isolation. Before judging a line, ask what job it does in the song: a set-up that a later line pays off, a payoff, a plain line that makes the next image hit harder, a deliberate understatement, a callback to an earlier line, a twist on a repeated phrase, a transition into a new section, the hook, or a rhyme partner that works as a couplet. A line that looks flat or obvious on its own may be doing exactly its job. Section roles matter too: verses set scenes, pre-choruses build, choruses land the idea, bridges turn it. Only flag a line if it still fails once you account for what it sets up or pays off, and when you do, say why in terms of its role (for example: the set-up promises something the payoff never delivers).\n\nTHE SONG’S WORLD. Before judging any line, map the song’s world: its recurring images, motifs and settings, the metaphors it keeps returning to, and how its images connect across sections (for example a door in verse one that becomes a closed road in the bridge). A line that belongs to this world, extends a motif, or echoes an earlier image is working, even if it is abstract, surprising or unexplained on its own. Songs are allowed to leave images unexplained when the whole earns them. Never mark a line down for being unusual if it fits the world.\n\nCOHESION, LINE AGAINST LINE. Separately from the song's world, read the lines against each other in sequence, not just each on its own: does it keep a consistent tense and point of view, or drift without reason; do the verses echo or escalate the idea rather than repeat it with nothing new; does the hook or chorus feel earned by what led into it; does the ending answer, pay off or recontextualize the opening rather than just stopping. Score cohesion on how well the lines build on each other as a sequence, not on how good any single line is alone — a song of strong individual lines that never build on each other scores lower on cohesion than a simpler song that clearly goes somewhere.\n\nTHE WRITER’S PERSONALITY. Learn how this writer writes from this song, their other songs below, and what you have learned about them before: plain-spoken or ornate, literal or impressionistic, how they use rhyme, repetition, humour, fragments, slang and line length. This read updates every time you rate them — weigh what you're seeing in THIS song and what you've learned across their other songs above any generic idea of 'good writing'. Their habits are their voice, not mistakes. Judge the song against the best version of THIS writer, not against a generic ideal.\n\nWhen unsure whether a line is a flaw or a choice, treat it as a choice. Fewer, sharper notes beat many weak ones. Remember music is subjective: you are offering one experienced ear's honest read, not a final verdict, so stay generous and lead with what is working. Being insightful means explaining WHY something lands or doesn't in terms specific to this song, not cataloguing everything that could theoretically be improved — a song can be genuinely good with real weak spots left unmentioned because they are not worth this writer's time right now.\n\nSTEP 2, score each dimension 0-10 (one decimal) on how well it achieves what THIS song is going for:\n- cleverness: moments of craft that make you lean in (an image, a turn, a rhyme, a twist), relative to the style\n- legibility: does the listener get what they need to feel it; clear enough for the style\n- cohesion: judged line against line and section against section — does it build as one song rather than a pile of unrelated good lines\n- voice: does it sound like someone, and fit the writer's chosen voice settings when they set any\nUse your judgment rather than a formula. "
        prompt += t.cal
        prompt += " Overall is your gut feel as a listener, not an average.\n\nThe writer's voice settings:"
        prompt += Prompts.pfx(e)
        prompt += Prompts.writerContext(e)
        prompt += "\n\nSong: "
        prompt += (s.title.isEmpty ? "Untitled" : s.title)
        prompt += (s.artist.isEmpty ? "" : " by " + s.artist)
        prompt += (s.notes.isEmpty ? "" : "\nWriter's notes: " + String(s.notes.prefix(400)))
        prompt += "\n\nFull lyrics:\n"
        prompt += String(v.prefix(7000))
        prompt += (part.isEmpty ? "" : "\n\nRate ONLY this part, using the rest as context:\n" + part)
        prompt += Prompts.intentText(s)
        prompt += "\n\nReturn JSON exactly like (fill \"world\" and \"personality\" FIRST, then judge with them in mind): {\"world\":\"one or two sentences: the song's image world, motifs and how they connect\",\"personality\":\"one or two sentences: how this writer writes, their habits and strengths\",\"intent\":\"one sentence: what this song is going for and how you read it\",\"overall\":0,\"verdict\":\"one or two sentences, a human reaction, lead with what lands\",\"potential\":{\"score\":0,\"how\":\"one sentence: the single change that would lift it most\"},\"scores\":{\"cleverness\":{\"score\":0,\"why\":\"one sentence\"},\"legibility\":{\"score\":0,\"why\":\"\"},\"cohesion\":{\"score\":0,\"why\":\"\"},\"voice\":{\"score\":0,\"why\":\"\"}},\"strengths\":[{\"quote\":\"\",\"role\":\"1-3 words\",\"note\":\"\"}],\"issues\":[{\"quote\":\"\",\"role\":\"what this line is doing in the song, 1-3 words (e.g. set-up, payoff, hook, transition, image, callback)\",\"problem\":\"why it falls short in context\",\"check\":\"why this is not explained by the song's world or the writer's style\",\"confidence\":0.0,\"fix\":\"\"}]}\n"
        prompt += t.count
        prompt += " Only raise what a good co-writer actually would. Give each issue a confidence from 0 to 1 that it is a real weakness rather than a deliberate choice. Every quote must be copied EXACTLY from the lyrics (a phrase or a full line). Each fix is a concrete direction, not a rewritten line."
        let finalPrompt = prompt
        let scopeNow = scope, toneNow = tone
        Task {
            defer { busy = false }
            do {
                var r = try await AIService.shared.json(finalPrompt, complex: true).object ?? [:]
                guard r["overall"]?.number != nil, r["scores"]?.object != nil else { note = "That didn’t come back cleanly. Try again."; return }
                let sq = Set((r["strengths"]?.array ?? []).compactMap { $0["quote"]?.string?.lowercased() })
                r["issues"] = .array((r["issues"]?.array ?? []).filter { x in
                    let q = (x["quote"]?.string ?? "").lowercased()
                    if sq.contains(q) { return false }
                    if sq.contains(where: { !$0.isEmpty && ($0.contains(q) || q.contains($0)) }) { return false }
                    guard let c = x["confidence"]?.number else { return true }
                    return c >= 0.72
                })
                if let p = r["personality"]?.string { r["personality"] = .string(String(p.prefix(300))) }
                r["t"] = .number(Clock.nowMs); r["scope"] = .string(scopeNow); r["tone"] = .string(toneNow); r["prev"] = prev; r["marks"] = true
                guard var now = library.song(songID) else { return }
                now.raw["rating"] = .object(r)
                now.touch()
                library.put(now)
                Haptics.success()
            } catch {
                var off = false
                if let e = error as? AIService.AIError, case .off = e { off = true }
                note = off ? "Allow access to get a rating." : "Couldn’t get a rating. Try again in a moment."
            }
        }
    }
}
