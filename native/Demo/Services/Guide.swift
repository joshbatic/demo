import Foundation

/// The built-in "How *[demo] works" song every library starts with (spec §1.8, the web's guideSong / seedGuide).
/// Fixed id and an old `updated` on purpose: any real edit, or a delete from another device, wins.
/// Delete it and it stays deleted. A newer GUIDE_V only replaces an untouched copy.
enum Guide {
    static let version = 4
    static let id = "5f1d0c2e-6a8b-4c3d-9e7f-0a1b2c3d4e5f"
    /// Date.UTC(2026, 9, 17, 2): 17 Oct 2026 02:00 UTC
    static let at: Double = 1_792_202_400_000

    static let lines: [String] = [
        "[Start here]",
        "This is a song like any other. Read it, edit it, delete it when you’re done.",
        "Everything saves as you type, and syncs to every device you’re signed in on.",
        "",
        "[Writing]",
        "Each line here is a lyric line.",
        "Put a section name on its own line in square brackets, like [Verse] or [Bridge].",
        "Write your chorus once under [Chorus]. Next time, type [Chorus] and press Enter: it fills itself in.",
        "Select words to make them bold, colour them, or highlight them.",
        "{Highlights mark a Hook,} a line to Rework, or an Idea.",
        "",
        "[Rhymes]",
        "The rhyme bar suggests rhymes for the word you just wrote. Tap one to use it.",
        "Switch it to Perfect, Near, Phrases, Synonyms, Opposites, Define and more.",
        "Tap the handle on top of the bar to open the Dictionary and look up any word.",
        "Rhyme map colours the words that rhyme. Syllable counts shows how long each line is.",
        "",
        "[When you’re stuck]",
        "Lines writes rhyming next lines in your voice.",
        "Muse deals out quick prompts when the page is blank.",
        "Writing voice sets how you write: genre, mood and style.",
        "Listen to the whole song makes every suggestion fit the song so far.",
        "Rate gives an honest co-writer’s read, with a score and notes you can act on.",
        "",
        "[Music]",
        "In Details, add chords, key, tempo, tuning and a status.",
        "Perform turns the song into a scrolling teleprompter, with speed and text size.",
        "",
        "[Audio & release]",
        "In Details › Audio, add versions of the song: voice memo, demo, mix, master. Tick the current one.",
        "Sync Lyrics listens to the current version and times every line for you.",
        "Play with Lyrics plays it with each line lighting up in time. Tap a line to jump there.",
        "Export .lrc saves the timed lyrics for streaming services and distributors.",
        "Stems, artwork and session files can live with the song too.",
        "Details › Credits keeps writers and their splits, plus ISRC, UPC, release date and label.",
        "",
        "[Keeping it safe]",
        "Save a Version before big changes, and restore it any time.",
        "Clean up tidies case, spacing and section tags, ready for streaming services.",
        "Copy Lyrics from Details, or export every song from Account.",
        "On Mac, songs are also saved as files in Documents › [demo] Songs.",
        "",
        "[Organising]",
        "Make folders, and drag songs between them.",
        "Swipe a song left in the list to pin it or delete it.",
        "Ideas, at the top of your songs, is a quick jot for lines, ideas and concepts. Type and press Return.",
        "",
        "[Writing together]",
        "Choose a username in Account so co-writers can find you.",
        "Invite them from Details › Collaborators. Shared songs stay in sync for everyone.",
        "Songs you mark Finished show up under Credits in Account.",
    ]

    static var song: Song {
        let lyrics = lines.map { $0.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "") }.joined(separator: "\n")
        let rich = lines.map { l -> String in
            if l.range(of: #"^\[[^\]]+\]$"#, options: .regularExpression) != nil {
                return "<span style=\"font-weight: bold; color: #8E8E96;\">" + esc(l) + "</span>"
            }
            // only the first {…} becomes the yellow Hook highlight, like the web's replace()
            let e = esc(l)
            guard let r = e.range(of: #"\{([^}]*)\}"#, options: .regularExpression) else { return e }
            let inner = String(e[r].dropFirst().dropLast())
            return e.replacingCharacters(in: r, with: "<span style=\"background-color: rgba(255, 204, 0, 0.38);\">" + inner + "</span>")
        }.joined(separator: "<br>")
        return Song(raw: [
            "id": .string(id), "guide": true, "guideAt": .number(at), "title": "How *[demo] works",
            "lyrics": .string(lyrics), "rich": .string(rich), "chords": "", "key": "", "bpm": "", "capo": "", "time": "",
            "tuning": "", "status": "Idea", "folder": "", "notes": "", "artist": "",
            "created": .number(at), "updated": .number(at)
        ])
    }

    /// The web's esc(): &, < and >.
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// seedGuide: once per library (account). Returns the songs to use.
    static func seed(_ songs: [Song], uid: String) -> [Song] {
        let key = "songpad:guide:songpad:v1:" + uid
        let had = UserDefaults.standard.integer(forKey: key)
        guard had < version else { return songs }
        var out = songs
        if let i = out.firstIndex(where: { $0.id == id }) {
            let ex = out[i]
            let exAt = ex.raw["guideAt"]?.number ?? 0
            if ex.updated == exAt && exAt < at { out[i] = song }
        } else if had == 0 {
            out.append(song)
        }
        UserDefaults.standard.set(version, forKey: key)
        return out
    }
}
