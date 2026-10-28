import Foundation

/// The parts of a song the Details and Writing voice sheets edit (data spec §1.1, §1.3).
nonisolated extension Song {

    // MARK: versions (spec §4.11)

    struct Version: Identifiable, Hashable {
        var t: Double
        var lyrics: String
        var rich: String
        var label: String
        var id: Double { t }
        var words: Int { lyrics.matches(of: #/[A-Za-z0-9']+/#).count }
    }

    var versions: [Version] {
        (raw["versions"]?.array ?? []).compactMap { v in
            guard let o = v.object else { return nil }
            return Version(t: o["t"]?.number ?? 0, lyrics: o["lyrics"]?.string ?? "", rich: o["rich"]?.string ?? "", label: o["label"]?.string ?? "")
        }
    }

    /// Saves the current text as a version unless it's the same as the last one; at most 30. Doesn't bump `updated`.
    @discardableResult
    mutating func snap(_ label: String) -> Bool {
        var list = raw["versions"]?.array ?? []
        if let last = list.last?.object, (last["lyrics"]?.string ?? "") == lyrics, (last["rich"]?.string ?? "") == rich { return false }
        list.append(.object(["t": .number(Clock.nowMs), "lyrics": .string(lyrics), "rich": .string(rich), "label": .string(label)]))
        if list.count > 30 { list.removeFirst(list.count - 30) }
        raw["versions"] = .array(list)
        return true
    }

    /// On opening a song: an "Auto" version when the last one is over two hours old.
    mutating func autoSnap() -> Bool {
        guard !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let last = versions.last, Clock.nowMs - last.t <= 2 * 3600 * 1000 { return false }
        return snap("Auto")
    }

    // MARK: credits and release (spec §2.1 Credits pane)

    struct Credit: Hashable, Identifiable {
        var id = UUID()
        var name: String
        var role: String
        var split: String
        static let roles = ["Writer", "Composer", "Lyricist", "Producer", "Performer", "Featured artist", "Mix engineer", "Mastering engineer", "Other"]
        static let splitRoles: Set<String> = ["Writer", "Composer", "Lyricist"]
        var hasSplit: Bool { Self.splitRoles.contains(role) }
    }

    var credits: [Credit] {
        get {
            (raw["credits"]?.array ?? []).compactMap { v in
                guard let o = v.object else { return nil }
                let split: String = o["split"]?.string ?? o["split"]?.number.map { n in n == n.rounded() ? String(Int(n)) : String(n) } ?? ""
                return Credit(name: o["name"]?.string ?? "", role: o["role"]?.string ?? "Writer", split: split)
            }
        }
        set {
            raw["credits"] = .array(newValue.map { .object(["name": .string($0.name), "role": .string($0.role), "split": .string($0.hasSplit ? $0.split : "")]) })
        }
    }

    func releaseField(_ k: String) -> String { raw["release"]?[k]?.string ?? "" }
    var releaseExplicit: Bool { raw["release"]?["explicit"]?.bool ?? false }
    mutating func setRelease(_ k: String, _ v: JSONValue) {
        var o = raw["release"]?.object ?? [:]
        o[k] = v
        raw["release"] = .object(o)
    }

    // MARK: writing voice (spec §1.3)

    /// The song's voice, filled out with the defaults (mkPF).
    var voice: [String: JSONValue] {
        var p = WritingVoice.defaults
        for (k, v) in raw["pf"]?.object ?? [:] where p[k] != nil { p[k] = v }
        return p
    }
}

nonisolated extension WritingVoice {
    /// The last voice used: the default for new songs (localStorage `songpad:prefs`).
    static var lastUsed: [String: JSONValue] {
        get {
            var p = defaults
            if let d = UserDefaults.standard.data(forKey: "songpad:prefs"),
               let o = try? JSONDecoder().decode([String: JSONValue].self, from: d) {
                for (k, v) in o where p[k] != nil { p[k] = v }
            }
            return p
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: "songpad:prefs") }
        }
    }

    /// The fields that light the gear's dot when they differ from the defaults (pfTouched).
    static let touchedKeys = ["genre", "mood", "dial", "img", "tags"]
    static func isTouched(_ p: [String: JSONValue]) -> Bool {
        touchedKeys.contains { CanonicalJSON.string(p[$0] ?? .null) != CanonicalJSON.string(defaults[$0] ?? .null) }
    }

    static let genres = ["Any", "Pop", "Bedroom pop", "Indie folk", "Alt-rock", "Alternative", "Pop-punk", "Emo", "Synth-pop", "Dance-pop", "Hyperpop", "R&B", "Neo-soul", "Hip-hop", "Trap", "Drill", "Country", "Americana", "Gospel", "Blues", "Afrobeats"]
    static let moods = ["Any", "Heartbreak", "Longing", "Bittersweet", "Hopeful", "Euphoric", "Romantic", "Infatuated", "Jealous", "Angry", "Defiant", "Grief", "Regretful", "Lonely", "Nostalgic", "Wistful", "Playful", "Confident", "Empowered", "Anxious", "Numb", "Dark", "Tender"]
    static let registers = ["Poetic", "Conversational", "Slang", "Explicit"]
    static let povs: [(String, String)] = [("Any", "Any"), ("I", "I"), ("You", "You"), ("We", "We"), ("They", "Story")]
    static let tenses = ["Any", "Present", "Past"]
    /// (label, the description that's stored)
    static let imagery: [(String, String)] = [
        ("City streets", "city streets, skylines, subway platforms"),
        ("Small town", "small-town main streets, porches, diners"),
        ("Suburbs", "suburbs, cul-de-sacs, backyard pools"),
        ("Nature", "forests, mountains, rivers, wide open land"),
        ("Coast", "ocean, tide, salt air, boardwalks"),
        ("Desert", "desert heat, dust, long empty highway"),
        ("Open road", "highways, gas stations, motel signs, headlights"),
        ("Night", "3am, streetlights, empty parking lots"),
        ("Home", "kitchens, bedrooms, worn furniture, family photos"),
        ("Weather", "rain, storms, snow, change in the air"),
        ("Faith", "church pews, prayer, hymns, searching for meaning"),
        ("Money", "debt, rent, dead-end jobs, wanting more"),
        ("Nightlife", "clubs, neon, bass through the floor, strangers"),
        ("Technology", "phone screens, texts left on read, blue light at 2am"),
        ("Nostalgia objects", "polaroids, mixtapes, old voicemails, handwriting"),
        ("Domestic", "laundry, dishes, small routines, quiet arguments"),
        ("Work", "clocking in, tired hands, the grind")
    ]
    static let techniques: [(String, String)] = [
        ("Concrete detail", "concrete, specific physical detail over vague abstraction"),
        ("Metaphor", "metaphor and extended imagery"),
        ("Simile", "simile, explicit like/as comparisons"),
        ("Internal rhyme", "internal rhyme within the line, not just at the end"),
        ("Wordplay", "wordplay, puns, double meanings"),
        ("Repetition", "repetition and refrain that builds"),
        ("Dialogue", "direct quoted dialogue"),
        ("Second person", "direct address to \"you\""),
        ("Specific names", "specific real names, places and brands rather than generic ones"),
        ("List structure", "a list or catalog structure, naming several things in a row"),
        ("Understatement", "understatement, saying less than is felt"),
        ("Callback", "a callback line that returns changed by the end")
    ]
    static let fineTuneKeys = ["pov", "tense", "strict", "refs", "custom"]
    /// Quick themes offered under "Themes and key words" until the song gives its own.
    static let starterThemes = ["Late nights", "Leaving", "Home", "Small town", "The city", "Open road", "The coast", "Weather", "Money", "Faith", "Phones and texts", "Growing up", "First love", "Moving on", "Family", "Friends", "Summer", "Winter"]
    /// Words from the song worth offering as tags: repeated or in the title, not filler, most used first.
    static func suggestedTags(title: String, lyrics: String, have: [String]) -> [String] {
        let extra: Set<String> = ["know", "want", "said", "gonna", "wanna", "gotta", "got", "get", "all", "out", "down", "one", "now", "here", "been", "back", "never", "ever", "every", "some", "more", "only", "into", "over", "still", "too", "again", "yeah", "ooh", "really", "think", "chorus", "verse", "bridge", "intro", "outro", "pre", "about", "always", "maybe", "make", "made", "take", "come", "going", "thing", "things", "around", "through", "because", "cause", "without", "even", "much", "well", "tell", "need", "tonight", "baby"]
        let lower = Set(have.map { $0.lowercased() })
        func words(_ t: String) -> [String] {
            t.lowercased().replacingOccurrences(of: "’", with: "'").components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")).replacingOccurrences(of: "'", with: "") }
                .filter { $0.count >= 4 && !RhymeEngine.stop.contains($0) && !extra.contains($0) }
        }
        let body = lyrics.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }.joined(separator: "\n")
        var count: [String: Int] = [:], first: [String: Int] = [:]
        for (i, w) in words(body).enumerated() { count[w, default: 0] += 1; if first[w] == nil { first[w] = i } }
        let inTitle = Set(words(title))
        for w in inTitle { count[w, default: 0] += 2; if first[w] == nil { first[w] = -1 } }
        let mine = count.filter { $0.value >= 2 && !lower.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : (first[$0.key] ?? 0) < (first[$1.key] ?? 0) }
            .prefix(6).map(\.key)
        let starters = starterThemes.filter { !lower.contains($0.lowercased()) }
        return Array((mine + starters).prefix(14))
    }
}

/// Chord chips for a key (chordChips): the scale's chords, the V7 (or V in minor), then / and |.
nonisolated enum ChordChips {
    static let notes = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static func chips(key: String) -> [String] {
        let k = key.isEmpty ? "C" : key
        let minor = k.hasSuffix("m")
        let r = notes.firstIndex(of: k.replacingOccurrences(of: "m", with: "")) ?? 0
        let iv = minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        let q = minor ? ["m", "dim", "", "m", "m", "", ""] : ["", "m", "m", "", "", "m", "dim"]
        var a = iv.enumerated().map { notes[(r + $0.element) % 12] + q[$0.offset] }
        a.append(notes[(r + 7) % 12] + (minor ? "" : "7"))
        return a + ["/", "|"]
    }
}
