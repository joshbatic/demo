import Foundation

/// An album (or EP, or single): its own row in `albums`, synced per row, last writer wins on `updated`.
/// Its songs say which album they're in themselves (`song.album`, ordered by `song.track`), so a song
/// moving in or out merges like any other edit. Kept whole as JSON, like a song, so keys from newer
/// apps survive. See supabase/albums.sql.
nonisolated struct Album: Identifiable, Hashable {
    var raw: [String: JSONValue]

    static let kinds = ["Album", "EP", "Single"]

    static func new(artist: String, now: Double = Clock.nowMs) -> Album {
        Album(raw: [
            "id": .string(UUID().uuidString.lowercased()), "title": "", "kind": "Album",
            "year": .string(String(Calendar.current.component(.year, from: Date()))),
            "artist": .string(artist), "art": "", "updated": .number(now)
        ])
    }

    var id: String { raw["id"]?.string ?? "" }
    private func str(_ k: String) -> String { raw[k]?.string ?? "" }
    var title: String { get { str("title") } set { raw["title"] = .string(newValue) } }
    var kind: String { get { Album.kinds.contains(str("kind")) ? str("kind") : "Album" } set { raw["kind"] = .string(newValue) } }
    var year: String { get { str("year") } set { raw["year"] = .string(newValue) } }
    var artist: String { get { str("artist") } set { raw["artist"] = .string(newValue) } }
    var updated: Double { get { raw["updated"]?.number ?? 0 } set { raw["updated"] = .number(newValue) } }
    var deleted: Bool { raw["deleted"]?.bool ?? false }
    mutating func touch() { updated = Clock.nowMs }

    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled \(kind)" : title }

    /// The artwork, only when it's a real image data URL (the songs' artOk rule).
    var artDataURL: String? {
        guard let a = raw["art"]?.string, !a.isEmpty,
              a.range(of: #"^data:image/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/=]+$"#, options: .regularExpression) != nil else { return nil }
        return a
    }
    mutating func setArt(_ a: String) { raw["art"] = .string(a) }

    /// A deleted album stays as a small tombstone row, so every device learns it's gone.
    static func tombstone(_ id: String) -> Album { Album(raw: ["id": .string(id), "deleted": true, "updated": .number(Clock.nowMs)]) }
}

nonisolated extension Song {
    /// The album this song is in ("" for none) and its place there.
    var albumID: String { get { raw["album"]?.string ?? "" } set { raw["album"] = .string(newValue) } }
    var track: Double { get { raw["track"]?.number ?? 0 } set { raw["track"] = .number(newValue) } }
    var isFinished: Bool { status == "Finished" }
}
