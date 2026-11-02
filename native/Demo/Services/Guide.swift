import Foundation

/// The built-in "How *[demo] works" song every library starts with (spec §1.8, the web's guideSong / seedGuide).
/// Fixed id and an old `updated` on purpose: any real edit, or a delete from another device, wins.
/// Delete it and it stays deleted. A newer GUIDE_V only replaces an untouched copy.
enum Guide {
    static let version = 5
    static let id = "5f1d0c2e-6a8b-4c3d-9e7f-0a1b2c3d4e5f"
    /// Date.UTC(2026, 10, 2, 12): 2 Nov 2026 12:00 UTC
    static let at: Double = 1_793_620_800_000

    /// The words and pictures live in GuideContent.swift, made by scripts/guide/build.js (the web uses the same).
    static var song: Song {
        Song(raw: [
            "id": .string(id), "guide": true, "guideAt": .number(at), "title": "How *[demo] works",
            "lyrics": .string(GuideContent.text), "rich": .string(GuideContent.rich), "chords": "", "key": "", "bpm": "", "capo": "", "time": "",
            "tuning": "", "status": "Idea", "folder": "", "notes": "", "artist": "",
            "created": .number(at), "updated": .number(at)
        ])
    }

    /// The guide is read with its pictures while its words are still the guide's own (the web's isGuideView).
    static func isView(_ s: Song) -> Bool {
        s.id == id && s.lyrics.replacingOccurrences(of: "\r\n", with: "\n") == GuideContent.text
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
