import Foundation

/// A song, kept as its full JSON object (see spec §1.1) with typed accessors on top.
/// Every key the native app doesn't use is carried along untouched, because the web and
/// Mac apps write the same records and anything dropped here would vanish for everyone.
nonisolated struct Song: Identifiable, Hashable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) { self.raw = raw }

    /// A brand-new song, shaped the way the web app makes them.
    static func new(artist: String, folder: String = "", now: Double = Clock.nowMs) -> Song {
        Song(raw: [
            "id": .string(UUID().uuidString.lowercased()),
            "title": "", "lyrics": "", "rich": "", "chords": "", "notes": "",
            "artist": .string(artist), "folder": .string(folder), "status": "Idea",
            "key": "", "bpm": "", "tuning": "", "capo": "", "time": "",
            "pf": .object(WritingVoice.lastUsed),
            "updated": .number(now)
        ])
    }

    var id: String { raw["id"]?.string ?? "" }

    private func str(_ k: String) -> String { raw[k]?.string ?? "" }
    private mutating func set(_ k: String, _ v: String) { raw[k] = .string(v) }

    var title: String { get { str("title") } set { set("title", newValue) } }
    var lyrics: String { get { str("lyrics") } set { set("lyrics", newValue) } }
    /// The formatted copy of the lyrics (an HTML subset, see RichText). Display prefers it.
    var rich: String { get { str("rich") } set { set("rich", newValue) } }
    var chords: String { get { str("chords") } set { set("chords", newValue) } }
    var notes: String { get { str("notes") } set { set("notes", newValue) } }
    var artist: String { get { str("artist") } set { set("artist", newValue) } }
    var folder: String { get { str("folder") } set { set("folder", newValue) } }
    var status: String { get { raw["status"]?.string ?? "Idea" } set { set("status", newValue) } }
    var key: String { get { str("key") } set { set("key", newValue) } }
    /// Sometimes a number in the data; always written back as a string.
    var bpm: String { get { str("bpm") } set { set("bpm", newValue) } }
    var tuning: String { get { str("tuning") } set { set("tuning", newValue) } }

    /// The conflict clock: ms since 1970, bumped on every change the user can see.
    var updated: Double { get { raw["updated"]?.number ?? 0 } set { raw["updated"] = .number(newValue) } }
    mutating func touch() { updated = Clock.nowMs }

    var isShared: Bool { raw["shared"]?.bool ?? false }
    var owner: String { str("owner") }
    var isPlaceholder: Bool { raw["ph"] != nil && !(raw["ph"]?.isNull ?? true) }
    var isGuide: Bool { raw["guide"]?.bool ?? false }

    /// Cover art, only when it's a real image data URL (spec: artOk).
    var artDataURL: String? {
        guard let a = raw["art"]?.string, !a.isEmpty,
              a.range(of: #"^data:image/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/=]+$"#, options: .regularExpression) != nil else { return nil }
        return a
    }

    var audioCount: Int { raw["audio"]?.array?.count ?? 0 }

    /// Lines of lyrics for previews: no blanks, no [Section] tags.
    var lyricLines: [String] {
        lyrics.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
    }

    /// What the list shows as the name: the title, else the first lyric line, else "New Song".
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return lyricLines.first ?? "New Song"
    }

    /// The list's second line: the first lyric line (or the second when the first is standing in as the title).
    var previewLine: String {
        if isPlaceholder && title.isEmpty && lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Empty folder. Tap to write its first song, or drag songs here."
        }
        let l = lyricLines
        let line = title.trimmingCharacters(in: .whitespaces).isEmpty ? (l.count > 1 ? l[1] : nil) : l.first
        return line ?? "No lyrics yet"
    }

    /// True when leaving it should throw it away (spec §1.6: an untouched new song).
    var isEmptyDraft: Bool {
        !isShared && title.isEmpty && lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chords.isEmpty && notes.isEmpty && artDataURL == nil && audioCount == 0
            && (raw["files"]?.array?.isEmpty ?? true) && (raw["credits"]?.array?.isEmpty ?? true)
            && key.isEmpty && bpm.isEmpty && folder.isEmpty
    }

    /// Plain text edits must also replace the formatted copy (spec §1.2), or other devices keep the old text.
    mutating func setText(lyrics newLyrics: String, rich newRich: String) {
        lyrics = newLyrics
        rich = newRich
        if isPlaceholder && (!title.isEmpty || !newLyrics.isEmpty) { raw.removeValue(forKey: "ph") }
        touch()
    }

    /// The object as it goes to the cloud: device-only `_` keys removed.
    var cloudJSON: JSONValue { .object(raw.filter { !$0.key.hasPrefix("_") }) }
}

nonisolated struct Idea: Identifiable, Hashable {
    var raw: [String: JSONValue]
    var id: String { raw["id"]?.string ?? "" }
    var text: String { get { raw["text"]?.string ?? "" } set { raw["text"] = .string(newValue) } }
    var kind: String { raw["kind"]?.string ?? "line" }
    var updated: Double { get { raw["updated"]?.number ?? 0 } set { raw["updated"] = .number(newValue) } }
    var hasMemo: Bool { raw["memo"]?.object != nil }
    var cloudJSON: JSONValue { .object(raw.filter { !$0.key.hasPrefix("_") }) }

    static func new(text: String) -> Idea {
        let now = Clock.nowMs
        return Idea(raw: ["id": .string(UUID().uuidString.lowercased()), "text": .string(text), "kind": "line", "tags": .array([]), "created": .number(now), "updated": .number(now)])
    }
}

/// The writing voice defaults (spec §1.3, mkPF).
nonisolated enum WritingVoice {
    static let defaults: [String: JSONValue] = [
        "genre": "Any", "mood": "Any", "voice": "Neutral", "dial": "", "era": "Any", "pov": "Any", "tense": "Any",
        "img": .array([]), "dev": .array([]), "tags": .array([]), "reg": "Conversational", "strict": true, "cliche": false, "refs": "", "custom": ""
    ]
}

nonisolated enum Clock {
    /// Milliseconds since 1970, the same clock the web app uses for `updated`.
    static var nowMs: Double { (Date().timeIntervalSince1970 * 1000).rounded() }
}
