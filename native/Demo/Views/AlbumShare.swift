import SwiftUI
import UIKit
import Supabase

/// An album's share link (listen.hellodemo.app/<id>), the same page the web makes: the artwork, title and artist on the
/// album's colours, and the tracklist, where each song opens its own link. Making or updating it makes or updates every
/// song's link too, so each one says which album it's from and links back (www/index.html albLinkMake).
@MainActor
enum AlbumShare {
    /// This account's link for the album, if it made one: {id, at, by, exp}.
    static func mine(_ a: Album, uid: String?) -> [String: JSONValue]? {
        guard let uid, let r = a.raw["share"]?.object, r["by"]?.string == uid, r["id"]?.string?.isEmpty == false else { return nil }
        return r
    }

    private static func render(_ v: some View, scale: CGFloat) -> UIImage? {
        let r = ImageRenderer(content: v.environment(\.colorScheme, .light))
        r.scale = scale
        return r.uiImage
    }

    private static func k(_ bg: SharePalette.Background) -> String {
        let a = bg.top
        return "\(Int(a.h.rounded())),\(a.s < 0.14 ? 8 : 40)%,15%"
    }

    /// Makes (or updates) the link; `step(i, n)` says which song it's on.
    static func make(_ a: Album, artist: String, uid: String, pro: Bool, library: LibraryStore, step: (Int, Int) -> Void) async throws -> String {
        let id = mine(a, uid: uid)?["id"]?.string ?? ShareLink_.newID()
        let tracks = library.albumSongs(a.id)
        let alb: [String: JSONValue] = ["id": .string(id), "title": .string(a.title.isEmpty ? "Untitled \(a.kind)" : a.title)]
        // one song at a time: each uploads its artwork (and its audio, on Pro)
        var links: [String] = []
        for (i, s0) in tracks.enumerated() {
            step(i + 1, tracks.count)
            let s = library.song(s0.id) ?? s0
            let pal = SharePalette.palette(s)
            let bg = SharePalette.background(pal, 0)
            let audio = pro ? s.currentAudio : nil
            let art = library.coverArt(s).flatMap(CoverView.image) ?? render(CoverView(song: s, size: 480, square: true), scale: 1)
            let og = render(ShareCard(song: s, bg: bg, audio: audio, lyrics: false, width: 1200 / 2.85)
                                .frame(width: 1200 / 2.85, height: 630 / 2.85), scale: 2.85)
            let sid = s.raw["shares"]?[uid]?["id"]?.string ?? ShareLink_.newID()
            try await ShareLink_.publish(s, id: sid, uid: uid, bg: bg, audio: audio, art: art, og: og, alb: alb, library: library)
            links.append(sid)
        }
        // the album page itself
        let bucket = Backend.client.storage.from("shares")
        let folder = "\(uid)/\(id)"
        let v = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let bg = AlbumLook(a).bg
        let artImg = a.artDataURL.flatMap(CoverView.image) ?? render(AlbumArt(album: a, size: 480, radius: 0), scale: 1)
        var data: [String: JSONValue] = [
            "v": .number(1), "type": "album", "title": .string(a.title), "artist": .string(artist),
            "kind": .string(a.kind), "year": .string(a.year),
            "bg": .object(["top": .string(SharePalette.css(bg.top)), "bot": .string(SharePalette.css(bg.bot)),
                           "glow": .string(SharePalette.css(bg.glow)), "k": .string(k(bg))]),
        ]
        let name = "art-\(v).jpg"
        if let jpg = artImg?.jpegData(compressionQuality: 0.9) {
            let path = folder + "/" + name
            _ = try await bucket.upload(path, data: jpg, options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: true))
            data["art"] = .string(try bucket.getPublicURL(path: path, download: nil as String?).absoluteString)
        }
        data["tracks"] = .array(tracks.enumerated().map { i, s in
            let ls = s.lyricLines
            let hasTitle = !s.title.trimmingCharacters(in: .whitespaces).isEmpty
            let line = hasTitle ? ls.first : (ls.count > 1 ? ls[1] : nil)
            return .object(["title": .string(s.displayTitle), "line": .string(line ?? ""), "link": .string(i < links.count ? links[i] : "")])
        })
        let row: [String: JSONValue] = ["id": .string(id), "owner": .string(uid), "song_id": .string("album:" + a.id), "data": .object(data),
                                        "updated_at": .string(ISO8601DateFormatter().string(from: Date()))]
        _ = try await Backend.client.from("shares").upsert(row, onConflict: "id").execute()
        // tidy: artwork from older versions of this link
        if let files = try? await bucket.list(path: folder) {
            let old = files.map(\.name).filter { $0 != name }.map { folder + "/" + $0 }
            if !old.isEmpty { _ = try? await bucket.remove(paths: old) }
        }
        if var now = library.album(a.id) {
            now.raw["share"] = .object(["id": .string(id), "at": .number(Clock.nowMs), "by": .string(uid), "exp": .number(Clock.nowMs + 30 * 86_400_000)])
            now.touch()
            library.putAlbum(now)
        }
        return id
    }

    /// Stops the album link. Each song's own link keeps working.
    static func stop(_ a: Album, uid: String, library: LibraryStore) async throws {
        guard let id = mine(a, uid: uid)?["id"]?.string else { return }
        _ = try await Backend.client.from("shares").delete().eq("id", value: id).execute()
        let bucket = Backend.client.storage.from("shares")
        if let files = try? await bucket.list(path: "\(uid)/\(id)") {
            let paths = files.map { "\(uid)/\(id)/" + $0.name }
            if !paths.isEmpty { _ = try? await bucket.remove(paths: paths) }
        }
        if var now = library.album(a.id) {
            now.raw.removeValue(forKey: "share")
            now.touch()
            library.putAlbum(now)
        }
    }
}
