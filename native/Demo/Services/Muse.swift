import Foundation
import Observation
import Supabase

// MARK: - the muse's memory (engines.md §2.2)

/// What this writer does with suggestions: kept word for word, edited (with their version), deleted,
/// rejected with a reason, or passed over. Kept per account on the device and in `muse_events`;
/// the learned voice profile lives in `muse_profile`.
@MainActor @Observable
final class MuseMemory {
    static let shared = MuseMemory()

    struct Event: Codable, Hashable {
        var id: String
        var song: String?
        var src: String?
        var o: String
        var shown: String?
        var final: String?
        var why: String?
        var at: Double
    }
    struct Pending: Codable, Hashable { var id: String; var song: String; var src: String; var shown: String; var at: Double }
    struct Profile: Codable, Hashable { var text: String; var edited: Bool; var at: Double; var n: Int }

    private(set) var events: [Event] = []
    private(set) var pending: [Pending] = []
    var profile: Profile?
    private(set) var building = false

    @ObservationIgnored private var uid: String?
    @ObservationIgnored private var queue: [Event] = []
    @ObservationIgnored private var noTable = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored weak var session: AppSession?

    static let whyReasons: [(String, String)] = [("cliche", "Cliché"), ("voice", "Not my voice"), ("nose", "Too on the nose"), ("sing", "Doesn’t sing"), ("sense", "Makes no sense")]
    static func whyLabel(_ k: String?) -> String? { whyReasons.first { $0.0 == k }?.1 }

    private func key(_ k: String) -> String { "songpad:muse:" + k + (uid.map { ":" + $0 } ?? "") }

