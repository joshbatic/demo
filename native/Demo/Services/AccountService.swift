import Foundation
import SwiftUI
import UIKit
import Supabase

/// Account › profile, links, blocks, storage, notifications prefs, support and delete (spec §6, data spec §5).
extension AppSession {

    // MARK: seen ping

    /// app_seen_ping once per sign-in: which device and build is in use.
    func seenPing() async {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let dev = UIDevice.current.identifierForVendor?.uuidString.lowercased() ?? "ios"
        let platform = Config.isDevBuild ? "ios-dev" : "ios"
        _ = try? await Backend.rpc("app_seen_ping", [
            "p_device": .string(dev), "p_platform": .string(platform), "p_build": .string(Config.appCommit),
            "p_seq": .number(Double(Config.appSeq)),
            "p_ua": .string(String("*[demo] native \(v) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)".prefix(300)))
        ])
    }

    // MARK: profile

    private func cacheProfile() {
        guard let uid = userID, let d = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(d, forKey: "songpad:profile:\(uid)")
    }

    /// Name & Username › Save. Returns an error message, or nil when saved.
    func saveNameAndUsername(name: String, username: String) async -> String? {
        guard let uid = userID else { return "Sign in first." }
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var u = username.trimmingCharacters(in: .whitespaces)
        while u.hasPrefix("@") { u.removeFirst() }
        u = u.lowercased()
        if !u.isEmpty && u.range(of: #"^[a-z0-9_]{3,20}$"#, options: .regularExpression) == nil {
            return "Usernames are 3–20 characters: letters, numbers, underscores."
        }
        let oldName = myName
        nonisolated struct Up: Encodable { let user_id: String; let username: String?; let display_name: String?; let updated_at: String }
        do {
            try await Backend.client.from("profiles").upsert(Up(user_id: uid, username: u.isEmpty ? nil : u,
                                                               display_name: nm.isEmpty ? (myName.isEmpty ? (u.isEmpty ? nil : u) : myName) : nm,
                                                               updated_at: LibraryStore.iso(Date())), onConflict: "user_id").execute()
        } catch {
            let m = describe(error)
            if m.contains("23505") || m.lowercased().contains("duplicate") { return "That username’s taken." }
            if m.contains("reserved_username") { return "That username’s reserved. If it’s your name, get in touch through hellodemo.app and we’ll set it up for you." }
            return "Couldn’t save: " + m
        }
        profile.username = u.isEmpty ? nil : u
        if !nm.isEmpty { profile.display_name = nm }
        cacheProfile()
        if myName != oldName { renameMyArtistCredit(from: oldName, to: myName) }
        return nil
    }

    /// renameMyArtistCredit: songs still crediting my old name follow the new one.
    func renameMyArtistCredit(from old: String, to new: String) {
        guard !old.isEmpty, !new.isEmpty, old != new else { return }
        for var s in library.songs where s.artist == old || (s.raw["_autoArtist"]?.string ?? "") == old {
            s.artist = new; s.raw["_autoArtist"] = .string(new); s.touch(); library.put(s)
        }
    }

    /// The profile photo: centre-cropped to 256×256 JPEG 0.85, saved as a data URL on the profile.
    func saveAvatar(_ image: UIImage) async {
        guard let uid = userID else { return }
        let side: CGFloat = 256
        let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let img = r.image { _ in
            let s = image.size, k = max(side / s.width, side / s.height)
            let w = s.width * k, h = s.height * k
            image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        guard let data = img.jpegData(compressionQuality: 0.85) else { return }
        let url = "data:image/jpeg;base64," + data.base64EncodedString()
        nonisolated struct Up: Encodable { let user_id: String; let avatar_url: String; let display_name: String?; let updated_at: String }
        do {
            try await Backend.client.from("profiles").upsert(Up(user_id: uid, avatar_url: url, display_name: myName.isEmpty ? nil : myName, updated_at: LibraryStore.iso(Date())), onConflict: "user_id").execute()
            profile.avatar_url = url; cacheProfile()
            Haptics.success(); toast = "Photo updated"
        } catch { toast = "Couldn’t update your photo: " + describe(error) }
    }

    /// Links: bare handles become full links; empty clears.
    static func normaliseLink(_ v: String, kind: String) -> String? {
        var x = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.isEmpty else { return nil }
        if x.lowercased().hasPrefix("http://") || x.lowercased().hasPrefix("https://") { return x }
        if x.contains(".") && x.contains("/") { return "https://" + x }
        while x.hasPrefix("@") { x.removeFirst() }
        switch kind {
        case "instagram": return "https://instagram.com/" + x
        case "tiktok": return "https://tiktok.com/@" + x
        case "spotify": return "https://open.spotify.com/artist/" + x
        case "apple_music": return "https://music.apple.com/search?term=" + (x.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? x)
        default: return "https://" + x
        }
    }

    /// "@handle" for Instagram / TikTok, "Artist page" for Spotify.
    static func linkLabel(_ url: String?, kind: String) -> String? {
        guard let u = url, !u.isEmpty else { return nil }
        if kind == "spotify" || kind == "apple_music" { return u.contains("/artist/") ? "Artist page" : "Connected" }
        let last = u.split(separator: "/").last.map(String.init) ?? u
        return last.hasPrefix("@") ? last : "@" + last
    }

    func saveLinks(spotify: String, appleMusic: String, instagram: String, tiktok: String) async -> Bool {
        guard let uid = userID else { return false }
        let sp = Self.normaliseLink(spotify, kind: "spotify"), am = Self.normaliseLink(appleMusic, kind: "apple_music")
        let ig = Self.normaliseLink(instagram, kind: "instagram"), tt = Self.normaliseLink(tiktok, kind: "tiktok")
        nonisolated struct Up: Encodable { let user_id: String; let updated_at: String; let link_spotify: String?; let link_apple_music: String?; let link_instagram: String?; let link_tiktok: String? }
        do {
            try await Backend.client.from("profiles").upsert(Up(user_id: uid, updated_at: LibraryStore.iso(Date()), link_spotify: sp, link_apple_music: am, link_instagram: ig, link_tiktok: tt), onConflict: "user_id").execute()
            profile.link_spotify = sp; profile.link_apple_music = am; profile.link_instagram = ig; profile.link_tiktok = tt; cacheProfile()
            toast = "Saved"; return true
        } catch { toast = "Couldn’t save: " + describe(error); return false }
    }

    // MARK: blocks (data spec §3.10)

    struct Blocked: Identifiable, Hashable { let id: String; var name: String; var username: String }

    func loadBlocked() async -> [Blocked] {
        guard let uid = userID,
              let res = try? await Backend.client.from("user_blocks").select("blocked").eq("blocker", value: uid).execute(),
              let rows = try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data) else { return [] }
        let ids = rows.compactMap { $0["blocked"]?.string }
        guard !ids.isEmpty else { return [] }
        var out = ids.map { Blocked(id: $0, name: "Someone", username: "") }
        if let pr = try? await Backend.client.from("profiles").select("user_id,display_name,username").in("user_id", values: ids).execute(),
           let ps = try? JSONDecoder().decode([[String: JSONValue]].self, from: pr.data) {
            for i in out.indices {
                if let p = ps.first(where: { $0["user_id"]?.string == out[i].id }) {
                    out[i].username = p["username"]?.string ?? ""
                    out[i].name = (p["display_name"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? (out[i].username.isEmpty ? "Someone" : "@" + out[i].username)
                }
            }
        }
        return out
    }

    /// Block the person behind an invite: their pending invites are declined; they aren't told.
    func block(_ inv: Collab.Invite) async {
        guard let uid = userID else { return }
        _ = try? await Backend.client.from("user_blocks").insert(["blocker": .string(uid), "blocked": .string(inv.ownerID)] as [String: JSONValue]).execute()
        for i in Collab.shared.invites where i.ownerID == inv.ownerID { await Collab.shared.decline(i) }
        toast = "Blocked \(inv.ownerName). To report them, email help@hellodemo.app"
    }

    func unblock(_ b: Blocked) async {
        guard let uid = userID else { return }
        _ = try? await Backend.client.from("user_blocks").delete().eq("blocker", value: uid).eq("blocked", value: b.id).execute()
        toast = "Unblocked " + (b.username.isEmpty ? b.name : "@" + b.username)
    }

    // MARK: storage, notification prefs

    func myStorage() async -> (used: Double, limit: Double)? {
        guard let r = try? await Backend.rpc("my_storage") else { return nil }
        let row = r.array?.first ?? r
        guard let used = row["used_bytes"]?.number else { return nil }
        return (used, row["limit_bytes"]?.number ?? 157_286_400)
    }

    func notifyPrefs() async -> [String: Bool] {
        let r = try? await Backend.rpc("my_notify_prefs")
        var out: [String: Bool] = [:]
        for k in ["cowrite", "nudge", "account", "plays"] { out[k] = r?[k]?.bool ?? true }
        return out
    }

    func setNotifyPref(_ k: String, _ on: Bool) async {
        _ = try? await Backend.rpc("set_notify_prefs", ["p": .object([k: .bool(on)])])
    }

    // MARK: Rate

    /// Reset What Rate Learned: forget the personality Rate read from every song.
    func resetRateLearned() {
        for var s in library.songs {
            guard var r = s.raw["rating"]?.object, r["personality"] != nil else { continue }
            r.removeValue(forKey: "personality")
            s.raw["rating"] = .object(r); s.touch(); library.put(s)
        }
        toast = "Rate will learn your style fresh"
    }

    // MARK: support (spec §6.10)

    struct Ticket: Identifiable { let id: String; let topic: String; let message: String; let status: String; let replies: [(at: String, text: String)]; let created: String; let fromUs: Bool }

    func tickets() async -> [Ticket] {
        guard let r = try? await Backend.rpc("my_tickets"), let a = r.array else { return [] }
        return a.compactMap { t in
            guard let id = t["id"]?.string else { return nil }
            var msg = t["message"]?.string ?? ""
            let fromUs = msg.hasPrefix("(You wrote to them) ")
            if fromUs { msg = String(msg.dropFirst("(You wrote to them) ".count)) }
            let reps = (t["replies"]?.array ?? []).map { (at: $0["at"]?.string ?? "", text: $0["text"]?.string ?? "") }
            return Ticket(id: id, topic: t["topic"]?.string ?? "other", message: msg, status: t["status"]?.string ?? "open",
                          replies: reps, created: t["created_at"]?.string ?? "", fromUs: fromUs)
        }
    }

    /// Returns nil when sent, or the error to show.
    func sendSupport(topic: String, message: String, diagnostics: Bool) async -> String? {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard m.count >= 3 else { return "Write a little more so we can help." }
        var body: [String: JSONValue] = ["action": "submit", "topic": .string(topic), "message": .string(String(m.prefix(4000)))]
        if diagnostics { body["diag"] = diagReport() }
        do {
            let r = try await Backend.function("support", body: body)
            if let e = r["error"]?.string { return e }
            return nil
        } catch { return "Couldn’t send your message: " + describe(error) }
    }

    /// diagReport: build, device, plan and sync state. Never lyrics or songs.
    func diagReport() -> JSONValue {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let sz = UIScreen.main.bounds.size
        return .object([
            "build": .string(Config.appCommit), "seq": .number(Double(Config.appSeq)), "platform": "ios", "native": true,
            "dev": .bool(Config.isDevBuild), "version": .string("\(v) (\(b))"),
            "device": .string(UIDevice.current.model), "os": .string(UIDevice.current.systemVersion),
            "screen": .string("\(Int(sz.width))x\(Int(sz.height))@\(Int(UIScreen.main.scale))"),
            "lang": .string(Locale.preferredLanguages.first ?? ""), "tz": .string(TimeZone.current.identifier),
            "signed_in": .bool(userID != nil), "plan": .string(plan.tier),
            "iap": .string(Store.shared.available ? "on" : "off"),
            "sync": .string(library.syncing ? "syncing" : (library.notice ?? "ok")),
            "songs": .number(Double(library.songs.count)), "ideas": .number(Double(library.ideas.count)),
            "paused": .object(["ai": .bool(RemoteConfig.shared.aiOff), "sync": .bool(RemoteConfig.shared.syncOff), "uploads": .bool(RemoteConfig.shared.uploadsOff)])
        ])
    }

    // MARK: delete account (data spec §5.5)

    /// Deletes every stored file, then the account itself; then signs out. Returns an error to show, or nil.
    func deleteAccount() async -> String? {
        guard let uid = userID else { return nil }
        let storage = Backend.client.storage
        for bucket in ["song-files", "shares"] {
            var paths: [String] = []
            func walk(_ dir: String) async {
                var offset = 0
                while true {
                    guard let items = try? await storage.from(bucket).list(path: dir, options: SearchOptions(limit: 100, offset: offset)), !items.isEmpty else { return }
                    for it in items {
                        let p = dir + "/" + it.name
                        if it.id == nil { await walk(p) } else { paths.append(p) }
                    }
                    if items.count < 100 { return }
                    offset += 100
                }
            }
            await walk(uid)
            var i = 0
            while i < paths.count {
                _ = try? await storage.from(bucket).remove(paths: Array(paths[i..<min(i + 100, paths.count)]))
                i += 100
            }
        }
        do {
            _ = try await Backend.rpc("delete_my_account")
        } catch {
            let m = describe(error)
            if m.contains("does not exist") || m.contains("PGRST202") { return "Account deletion isn’t set up on the server yet" }
            return "Couldn’t delete your account: " + m
        }
        // every local trace of this account
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.contains(uid) { d.removeObject(forKey: k) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("library-\(uid).json"))
        await signOut()
        toast = "Your account and everything in it has been deleted."
        return nil
    }
}