    /// Loads this account's memory and pulls the cloud copy.
    func open(uid: String?, library: LibraryStore, session: AppSession) {
        self.library = library
        self.session = session
        guard uid != self.uid || events.isEmpty && pending.isEmpty && profile == nil else { return }
        self.uid = uid
        let d = UserDefaults.standard
        events = (try? JSONDecoder().decode([Event].self, from: d.data(forKey: key("ev")) ?? Data())) ?? []
        pending = (try? JSONDecoder().decode([Pending].self, from: d.data(forKey: key("pend")) ?? Data())) ?? []
        profile = try? JSONDecoder().decode(Profile.self, from: d.data(forKey: key("prof")) ?? Data())
        building = false
        queue = []
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(force: false) }
            }
        }
        Task { await pull() }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(Array(events.suffix(500))), forKey: key("ev"))
        d.set(try? JSONEncoder().encode(Array(pending.suffix(40))), forKey: key("pend"))
    }

    private func storeProfile(push: Bool) {
        UserDefaults.standard.set(try? JSONEncoder().encode(profile), forKey: key("prof"))
        guard push, let p = profile, let uid, !noTable else { return }
        let row: [String: JSONValue] = ["user_id": .string(uid), "profile": .string(p.text), "edited": .bool(p.edited), "basis": .number(Double(p.n)),
                                        "updated_at": .string(Self.iso(p.at))]
        Task {
            do { _ = try await Backend.client.from("muse_profile").upsert(row, onConflict: "user_id").execute() }
            catch { if Self.missing(error) { noTable = true } }
        }
    }

    static func newID() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String((0..<7).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }
    static func iso(_ ms: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000)) }
    static func missing(_ e: Error) -> Bool { "\(e)".range(of: "relation|does not exist|schema cache|42P01|PGRST20", options: .regularExpression) != nil }

    func log(_ e: Event) {
        events.append(e)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        save()
        queue.append(e)
        if queue.count > 500 { queue.removeFirst(queue.count - 500) }
        flush()
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, uid != nil, !noTable, !queue.isEmpty else { return }
            let batch = Array(queue.prefix(50))
            queue.removeFirst(batch.count)
            let rows: [[String: JSONValue]] = batch.map { e in
                var r: [String: JSONValue] = ["id": .string(e.id), "outcome": .string(e.o), "created_at": .string(Self.iso(e.at))]
                r["song_id"] = e.song.map { .string($0) } ?? .null
                r["src"] = e.src.map { .string($0) } ?? .null
                r["shown"] = e.shown.flatMap { $0.isEmpty ? nil : JSONValue.string(String($0.prefix(600))) } ?? .null
                r["final"] = e.final.flatMap { $0.isEmpty ? nil : JSONValue.string(String($0.prefix(600))) } ?? .null
                r["reason"] = e.why.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null
                return r
            }
            do {
                _ = try await Backend.client.from("muse_events").upsert(rows, onConflict: "id", ignoreDuplicates: true).execute()
                if !queue.isEmpty { flush() }
            } catch {
                if Self.missing(error) { noTable = true } else { queue = batch + queue }
            }
        }
    }

    /// On sign-in: merge the account's history with this device's, and take the newer profile.
    private func pull() async {
        guard uid != nil, !noTable else { return }
        do {
            let res = try await Backend.client.from("muse_events").select("id,song_id,src,outcome,shown,final,reason,created_at")
                .order("created_at", ascending: false).limit(500).execute()
            let rows = (try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? []
            var have = Set(events.map(\.id)), srv = Set<String>()
            for x in rows {
                guard let id = x["id"]?.string else { continue }
                srv.insert(id)
                if !have.contains(id) {
                    have.insert(id)
                    let at = (x["created_at"]?.string).flatMap { ISO8601DateFormatter.fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                    events.append(Event(id: id, song: x["song_id"]?.string, src: x["src"]?.string, o: x["outcome"]?.string ?? "", shown: x["shown"]?.string,
                                        final: x["final"]?.string, why: x["reason"]?.string, at: (at?.timeIntervalSince1970 ?? 0) * 1000))
                }
            }
            events.sort { $0.at < $1.at }
            if events.count > 500 { events.removeFirst(events.count - 500) }
            save()
            let oldest: Double = rows.count >= 500 ? ((rows.last?["created_at"]?.string).flatMap { ISO8601DateFormatter.fractional.date(from: $0) }?.timeIntervalSince1970 ?? 0) * 1000 : 0
            for e in events where !srv.contains(e.id) && e.at >= oldest && !queue.contains(e) { queue.append(e) }
            flush()
            let pr = try await Backend.client.from("muse_profile").select("profile,edited,basis,updated_at").limit(1).execute()
            if let p = ((try? JSONDecoder().decode([[String: JSONValue]].self, from: pr.data)) ?? []).first {
                let t = ((p["updated_at"]?.string).flatMap { ISO8601DateFormatter.fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }?.timeIntervalSince1970 ?? 0) * 1000
                if profile == nil || t > (profile?.at ?? 0) {
                    profile = Profile(text: p["profile"]?.string ?? "", edited: p["edited"]?.bool ?? false, at: t, n: Int(p["basis"]?.number ?? 0))
                    storeProfile(push: false)
                } else if let mine = profile, mine.at > t { storeProfile(push: true) }
            }
            autoProfile()
        } catch {
            if Self.missing(error) { noTable = true }
        }
    }

    // MARK: outcomes

    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "[^a-z0-9' ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Dice overlap of the two lines' words.
    static func sim(_ a: String, _ b: String) -> Double {
        let A = norm(a).split(separator: " ").map(String.init), B = norm(b).split(separator: " ").map(String.init)
        guard !A.isEmpty, !B.isEmpty else { return 0 }
        var m: [String: Int] = [:]
        A.forEach { m[$0, default: 0] += 1 }
        var n = 0
        for w in B where (m[w] ?? 0) > 0 { m[w]! -= 1; n += 1 }
        return 2 * Double(n) / Double(A.count + B.count)
    }

    /// A suggestion went into the song: check on it again in a few minutes.
    func used(_ line: String, src: String, song: String) {
        guard !line.isEmpty else { return }
        pending.append(Pending(id: Self.newID(), song: song, src: src, shown: line, at: Clock.nowMs))
        save()
        autoProfile()
    }

    /// Kept (still there word for word), edited (≥ 0.45 overlap with some line) or deleted, ≥ 3 minutes on.
    func check(force: Bool) {
        guard !pending.isEmpty, let library else { return }
        let now = Clock.nowMs
        var left: [Pending] = []
        for p in pending {
            guard let s = library.song(p.song) else { continue }
            if s.isShared, (s.raw["members"]?.array?.count ?? 0) > 1 { continue }
            if !force && now - p.at < 180_000 { left.append(p); continue }
            let ls = s.lyrics.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("[") }
            let t = Self.norm(p.shown)
            if ls.contains(where: { Self.norm($0) == t }) {
                log(Event(id: Self.newID(), song: p.song, src: p.src, o: "kept", shown: p.shown, at: p.at)); continue
            }
            var best = "", bs = 0.0
            for x in ls { let v = Self.sim(x, p.shown); if v > bs { bs = v; best = x } }
            log(bs >= 0.45 ? Event(id: Self.newID(), song: p.song, src: p.src, o: "edited", shown: p.shown, final: best, at: p.at)
                           : Event(id: Self.newID(), song: p.song, src: p.src, o: "deleted", shown: p.shown, at: p.at))
        }
        pending = left
        save()
    }

    func reject(_ line: String, why: String, src: String, song: String?) {
        log(Event(id: Self.newID(), song: song, src: src, o: "reject", shown: line, why: why.isEmpty ? nil : why, at: Clock.nowMs))
    }

    func passed(_ list: [String], src: String, song: String?) {
        guard !list.isEmpty else { return }
        log(Event(id: Self.newID(), song: song, src: src, o: "passed", shown: list.prefix(6).joined(separator: " / "), at: Clock.nowMs))
    }

    func recent(_ kind: String, _ n: Int) -> [Event] { Array(events.filter { $0.o == kind && !($0.shown ?? "").isEmpty }.suffix(n)) }

    /// Words this writer keeps throwing out (and never keeps).
    func avoid() -> [String] {
        var bad: [String: Int] = [:], good = Set<String>()
        func add(_ t: String?) { for w in Self.norm(t ?? "").split(separator: " ").map(String.init) where w.count > 3 && !RhymeEngine.stop.contains(w) { bad[w, default: 0] += 1 } }
        for e in events {
            if e.o == "deleted" || e.o == "reject" { add(e.shown) }
            else if e.o == "kept" { Self.norm(e.shown ?? "").split(separator: " ").forEach { good.insert(String($0)) } }
            else if e.o == "edited" {
                let f = Set(Self.norm(e.final ?? "").split(separator: " ").map(String.init))
                f.forEach { good.insert($0) }
                for w in Self.norm(e.shown ?? "").split(separator: " ").map(String.init) where !f.contains(w) && w.count > 3 && !RhymeEngine.stop.contains(w) { bad[w, default: 0] += 1 }
            }
        }
        return bad.filter { $0.value >= 2 && !good.contains($0.key) }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(25).map(\.key)
    }

    // MARK: the voice profile (engines.md §2.6)

    private func outcomes() -> Int {
        let intents = (library?.songs ?? []).reduce(0) { $0 + ($1.raw["intents"]?.array?.count ?? 0) }
        return events.filter { $0.o != "passed" }.count + intents
    }

    /// Rebuilds on its own: Pro, ≥16 lyric lines, and no profile yet, 25 new outcomes, or two weeks old.
    func autoProfile() {
        guard !building, session?.plan.isPro == true, AIService.shared.consent == "yes", profile?.edited != true, let library else { return }
        let n = outcomes(), lines = Prompts.catalog(library.songs).count
        guard lines >= 16 else { return }
        let p = profile
        if p == nil || (p?.text ?? "").isEmpty || n - (p?.n ?? 0) >= 25 || (Clock.nowMs - (p?.at ?? 0) > 14 * 864e5 && n > (p?.n ?? 0)) {
            Task { await buildProfile(manual: false) }
        }
    }

    @discardableResult
    func buildProfile(manual: Bool) async -> String? {
        guard !building, let library else { return nil }
        building = true
        defer { building = false }
        let forUid = uid
        let songs = library.songs.filter { !$0.isGuide }.sorted { $0.updated > $1.updated }
        let hooks = Prompts.hookLines(library.songs)
        var sample: [String] = [], budget = 9000
        for s in songs {
            guard budget > 200 else { break }
            let ls = Prompts.llines(s)
            guard !ls.isEmpty else { continue }
            let chunk = String(ls.prefix(16).map { String($0.prefix(200)) }.joined(separator: "\n").prefix(budget))
            budget -= chunk.count
            sample.append("[" + String((s.title.isEmpty ? "Untitled" : s.title).prefix(80)) + "]\n" + chunk)
        }
        let ed = recent("edited", 12), kp = recent("kept", 10)
        let rj = Array(events.filter { ($0.o == "reject" || $0.o == "deleted") && !($0.shown ?? "").isEmpty }.suffix(12))
        var pr = "You are studying a songwriter so a writing assistant can write lines that sound like them and not like generic AI lyrics.\n\nTheir songs (most recent first):\n" + sample.joined(separator: "\n\n")
        if !hooks.isEmpty { pr += "\n\nLines they marked as favourites: " + hooks.map(Prompts.q).joined(separator: " / ") }
        if !ed.isEmpty { pr += "\n\nSuggestions they rewrote (suggested -> their version):\n" + ed.map { Prompts.q($0.shown ?? "") + " -> " + Prompts.q($0.final ?? "") }.joined(separator: "\n") }
        if !kp.isEmpty { pr += "\n\nSuggestions they kept as written:\n" + kp.map { Prompts.q($0.shown ?? "") }.joined(separator: "\n") }
        if !rj.isEmpty { pr += "\n\nSuggestions they threw out:\n" + rj.map { Prompts.q($0.shown ?? "") + (Self.whyLabel($0.why).map { " (" + $0.lowercased() + ")" } ?? "") }.joined(separator: "\n") }
        let mc = Prompts.meantChoices(12, skip: nil, songs: library.songs)
        if !mc.isEmpty { pr += "\n\nLines of theirs a critic questioned that they defended as deliberate (strong evidence of their habits):\n" + mc.map { Prompts.q($0.q) + ($0.why.isEmpty ? "" : " (" + $0.why + ")") }.joined(separator: "\n") }
        let rr = Prompts.rateReads(4, skip: nil, songs: library.songs)
        if !rr.isEmpty { pr += "\n\nHow a critic who read their songs described their writing (secondary evidence; trust the lyrics over it):\n" + rr.map { "- " + $0 }.joined(separator: "\n") }
        pr += "\n\nWrite a voice profile of 120 to 200 words as direct instructions to someone writing lines for them (\"Uses...\", \"Never...\"). Cover: what kind of concrete details and nouns they reach for; how literal or oblique they are; vocabulary and register (slang, swearing, plainness); line length and rhythm; how they rhyme (perfect, slant, internal, or loose); point of view and who they talk to; recurring themes; and what they clearly avoid. Be specific to THIS writer and quote short fragments of their own words as evidence. No praise, no generic advice that would fit any songwriter. Return JSON: {\"profile\":\"...\"}"
        if pr.count > 20000 { pr = String(pr.prefix(19000)) + "\n\nWrite a voice profile of 120 to 200 words as direct instructions. Return JSON: {\"profile\":\"...\"}" }
        guard let r = try? await AIService.shared.json(pr, complex: true, ask: manual), uid == forUid else { return nil }
        let t = (r["profile"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !manual && profile?.edited == true { return nil }
        profile = Profile(text: t, edited: false, at: Clock.nowMs, n: outcomes())
        storeProfile(push: true)
        return t
    }

    /// The writer edited the profile by hand: it's kept until they tap Relearn.
    func editProfile(_ text: String) {
        profile = Profile(text: text, edited: true, at: Clock.nowMs, n: profile?.n ?? outcomes())
        storeProfile(push: true)
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}

// MARK: - prompt parts (engines.md §2.2)

/// Everything a prompt needs to know about where the writer is.
struct PromptEnv {
    var song: Song
    var songs: [Song]
    /// The editor's text right now (plain).
    var text: String
    /// "Listen to the whole song" (Pro).
    var ctxOn: Bool
}

@MainActor
enum Prompts {
    static let voices: [String: String] = [
        "Southern US": "Southern US vernacular: easy drawl rhythm, y'all and fixin' to, porches, back roads, church and heat",
        "Appalachian": "Appalachian mountain speech: old-time phrasing, hollers, creeks, coal and kin",
        "Texas": "Texas plain talk: big-sky imagery, dry humour, highways and dust",
        "Midwest": "plain-spoken Midwestern voice: understated and polite, grain towns, lakes and long winters",
        "New York": "New York voice: fast, blunt and streetwise, subways, stoops and bodegas",
        "West Coast": "California and West Coast voice: laid-back, freeways, sun, smog and the ocean",
        "Atlanta": "Atlanta voice: Southern hip-hop cadence and slang, trap-era imagery, heat and hustle",
        "Chicago": "Chicago voice: grit and wind, the L train, lake winters, blues and drill-era slang",
        "London": "London voice: British spelling, MLE and cockney-leaning slang, the tube, estates and corner shops",
        "Northern England": "Northern English voice: dry wit, terraced streets, pubs, rain, words like \"our kid\" and \"nowt\"",
        "Scottish": "Scottish voice: Scots words used naturally (wee, aye, ken, greet), Glasgow streets and Highland weather",
        "Irish": "Irish voice: lyrical storytelling cadence, Hiberno-English (grand, so it is, craic), sea, pubs and leaving",
        "Australian": "Australian voice: laconic humour, Aussie slang used naturally (arvo, servo, reckon, heaps), suburbs, beach and outback",
        "New Zealand": "New Zealand voice: Kiwi slang (chur, sweet as, yeah nah), understated humour, coast and bush",
        "Caribbean": "Caribbean voice: island rhythm, light patois phrasing used with respect, sea, heat and sound systems",
        "Gen Z": "Gen Z online voice: very online, ironic, group-chat phrasing, lowercase energy",
        "Old soul": "old-soul voice: timeless plain words, no modern slang, could have been written any decade"
    ]

    static let genreDesc: [String: String] = [
        "Pop": "pop — hook-first, broad appeal, radio-ready polish",
        "Bedroom pop": "bedroom pop — lo-fi, intimate, diary-like detail",
        "Indie folk": "indie folk — acoustic, literary, unhurried storytelling",
        "Alt-rock": "alternative rock — guitar-driven, moody dynamics",
        "Pop-punk": "pop-punk — fast, confessional, big shouted choruses",
        "Emo": "emo — raw, melodramatic, painfully specific heartbreak",
        "Synth-pop": "synth-pop — glossy, nostalgic 80s-leaning synths",
        "Dance-pop": "dance-pop — hook-first, built for the floor",
        "Hyperpop": "hyperpop — maximalist, glitchy, internet-native hyperbole",
        "R&B": "R&B — smooth, vocal-run phrasing, intimate groove",
        "Neo-soul": "neo-soul — warm, loose in the pocket, lyrical",
        "Hip-hop": "hip-hop — rhythmic flow, wordplay, punchlines that land",
        "Trap": "trap — dark, minimal, repetition and ad-lib energy",
        "Drill": "drill — menacing, street-specific, deadpan delivery",
        "Country": "country — plainspoken storytelling, small-town detail",
        "Americana": "Americana — roots, weathered, open-road imagery",
        "Gospel": "gospel — devotional, call-and-response, building toward uplift",
        "Blues": "blues — plainspoken hardship, repetition, grit",
        "Afrobeats": "Afrobeats — rhythmic, warm, communal and danceable",
        "Alternative": "alternative — genre-agnostic, idiosyncratic, unconcerned with radio convention"
    ]

    static func q(_ x: String) -> String { "\"" + x.replacingOccurrences(of: "\"", with: "'") + "\"" }

    static func llines(_ s: Song) -> [String] {
        s.lyrics.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("[") }
    }

    static func catalog(_ songs: [Song]) -> [String] { songs.filter { !$0.isGuide }.flatMap(llines) }

    /// Cache key part: the voice, the learned voice and the context toggle (pfk).
    static func pfk(_ env: PromptEnv) -> String {
        "#" + CanonicalJSON.string(.object(env.song.voice)) + "#" + learnedVoice(env) + (env.ctxOn ? "#ctx" : "")
    }

    /// The writer's voice, appended to every generation prompt (pfx).
    static func pfx(_ env: PromptEnv) -> String {
        let p = env.song.voice
        func s(_ k: String) -> String { p[k]?.string ?? "" }
        func arr(_ k: String) -> [String] { (p[k]?.array ?? []).compactMap(\.string) }
        var a: [String] = []
        if s("genre") != "Any" && !s("genre").isEmpty { a.append("Genre: " + (genreDesc[s("genre")] ?? s("genre")) + ".") }
        if s("mood") != "Any" && !s("mood").isEmpty { a.append("Mood: " + s("mood").lowercased() + ".") }
        let dial = s("dial").trimmingCharacters(in: .whitespaces)
        if !dial.isEmpty { a.append("Write specifically in this voice: " + dial + ". Use its real vocabulary, idioms and spelling naturally, never as caricature.") }
        let era = s("era")
        if era != "Any" && !era.isEmpty { a.append(era == "Timeless" ? "Era: timeless, avoid dated references." : "Era: write as if it were the " + era + " (or right " + era.lowercased() + "), with period-true references and slang.") }
        let povs = ["I": "first person (I)", "You": "second person, addressing \"you\"", "We": "first person plural (we)", "Story": "third-person storytelling"]
        if let pv = povs[s("pov")] { a.append("Point of view: " + pv + ".") }
        if s("tense") != "Any" && !s("tense").isEmpty { a.append("Tense: " + s("tense").lowercased() + ".") }
        let themes = arr("tags") + arr("img").map { d in WritingVoice.imagery.first { $0.1 == d }?.0 ?? d }
        if !themes.isEmpty { a.append("Themes and key words the writer wants in this song: " + themes.joined(separator: ", ") + ". Lean toward them and their world when choosing images and words, but only where one fits naturally: never force one into a line, and don't cram several into the same line.") }
        let regs = ["Poetic": "poetic and imagistic, with metaphor and no slang", "Conversational": "natural everyday speech, contractions welcome",
                    "Slang": "casual and slangy like real speech, never forced", "Explicit": "raw and uncensored, with profanity where it lands naturally"]
        a.append("Language: " + (regs[s("reg")] ?? regs["Conversational"]!) + ".")
        a.append("Write like a person drafting by hand, not an AI assistant: skip the tidy \"it's not X, it's Y\" contrast, stock openers like \"in the silence/stillness\" or \"let me take you back\", em-dash asides, and a neatly uplifting resolution by default. Let a line stay plain, unresolved, or a little rough rather than polishing every single one.")
        a.append("Avoid clichés, stock phrases and stock rhyme pairs (fire/desire, heart/apart, eyes/skies, rain/pain, love/above).")
        let refs = s("refs").trimmingCharacters(in: .whitespaces)
        if !refs.isEmpty { a.append("Influences, for tone only: " + refs + ". Never quote or closely paraphrase existing lyrics.") }
        let custom = s("custom").trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { a.append("Extra direction from the writer: " + custom) }
        return " " + a.joined(separator: " ") + learnedVoice(env) + learnedLinePref(env)
    }

    /// Learns from the writer's own songs, only on dimensions they haven't set themselves.
    static func learnedVoice(_ env: PromptEnv) -> String {
        let p = env.song.voice
        let suppressPov = (p["pov"]?.string ?? "Any") != "Any"
        let suppressImg = !(p["img"]?.array ?? []).isEmpty || !(p["tags"]?.array ?? []).isEmpty
        let fp = fingerprint(env.songs, suppressPov: suppressPov, suppressImg: suppressImg)
        let hooks = hookLines(env.songs)
        var parts: [String] = []
        if let fp, !fp.isEmpty { parts.append("From this writer's own past songs: " + fp.joined(separator: "; ") + ".") }
        if !hooks.isEmpty { parts.append("Lines they themselves marked as a favorite \"Hook\", for tone and quality only — never reuse or closely paraphrase them: " + hooks.map { "\"" + $0 + "\"" }.joined(separator: " / ") + ".") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    static func fingerprint(_ songs: [Song], suppressPov: Bool, suppressImg: Bool) -> [String]? {
        let lines = catalog(songs)
        guard lines.count >= 8 else { return nil }
        var totW = 0, totS = 0, pov = ["I": 0, "You": 0, "We": 0], imgCount: [String: Int] = [:], words: [String: Int] = [:]
        let imgRx: [(String, String)] = [("City", "\\b(city|street|block|skyline|subway|downtown)\\b"), ("small town", "\\b(small town|main street|porch|county|back road)\\b"),
            ("nature", "\\b(tree|forest|mountain|river|flower|sky)\\b"), ("coast", "\\b(ocean|beach|wave|tide|coast|shore)\\b"),
            ("the road", "\\b(highway|road|drive|miles|wheel|car)\\b"), ("night", "\\b(night|moon|dark|stars)\\b"), ("home", "\\b(home|house|kitchen|bed|porch)\\b"),
            ("weather", "\\b(rain|storm|snow|sun|wind)\\b"), ("faith", "\\b(god|prayer|faith|heaven|soul)\\b"), ("money", "\\b(money|cash|dollar|broke|rich)\\b"),
            ("party", "\\b(party|dance|drink|club)\\b")]
        func has(_ l: String, _ rx: String) -> Bool { l.range(of: rx, options: [.regularExpression, .caseInsensitive]) != nil }
        for l in lines {
            let w = l.matches(of: #/[A-Za-z']+/#).map { String(l[$0.range]) }
            totW += w.count; totS += RhymeEngine.shared.lineSyllables(l)
            if has(l, "\\b(i|my|me|i'm|i've)\\b") { pov["I"]! += 1 }
            if has(l, "\\b(you|your|you're)\\b") { pov["You"]! += 1 }
            if has(l, "\\b(we|our|we're)\\b") { pov["We"]! += 1 }
            for (k, rx) in imgRx where has(l, rx) { imgCount[k, default: 0] += 1 }
            for x in w { let x = x.lowercased(); if x.count > 3 && !RhymeEngine.stop.contains(x) { words[x, default: 0] += 1 } }
        }
        let n = Double(lines.count)
        let avgW = String(format: "%.1f", Double(totW) / n), avgS = String(format: "%.1f", Double(totS) / n)
        let topImg = imgCount.filter { Double($0.value) >= n * 0.04 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2).map(\.key)
        let topPov = ["I", "You", "We"].max { (pov[$0] ?? 0) < (pov[$1] ?? 0) } ?? "I"
        // ties broken by the word, so the text (part of the Lines cache key) is the same every time
        let topWords = words.filter { $0.value >= 3 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6).map(\.key)
        var bits = ["lines average around \(avgW) words / \(avgS) syllables"]
        if !suppressImg && !topImg.isEmpty { bits.append("imagery leans toward " + topImg.joined(separator: " and ")) }
        let povText = ["I": "first person (I/my)", "You": "second person (you)", "We": "first person plural (we)"]
        if !suppressPov && Double(pov[topPov] ?? 0) > n * 0.15 { bits.append("mostly written in " + povText[topPov]!) }
        if !topWords.isEmpty { bits.append("words they keep coming back to: " + topWords.joined(separator: ", ")) }
        return bits
    }

    /// Lines highlighted as "Hook" (the yellow highlight), newest first, up to 4.
    static func hookLines(_ songs: [Song]) -> [String] {
        var out: [(String, Double)] = []
        let rx = try? NSRegularExpression(pattern: #"<span[^>]*background-color:\s*rgba?\(\s*255,\s*204,\s*0[^>]*>([^<]*)</span>"#, options: .caseInsensitive)
        for s in songs where !s.rich.isEmpty && !s.isGuide {
            let ns = s.rich as NSString
            for m in rx?.matches(in: s.rich, range: NSRange(location: 0, length: ns.length)) ?? [] {
                let t = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && t.count < 120 { out.append((t, s.updated)) }
            }
        }
        out.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var seen = Set<String>(), res: [String] = []
        for o in out where res.count < 4 && !seen.contains(o.0) { seen.insert(o.0); res.append(o.0) }
        return res
    }

    /// "This writer tends to pick near rhymes" once they've picked ≥ 8 (ignored with Perfect only).
    static func learnedLinePref(_ env: PromptEnv) -> String {
        if env.song.voice["strict"]?.bool ?? true { return "" }
        let st = UserDefaults.standard.dictionary(forKey: "songpad:linepref") as? [String: Int] ?? [:]
        let perfect = st["perfect"] ?? 0, near = st["near"] ?? 0, loose = st["loose"] ?? 0
        guard perfect + near + loose >= 8 else { return "" }
        return Double(near + loose) > Double(perfect) * 1.3 ? " This writer tends to pick near/slant rhymes over perfect ones when both are offered — lean that way when it reads naturally." : ""
    }

    static func recordLineAccept(_ type: String) {
        guard !type.isEmpty, type != "new" else { return }
        var st = UserDefaults.standard.dictionary(forKey: "songpad:linepref") as? [String: Int] ?? [:]
        st[type, default: 0] += 1
        UserDefaults.standard.set(st, forKey: "songpad:linepref")
    }

    /// The song around the spot being written (songCtx). Offsets are UTF-16, like the editor's.
    static func songCtx(_ env: PromptEnv, at: Int?, section: [String], rewrite: NSRange? = nil) -> String {
        let v = env.text as NSString
        let at = min(at ?? v.length, v.length)
        if !env.ctxOn {
            var sec = section
            if sec.isEmpty {
                let upto = rewrite.map { r -> Int in
                    let nl = v.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: max(0, r.location - 1)))
                    return nl.location == NSNotFound ? 0 : nl.location + 1
                } ?? at
                sec = Array(v.substring(to: upto).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(2))
            }
            let prev = sec.joined(separator: "\n")
            return prev.isEmpty ? "" : "Lines already written in this section:\n" + prev + "\n\nBefore writing, read these lines and note their tone (the emotional register), their writing style (sentence rhythm, vocabulary, formality) and any imagery or metaphors already in play. What you write must match all three, not just continue the plot."
        }
        var s: String
        if let r = rewrite, r.location + r.length <= v.length {
            s = v.substring(to: r.location) + "⟦" + v.substring(with: r) + "⟧" + v.substring(from: r.location + r.length)
        } else {
            s = v.substring(to: at) + "⟦NEW LINE GOES HERE⟧" + v.substring(from: at)
        }
        if s.count > 5000, let m = s.firstIndex(of: "⟦") {
            let mi = s.distance(from: s.startIndex, to: m)
            let st = max(0, mi - 3500)
            let start = s.index(s.startIndex, offsetBy: st)
            let end = s.index(start, offsetBy: min(5000, s.distance(from: start, to: s.endIndex)))
            s = (st > 0 ? "…" : "") + String(s[start..<end]) + "…"
        }
        let song = env.song
        let head = "Song: " + (song.title.isEmpty ? "Untitled" : song.title) + (song.artist.isEmpty ? "" : " by " + song.artist) + (song.notes.isEmpty ? "" : "\nWriter's notes: " + String(song.notes.prefix(400)))
        return head + "\nFull lyrics so far (" + (rewrite != nil ? "⟦ ⟧ marks the phrase being rewritten" : "⟦NEW LINE GOES HERE⟧ marks where the new line goes") + "):\n" + s + "\n\nBefore writing, read what's there and note its tone, its writing style (sentence rhythm, vocabulary, formality), and any imagery or metaphors already in play. The new text must belong in this song: match that tone, style and imagery, continue its story, keep its characters, tense and point of view consistent, and do not repeat lines or end words already used nearby."
    }

    static func brief(_ s: Song) -> String {
        guard let b = s.raw["brief"]?.object else { return "" }
        var a: [String] = []
        func f(_ k: String) -> String { (b[k]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if !f("who").isEmpty { a.append("Who's singing: " + f("who")) }
        if !f("to").isEmpty { a.append("Singing to: " + f("to")) }
        if !f("where").isEmpty { a.append("Where and when: " + f("where")) }
        if !f("thing").isEmpty { a.append("A real detail from it: " + f("thing")) }
        if !f("more").isEmpty { a.append("Also true: " + f("more")) }
        return a.joined(separator: "\n")
    }

    /// The writer's own lines closest to what they're writing (shared words, then favourite hooks).
    static func myLines(_ env: PromptEnv, section: [String], _ n: Int) -> [String] {
        func words(_ t: String) -> [String] {
            let n = MuseMemory.norm(t)
            return n.matches(of: #/[a-z']+/#).map { String(n[$0.range]) }.filter { $0.count > 3 && !RhymeEngine.stop.contains($0) }
        }
        var q = Set<String>()
        let b = env.song.raw["brief"]?.object
        let briefWords = ["who", "to", "where", "thing"].map { b?[$0]?.string ?? "" }.joined(separator: " ")
        for t in section + [env.song.title, briefWords] { words(t).forEach { q.insert($0) } }
        let hk = Set(hookLines(env.songs).map(MuseMemory.norm))
        var cand: [(String, String, Double, Double)] = []
        for s in env.songs where s.id != env.song.id && !s.lyrics.isEmpty && !s.isGuide {
            for raw in s.lyrics.components(separatedBy: "\n") {
                let l = raw.trimmingCharacters(in: .whitespaces)
                if l.count < 14 || l.count > 110 || l.hasPrefix("[") { continue }
                var sc = Double(Set(words(l)).filter { q.contains($0) }.count)
                if hk.contains(MuseMemory.norm(l)) { sc += 1.5 }
                cand.append((l, s.id, sc, s.updated))
            }
        }
        cand.sort { $0.2 != $1.2 ? $0.2 > $1.2 : $0.3 > $1.3 }
        var out: [String] = [], per: [String: Int] = [:], seen = Set<String>()
        for c in cand where out.count < n {
            let k = MuseMemory.norm(c.0)
            if seen.contains(k) || (per[c.1] ?? 0) >= 3 { continue }
            seen.insert(k); per[c.1, default: 0] += 1; out.append(c.0)
        }
        return out
    }

    struct Intent { var q: String; var why: String; var t: Double }
    static func meantChoices(_ n: Int, skip: String?, songs: [Song]) -> [Intent] {
        var out: [Intent] = []
        for s in songs where s.id != skip && !s.isGuide {
            for x in s.raw["intents"]?.array ?? [] {
                guard let o = x.object, let q = o["quote"]?.string, !q.isEmpty else { continue }
                out.append(Intent(q: q, why: o["why"]?.string ?? "", t: o["t"]?.number ?? 0))
            }
        }
        return Array(out.sorted { $0.t < $1.t }.suffix(n))
    }

    static func rateReads(_ n: Int, skip: String?, songs: [Song]) -> [String] {
        songs.filter { $0.id != skip && !$0.isGuide && !($0.raw["rating"]?["personality"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0.raw["rating"]?["t"]?.number ?? 0) > ($1.raw["rating"]?["t"]?.number ?? 0) }
            .prefix(n).map { String(($0.raw["rating"]?["personality"]?.string ?? "").prefix(300)) }
    }

    /// Everything personal the muse knows, as one block (museCtx).
    static func museCtx(_ env: PromptEnv, section: [String]) -> String {
        let mz = MuseMemory.shared
        var a: [String] = []
        if let p = mz.profile, !p.text.isEmpty { a.append("HOW THIS WRITER WRITES (their voice profile; let it shape style and word choice, not subject matter):\n" + String(p.text.prefix(1400))) }
        let br = brief(env.song)
        if !br.isEmpty { a.append("BACKGROUND ON THIS SONG from the writer. Treat it as what you know, not a checklist: only bring a name, place or detail in when it fits the line and the moment naturally, change or leave it out when it doesn't, and never force it into every suggestion. Most good lines will use none of it:\n" + br) }
        let mine = myLines(env, section: section, 8)
        if !mine.isEmpty { a.append("THE WRITER'S OWN LINES from other songs, that might be close to what they're writing now. Use them only for how this writer sounds (kind of detail, plainness or strangeness, rhythm), not as material to borrow, and ignore any that don't fit this song. Never reuse or paraphrase them:\n" + mine.map(q).joined(separator: "\n")) }
        let mc = meantChoices(8, skip: nil, songs: env.songs)
        if !mc.isEmpty { a.append("LINES THEY DEFENDED as deliberate when a critic questioned them. These are habits of their voice: don't smooth them away, write with them:\n" + mc.map { "- " + q($0.q) + ($0.why.isEmpty ? "" : " (" + $0.why + ")") }.joined(separator: "\n")) }
        if (mz.profile?.text ?? "").isEmpty {
            let rr = rateReads(2, skip: nil, songs: env.songs)
            if !rr.isEmpty { a.append("HOW A CLOSE READER DESCRIBED THEIR WRITING (style only):\n" + rr.map { "- " + $0 }.joined(separator: "\n")) }
        }
        let ed = mz.recent("edited", 6)
        if !ed.isEmpty { a.append("SUGGESTIONS THEY REWROTE, and what they changed them to. Learn the direction of each change and write like the \"after\":\n" + ed.map { "- " + q($0.shown ?? "") + " -> " + q($0.final ?? "") }.joined(separator: "\n")) }
        let kp = mz.recent("kept", 5)
        if !kp.isEmpty { a.append("SUGGESTIONS THEY KEPT word for word (this is the bar):\n" + kp.map { "- " + q($0.shown ?? "") }.joined(separator: "\n")) }
        let rj = mz.events.filter { ($0.o == "reject" || $0.o == "deleted") && !($0.shown ?? "").isEmpty }.suffix(8)
        if !rj.isEmpty { a.append("SUGGESTIONS THEY THREW OUT (don't write anything like these):\n" + rj.map { "- " + q($0.shown ?? "") + (MuseMemory.whyLabel($0.why).map { " (" + $0.lowercased() + ")" } ?? "") }.joined(separator: "\n")) }
        let av = mz.avoid()
        a.append("NEVER USE stock song language: neon lights, shattered hearts, echoes, whispers in the dark, fire and desire, tapestries, symphonies, chasing dreams, rising from the ashes, broken wings, the weight of the world, a light in the dark, lost in your eyes, or anything else a thousand songs already say. Prefer one specific, slightly unexpected concrete detail over a big abstract feeling. Plain, true and particular beats poetic and vague." + (av.isEmpty ? "" : " Also avoid these words this writer keeps rejecting: " + av.joined(separator: ", ") + "."))
        a.append("ORDER OF PRIORITY: first, the lines already written in this song and where they're heading (that is what the new line must fit and continue); second, how this writer sounds; only then the background above, and only where it genuinely fits. Vary the suggestions: don't let one detail or image from the background show up across many of them.")
        return "\n\n" + a.joined(separator: "\n\n")
    }

    // MARK: filtering and judging

    static let clicheRx: [NSRegularExpression] = [
        #"\bneon (light|lights|glow|sign|signs|dream|dreams)\b"#, #"\bshatter(ed|s)? (heart|hearts|glass|pieces|dreams)\b"#, #"\b(heart|hearts) (of gold|of stone|on (my|your) sleeve)\b"#,
        #"\becho(es|ing)? (of|in the|through)\b"#, #"\bwhisper(s|ed|ing)? (in the dark|of the|in my ear|of you)\b"#, #"\btapestry\b"#, #"\bsymphony\b"#, #"\bkaleidoscope\b"#,
        #"\blabyrinth\b"#, #"\bdanc(e|ing) in the rain\b"#, #"\bset (my|your|our) (soul|heart) on fire\b"#, #"\bburning desire\b"#, #"\bfire\b.*\bdesire\b|\bdesire\b.*\bfire\b"#,
        #"\blost in (your|those|her|his) eyes\b"#, #"\bchasing (dreams|the sun|shadows|the light|the stars)\b"#, #"\bbroken wings\b"#, #"\brise from the ashes\b"#, #"\bmidnight hour\b"#,
        #"\bvelvet (sky|night)\b"#, #"\bsilver lining\b"#, #"\bstorm inside\b"#, #"\btears? (fall|falling) like rain\b"#, #"\bheart ?beat(s)? like a drum\b"#, #"\bweight of the world\b"#,
        #"\blight in the dark(ness)?\b"#, #"\bin the dead of (the )?night\b"#, #"\bagainst all odds\b"#, #"\bendless night\b"#, #"\btime stands still\b"#, #"\bfaded memor(y|ies)\b"#,
        #"\bghosts? of (the past|you|us|yesterday)\b"#, #"\bshadows (dance|dancing)\b"#, #"\bstarlit\b"#, #"\bembers? (of|glow)\b"#, #"\bsoul(s)? (on fire|ablaze)\b"#, #"\bunspoken words\b"#,
        #"\bwings to fly\b"#, #"\bspread (my|your) wings\b"#, #"\btouch the sky\b"#, #"\breach for the stars\b"#, #"\bheart of the night\b"#, #"\bbleeding heart\b"#, #"\bscars (that|tell|of)\b"#,
        #"\bcold as ice\b"#, #"\bhold on tight\b"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func isCliche(_ line: String) -> Bool {
        let l = MuseMemory.norm(line)
        let r = NSRange(location: 0, length: (l as NSString).length)
        return clicheRx.contains { $0.firstMatch(in: l, range: r) != nil }
    }

    /// Does this suggestion just repeat a line that's already written?
    static func isEcho(_ k: String, _ prior: [String]) -> Bool {
        let w = k.split(separator: " ").map(String.init)
        guard w.count >= 3 else { return false }
        var grams = Set<String>()
        if w.count >= 4 { for i in 0...(w.count - 4) { grams.insert(w[i..<i + 4].joined(separator: " ")) } }
        let set = Set(w)
        return prior.contains { p in
            let pw = p.split(separator: " ").map(String.init)
            guard pw.count >= 3 else { return false }
            if pw.count >= 4 { for j in 0...(pw.count - 4) where grams.contains(pw[j..<j + 4].joined(separator: " ")) { return true } }
            if pw.last == w.last && w.dropLast().contains(where: { $0.count >= 4 && pw.dropLast().contains($0) }) { return true }
            let ps = Set(pw), inter = set.intersection(ps).count, uni = set.union(ps).count
            return uni > 0 && Double(inter) / Double(uni) >= 0.5 && inter >= 3
        }
    }

    /// Drops stock phrases, rejected words, and anything already in the song or thrown out (mzFilter).
    static func filter<T>(_ items: [T], text: String, min: Int, get: (T) -> String) -> [T] {
        let av = Set(MuseMemory.shared.avoid())
        var have = Set<String>(), prior: [String] = []
        for l in text.components(separatedBy: "\n") {
            let k = MuseMemory.norm(l)
            if !k.isEmpty && !l.trimmingCharacters(in: .whitespaces).hasPrefix("[") { have.insert(k); prior.append(k) }
        }
        let rej = Set(MuseMemory.shared.events.filter { $0.o == "reject" || $0.o == "deleted" }.map { MuseMemory.norm($0.shown ?? "") })
        var ok: [T] = [], weak: [T] = [], echo: [T] = []
        for x in items {
            let t = get(x), k = MuseMemory.norm(t)
            if k.isEmpty || have.contains(k) || rej.contains(k) { continue }
            if isEcho(k, prior) { echo.append(x); continue }
            let bad = isCliche(t) || k.split(separator: " ").contains { av.contains(String($0)) }
            if bad { weak.append(x) } else { ok.append(x) }
        }
        let out = ok.count >= max(1, min) ? ok : ok + weak
        return out.isEmpty ? echo : out
    }

    /// A hard-to-please judge scores each candidate 1–10; nil after 9 s or on failure.
    static func judge(_ cands: [String], env: PromptEnv, section: [String], what: String) async -> [Int: Double]? {
        guard cands.count >= 3 else { return nil }
        let mine = myLines(env, section: section, 4), br = brief(env.song), prof = MuseMemory.shared.profile?.text ?? ""
        var p = "You are a hard-to-please co-writer judging lyric lines for a specific writer. Score each candidate from 1 to 10.\n\n"
        if !prof.isEmpty { p += "The writer's voice:\n" + String(prof.prefix(900)) + "\n\n" }
        if !mine.isEmpty { p += "Lines the writer wrote themselves:\n" + mine.map(q).joined(separator: "\n") + "\n\n" }
        if !br.isEmpty { p += "Background on this song (a line that forces these details in where they don't fit scores lower):\n" + br + "\n\n" }
        if !section.isEmpty { p += "The section they're writing:\n" + section.joined(separator: "\n") + "\n\n" }
        p += "Task: " + what + "\n\nCandidates:\n" + cands.enumerated().map { "\($0.offset). \($0.element)" }.joined(separator: "\n")
        p += "\n\nScore each line the way a great co-writer would, in this order:\n1. Does it make sense? Read it aloud as a sentence. Word salad, mixed metaphors and lines that only exist to land a rhyme score 2 or less.\n2. Is the rhyme earned? If the end word feels forced, or the syntax is bent backwards to reach it (\"the night so cold I'm in\"), score 3 or less.\n3. Does it say something? Filler (\"oh yeah\", \"tonight\" tacked on, \"and I know\", \"you see\") or a line that just restates the one before scores 3 or less.\n4. Is it specific and fresh? A concrete image, an action or a turn of phrase scores high; a stock phrase or a line any songwriter could have written scores 4 or less.\n5. Does it follow on from the line right before it? It should pick up what that line raises (the reason, the alternative, the person, what happens next) so the two read as one thought, in the same voice: same person, tense, plainness and sentence shape. A line that ignores the line before scores 4 or less.\n6. Does it belong here and sound like this writer? Right tone, natural to sing, moves the section forward.\nA line that repeats, rewords or closely echoes a line already in the section scores 1. Use the full range: the best line should score 8 to 10 only if you'd actually keep it. Return ONLY JSON: [{\"i\":0,\"s\":7}, ...] with one entry for every candidate."
        let prompt = p
        return await withTaskGroup(of: [Int: Double]?.self) { g in
            g.addTask { @MainActor in
                guard let r = try? await AIService.shared.json(prompt, tier: "judge", ask: false) else { return nil }
                var out: [Int: Double] = [:]
                for x in r.array ?? [] { if let i = x["i"]?.number, let s = x["s"]?.number { out[Int(i)] = s } }
                return out.isEmpty ? nil : out
            }
            g.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }

    // MARK: Rate's context

    static func writerContext(_ env: PromptEnv) -> String {
        var out = ""
        let others = env.songs.filter { $0.id != env.song.id && !$0.isGuide && !$0.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.updated > $1.updated }.prefix(6)
        if !others.isEmpty { out += "\n\nOther songs by this writer (for their style only, do not rate these):\n" + others.map { "- " + ($0.title.isEmpty ? "Untitled" : $0.title) + ": " + llines($0).prefix(6).joined(separator: " / ") }.joined(separator: "\n") }
        if let p = MuseMemory.shared.profile, !p.text.isEmpty { out += "\n\nHow this writer writes (their voice profile, learned from all their songs and from which suggestions they kept, rewrote and threw out; judge against this voice, not a generic ideal):\n" + String(p.text.prefix(1400)) }
        let w = rateReads(6, skip: env.song.id, songs: env.songs)
        if !w.isEmpty { out += "\n\nWhat earlier readings learned about this writer:\n" + w.map { "- " + $0 }.joined(separator: "\n") }
        let kept = meantChoices(10, skip: env.song.id, songs: env.songs)
        if !kept.isEmpty { out += "\n\nLines in other songs this writer told you were deliberate when they were questioned (their habits, not mistakes):\n" + kept.map { "- " + q($0.q) + ($0.why.isEmpty ? "" : " (" + $0.why + ")") }.joined(separator: "\n") }
        let br = brief(env.song)
        if !br.isEmpty { out += "\n\nWhat the writer told you about this song (use it to understand what it's going for and who is singing to whom; never mark a line down for not using these details):\n" + br }
        return out
    }

    static func intentText(_ s: Song) -> String {
        let a = (s.raw["intents"]?.array ?? []).compactMap(\.object)
        guard !a.isEmpty else { return "" }
        return "\n\nThe writer has told you these choices are deliberate. Respect them: do not raise them as issues again, and re-judge the scores they affect with the intent in mind. If the intent makes the line work, credit it; only mention one if it truly undermines something else, and then gently:\n" + a.map { x in
            let why = x["why"]?.string ?? ""
            return "- \"" + (x["quote"]?.string ?? "") + "\"" + (why.isEmpty ? " (no reason given)" : " (writer: " + why + ")")
        }.joined(separator: "\n")
    }
}
