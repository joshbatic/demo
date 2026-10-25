import Foundation
import Observation
import Supabase

/// Co-writing (data spec §3): sharing a song, keeping `shared_songs` up to date, invites, members,
/// and noticing when an owner stops sharing.
@MainActor @Observable
final class Collab {
    static let shared = Collab()

    nonisolated struct Invite: Identifiable, Hashable {
        var id: String
        var songID: String
        var title: String
        var ownerID: String
        var ownerName: String
        var ownerEmail: String
        var avatar: String?
    }

    private(set) var invites: [Invite] = []
    var banner: Invite?

    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored weak var session: AppSession?
    @ObservationIgnored private var libChannel: RealtimeChannelV2?
    @ObservationIgnored private var libTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pushing = Set<String>()
    @ObservationIgnored private var lastLivePush: [String: Date] = [:]
    @ObservationIgnored private var warned = Set<String>()
    /// The song open with a live channel: its pushes are held to one every 4 s.
    @ObservationIgnored var liveSongID: String?

    private var uid: String? { session?.userID }

    // MARK: start / stop

    func start(library: LibraryStore, session: AppSession) {
        self.library = library
        self.session = session
        stop()
        library.onSaved = { [weak self] in self?.syncShared() }
        guard let uid = session.userID else { return }
        // pings to this account: a new invite, or a song that's gone
        let ch = Backend.client.channel("library:\(uid)") { $0.broadcast.receiveOwnBroadcasts = false }
        libChannel = ch
        libTasks.append(Task { [weak self] in
            for await _ in ch.broadcastStream(event: "invite") { await self?.pullInvites() }
        })
        libTasks.append(Task { [weak self] in
            for await _ in ch.broadcastStream(event: "gone") {
                try? await Task.sleep(for: .seconds(1.5))
                await self?.goneCheck()
            }
        })
        Task { await ch.subscribe() }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.goneCheck()
            while !Task.isCancelled {
                await self?.pullInvites()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    func stop() {
        libTasks.forEach { $0.cancel() }; libTasks = []
        pollTask?.cancel(); pollTask = nil
        if let ch = libChannel { Task { await Backend.client.removeChannel(ch) } }
        libChannel = nil
        invites = []; banner = nil
    }

    // MARK: the shared copy

    /// `ser(song)`: the song without device-only keys or `shared`, versions cut to the last 8.
    static func ser(_ s: Song) -> JSONValue {
        var o = s.raw.filter { !$0.key.hasPrefix("_") && $0.key != "shared" }
        if let v = o["versions"]?.array, v.count > 8 { o["versions"] = .array(Array(v.suffix(8))) }
        return .object(o)
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    /// Makes a song co-writable (Pro). Returns its id, which changes if it wasn't a UUID yet.
    func share(_ songID: String) async -> String? {
        guard let library, let session, let uid else { return nil }
        guard var s = library.song(songID) else { return nil }
        if !Self.isUUID(s.id) {
            // older imported songs have ids like "s1712…": sharing needs a UUID
            let old = s.id
            s.raw["id"] = .string(UUID().uuidString.lowercased())
            library.delete(old)
        }
        if s.artist.isEmpty { s.artist = session.myName }
        s.raw["shared"] = true
        s.raw["owner"] = .string(uid)
        s.raw["ownerEmail"] = .string(session.email)
        s.raw["members"] = .array([.string(uid)])
        s.touch()
        library.put(s)
        do { try await push(s) } catch {
            session.toast = "Couldn’t share it: " + describe(error)
            return nil
        }
        Haptics.success()
        session.toast = "Shared. Invite a collaborator by username below."
        return s.id
    }

    /// pushShared: the owner upserts the row; a co-writer may only update it.
    func push(_ song: Song) async throws {
        guard let library, let session, let uid else { return }
        var s = song
        s.raw["lastEditBy"] = .string(session.email)
        s.raw["lastEditAt"] = .number(Clock.nowMs)
        let body = Self.ser(s)
        let now = ISO8601DateFormatter().string(from: Date())
        let mine = s.owner.isEmpty || s.owner == uid
        if mine {
            let row: [String: JSONValue] = ["id": .string(s.id), "owner_id": .string(s.owner.isEmpty ? uid : s.owner),
                                            "owner_email": .string((s.raw["ownerEmail"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? session.email),
                                            "data": body, "updated_at": .string(now)]
            _ = try await Backend.client.from("shared_songs").upsert(row, onConflict: "id").execute()
        } else {
            let res = try await Backend.client.from("shared_songs").update(["data": body, "updated_at": .string(now)] as [String: JSONValue])
                .eq("id", value: s.id).select("id").execute()
            let rows = (try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? []
            if rows.isEmpty { throw PushError.notMember }
        }
        // remember what was pushed (device-only key)
        if var now = library.song(s.id) {
            now.raw["_pushed"] = .number(max(now.raw["_pushed"]?.number ?? 0, s.updated))
            now.raw["lastEditBy"] = s.raw["lastEditBy"]; now.raw["lastEditAt"] = s.raw["lastEditAt"]
            library.putQuietly(now)
        }
    }

    enum PushError: Error { case notMember }

    /// After each save: push every shared song changed since its last push (the live one at most every 4 s).
    func syncShared() {
        guard let library, uid != nil else { return }
        for s in library.songs where s.isShared && s.updated > (s.raw["_pushed"]?.number ?? 0) && !pushing.contains(s.id) {
            if s.id == liveSongID, let last = lastLivePush[s.id], Date().timeIntervalSince(last) < 4 {
                let id = s.id
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4.1 - Date().timeIntervalSince(last)))
                    self?.syncShared()
                    _ = id
                }
                continue
            }
            pushing.insert(s.id)
            if s.id == liveSongID { lastLivePush[s.id] = Date() }
            Task { [weak self] in
                defer { self?.pushing.remove(s.id) }
                do { try await self?.push(s) } catch PushError.notMember {
                    await self?.goneCheck()
                    if let self, self.library?.song(s.id) != nil, !self.warned.contains(s.id) {
                        self.warned.insert(s.id)
                        self.session?.toast = "Couldn’t save your changes to “\(s.displayTitle)”. Ask the owner to invite you again."
                    }
                } catch {
                    if let self, !self.warned.contains("err" + s.id) {
                        self.warned.insert("err" + s.id)
                        self.session?.toast = "Couldn’t sync this song (kept on this device): " + describe(error)
                    }
                }
            }
        }
    }

    /// pullShared: take the shared copy if it's newer; file deletions always merge.
    @discardableResult
    func pull(_ songID: String) async -> Bool {
        guard let library else { return false }
        do {
            let res = try await Backend.client.from("shared_songs").select("data,owner_id,owner_email").eq("id", value: songID).limit(1).execute()
            guard let row = ((try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? []).first,
                  var d = row["data"]?.object, var s = library.song(songID) else { return false }
            let theirsRm = d["rmFiles"]?.object ?? [:]
            if !theirsRm.isEmpty { d["rmFiles"] = .object((s.raw["rmFiles"]?.object ?? [:]).merging(theirsRm) { a, _ in a }) }
            let theirs = d["updated"]?.number ?? 0
            if theirs <= s.updated {
                if Self.fileMerge(&s, rm: d["rmFiles"]?.object ?? [:], audio: d["audio"]?.array ?? [], files: d["files"]?.array ?? []) {
                    s.touch(); library.put(s)
                }
                return false
            }
            let localRm = s.raw["rmFiles"]?.object ?? [:]
            for (k, v) in d { s.raw[k] = v }
            s.raw["shared"] = true
            var changed = Self.fileMerge(&s, rm: localRm, audio: [], files: [])
            if (localRm.keys.contains { (d["rmFiles"]?.object ?? [:])[$0] == nil }) { changed = true }
            if changed { s.touch() }
            s.raw["owner"] = row["owner_id"] ?? s.raw["owner"]
            s.raw["ownerEmail"] = row["owner_email"] ?? s.raw["ownerEmail"]
            s.raw["_pushed"] = .number(theirs)
            library.put(s)
            return true
        } catch { return false }
    }

    /// fileMerge: union the tombstones and the file lists (theirs first), drop anything tombstoned, keep one current audio.
    @discardableResult
    static func fileMerge(_ s: inout Song, rm: [String: JSONValue], audio: [JSONValue], files: [JSONValue]) -> Bool {
        let before = CanonicalJSON.string(.object(s.raw))
        var allRm = s.raw["rmFiles"]?.object ?? [:]
        for (k, v) in rm where allRm[k] == nil { allRm[k] = v }
        if !allRm.isEmpty { s.raw["rmFiles"] = .object(allRm) }
        func union(_ theirs: [JSONValue], _ mine: [JSONValue]) -> [JSONValue] {
            var seen = Set<String>(), out: [JSONValue] = []
            for x in theirs + mine { if let id = x["id"]?.string, !seen.contains(id) { seen.insert(id); out.append(x) } }
            return out.filter { allRm[$0["id"]?.string ?? ""] == nil }
        }
        var a = union(audio, s.raw["audio"]?.array ?? [])
        let f = union(files, s.raw["files"]?.array ?? [])
        if !a.isEmpty && !a.contains(where: { $0["cur"]?.bool == true }), var last = a.last?.object {
            last["cur"] = true; a[a.count - 1] = .object(last)
        }
        if s.raw["audio"] != nil || !a.isEmpty { s.raw["audio"] = .array(a) }
        if s.raw["files"] != nil || !f.isEmpty { s.raw["files"] = .array(f) }
        return CanonicalJSON.string(.object(s.raw)) != before
    }

    /// sharedGoneCheck: drop shared songs (that I don't own) whose shared row no longer exists.
    func goneCheck() async {
        guard let library, let session, let uid else { return }
        guard (try? await Backend.client.auth.session.user.id.uuidString.lowercased()) == uid.lowercased() else { return }
        let theirs = library.songs.filter { $0.isShared && !$0.owner.isEmpty && $0.owner != uid }
        guard !theirs.isEmpty else { return }
        func missing() async -> [Song]? {
            guard let res = try? await Backend.client.from("shared_songs").select("id").in("id", values: theirs.map(\.id)).execute() else { return nil }
            let have = Set(((try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? []).compactMap { $0["id"]?.string })
            return theirs.filter { !have.contains($0.id) }
        }
        guard var gone = await missing(), !gone.isEmpty else { return }
        if gone.count >= 2 && gone.count == theirs.count {
            try? await Task.sleep(for: .seconds(8))
            guard let again = await missing() else { return }
            gone = again
        }
        for s in gone { library.dropLocally(s.id) }
        if gone.count == 1 { session.toast = "“\(gone[0].displayTitle)” was removed by its owner" }
        else if gone.count > 1 { session.toast = "\(gone.count) shared songs were removed by their owners" }
    }

    /// The owner stops sharing: tell everyone, then delete the shared row (members and invites go with it).
    func stopSharing(_ songID: String) async {
        guard let library, let session, var s = library.song(songID) else { return }
        await sharedEnd(s)
        for k in ["owner", "ownerEmail", "members"] { s.raw.removeValue(forKey: k) }
        s.raw["shared"] = false
        s.touch()
        library.put(s)
        session.toast = "Sharing stopped. The song is back on this device only."
    }

    func sharedEnd(_ s: Song) async {
        await LiveSession.sendGone(s.id)
        if let res = try? await Backend.client.from("collab_members").select("user_id").eq("song_id", value: s.id).execute() {
            let ids = ((try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? []).compactMap { $0["user_id"]?.string }
            for id in ids where id != uid { await Self.ping(id, event: "gone") }
        }
        try? await Task.sleep(for: .milliseconds(600))
        _ = try? await Backend.client.from("shared_songs").delete().eq("id", value: s.id).execute()
    }

    /// A quick broadcast to someone's devices (`library:<uid>`): subscribe, send, leave (8 s cap).
    static func ping(_ user: String, event: String) async {
        let ch = Backend.client.channel("library:\(user)")
        await withTaskGroup(of: Void.self) { g in
            g.addTask { @MainActor in
                await ch.subscribe()
                await ch.broadcast(event: event, message: [:])
            }
            g.addTask { try? await Task.sleep(for: .seconds(8)) }
            _ = await g.next()
            g.cancelAll()
        }
        await Backend.client.removeChannel(ch)
    }

    // MARK: people on a song

    struct Person: Identifiable, Hashable {
        var id: String
        var name: String
        var username: String
        var avatar: String?
        var role: String     // owner | member | invited
        var isMe: Bool
    }

    func people(_ song: Song) async -> [Person] {
        guard let uid else { return [] }
        let owner = song.owner.isEmpty ? uid : song.owner
        var ids: [String] = [owner]
        var roles: [String: String] = [owner: "owner"]
        if let res = try? await Backend.client.from("collab_members").select("user_id,email").eq("song_id", value: song.id).execute() {
            for r in (try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? [] {
                if let u = r["user_id"]?.string, roles[u] == nil { ids.append(u); roles[u] = "member" }
            }
        }
        var invited: [(String, String)] = []
        if owner == uid, let res = try? await Backend.client.from("collab_invites").select("invitee_user_id,invitee_username,status")
            .eq("song_id", value: song.id).eq("status", value: "pending").execute() {
            for r in (try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? [] {
                if let u = r["invitee_user_id"]?.string, roles[u] == nil { ids.append(u); roles[u] = "invited"; invited.append((u, r["invitee_username"]?.string ?? "")) }
            }
        }
        var profiles: [String: [String: JSONValue]] = [:]
        if let res = try? await Backend.client.from("profiles").select("user_id,display_name,username,avatar_url").in("user_id", values: ids).execute() {
            for r in (try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? [] { if let u = r["user_id"]?.string { profiles[u] = r } }
        }
        return ids.map { u in
            let p = profiles[u]
            let uname = p?["username"]?.string ?? invited.first { $0.0 == u }?.1 ?? ""
            let name = (p?["display_name"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? (uname.isEmpty ? "Co-writer" : uname)
            return Person(id: u, name: name, username: uname, avatar: p?["avatar_url"]?.string, role: roles[u] ?? "member", isMe: u == uid)
        }
    }

    /// Up to 5 people whose username starts with the text (≥ 2 characters).
    func suggest(_ text: String) async -> [Person] {
        let v = text.lowercased().replacingOccurrences(of: "@", with: "").trimmingCharacters(in: .whitespaces)
        guard v.count >= 2, let uid else { return [] }
        guard let res = try? await Backend.client.from("profiles").select("user_id,username,display_name,avatar_url")
            .ilike("username", pattern: v + "%").not("username", operator: .`is`, value: "null").neq("user_id", value: uid).limit(5).execute() else { return [] }
        return ((try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? []).compactMap { r in
            guard let u = r["user_id"]?.string else { return nil }
            let un = r["username"]?.string ?? ""
            return Person(id: u, name: (r["display_name"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? un, username: un, avatar: r["avatar_url"]?.string, role: "", isMe: false)
        }
    }

    /// Invites someone by username. Returns nil on success, else what went wrong.
    func invite(_ text: String, to songID: String) async -> String? {
        guard let library, let session, let uid, let s = library.song(songID) else { return "Couldn’t send the invite." }
        let v = text.lowercased().replacingOccurrences(of: "@", with: "").trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return "Enter a username" }
        guard let res = try? await Backend.client.from("profiles").select("user_id,username").ilike("username", pattern: v).limit(1).execute(),
              let p = ((try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? []).first,
              let invitee = p["user_id"]?.string else { return "No one found with that username" }
        if invitee == uid { return "That’s your own account" }
        // someone I've blocked can't be invited (the server refuses it too)
        if let br = try? await Backend.client.from("user_blocks").select("blocked").eq("blocker", value: uid).eq("blocked", value: invitee).execute(),
           !((try? JSONDecoder().decode([[String: JSONValue]].self, from: br.data)) ?? []).isEmpty {
            return "You’ve blocked @\(p["username"]?.string ?? v). Unblock them in Account › Blocked to invite them."
        }
        let row: [String: JSONValue] = ["song_id": .string(s.id), "song_title": .string(s.title.isEmpty ? "Untitled" : s.title), "owner_id": .string(uid),
                                        "owner_email": .string(session.email), "owner_name": session.myName.isEmpty ? .null : .string(session.myName),
                                        "invitee_user_id": .string(invitee), "invitee_username": .string(p["username"]?.string ?? v)]
        func insert() async throws { _ = try await Backend.client.from("collab_invites").insert(row).execute() }
        do { try await insert() } catch {
            if "\(error)".lowercased().contains("row-level security") {
                // the shared row may not have landed yet
                try? await push(s)
                try? await Task.sleep(for: .seconds(2.5))
                do { try await insert() } catch { return "Couldn’t send the invite: only the song’s owner can invite people." }
            } else { return "Couldn’t send the invite: " + describe(error) }
        }
        Task { await Self.ping(invitee, event: "invite") }
        _ = try? await Backend.function("push", body: ["action": "invite", "song_id": .string(s.id), "invitee": .string(invitee)])
        return nil
    }

    func remove(_ person: Person, from songID: String) async {
        _ = try? await Backend.client.from("collab_members").delete().eq("song_id", value: songID).eq("user_id", value: person.id).execute()
        if person.role == "invited" {
            _ = try? await Backend.client.from("collab_invites").delete().eq("song_id", value: songID).eq("invitee_user_id", value: person.id).execute()
        }
        session?.toast = "Removed \(person.name)"
    }

    // MARK: invites to me

    func pullInvites() async {
        guard let uid else { return }
        guard let res = try? await Backend.client.from("collab_invites").select("*").eq("status", value: "pending").eq("invitee_user_id", value: uid).execute() else { return }
        let rows = (try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? []
        var list = rows.compactMap { r -> Invite? in
            guard let id = r["id"]?.string, let sid = r["song_id"]?.string else { return nil }
            return Invite(id: id, songID: sid, title: r["song_title"]?.string ?? "Untitled", ownerID: r["owner_id"]?.string ?? "",
                          ownerName: r["owner_name"]?.string ?? (r["owner_email"]?.string?.components(separatedBy: "@").first ?? "Someone"),
                          ownerEmail: r["owner_email"]?.string ?? "", avatar: nil)
        }
        let owners = Array(Set(list.map(\.ownerID)))
        if !owners.isEmpty, let pr = try? await Backend.client.from("profiles").select("user_id,display_name,avatar_url").in("user_id", values: owners).execute() {
            let ps = (try? JSONDecoder().decode([[String: JSONValue]].self, from: pr.data)) ?? []
            for i in list.indices {
                if let p = ps.first(where: { $0["user_id"]?.string == list[i].ownerID }) {
                    if let n = p["display_name"]?.string, !n.isEmpty { list[i].ownerName = n }
                    list[i].avatar = p["avatar_url"]?.string
                }
            }
        }
        invites = list
        // a banner for invites this device hasn't shown yet
        var seen = Set(UserDefaults.standard.stringArray(forKey: "songpad:invseen") ?? [])
        if banner == nil, let fresh = list.first(where: { !seen.contains($0.id) }) {
            seen.insert(fresh.id)
            UserDefaults.standard.set(Array(seen), forKey: "songpad:invseen")
            banner = fresh
            Haptics.success()
        }
    }

    func accept(_ inv: Invite) async {
        guard let library, let session, let uid else { return }
        banner = nil
        do {
            _ = try await Backend.client.from("collab_members").upsert(["song_id": .string(inv.songID), "user_id": .string(uid), "email": .string(session.email)] as [String: JSONValue], onConflict: "song_id,user_id").execute()
        } catch {
            session.toast = "Couldn’t join: " + describe(error)
            return
        }
        _ = try? await Backend.client.from("collab_invites").update(["status": "accepted", "responded_at": .string(ISO8601DateFormatter().string(from: Date()))] as [String: JSONValue]).eq("id", value: inv.id).execute()
        if library.song(inv.songID) == nil,
           let res = try? await Backend.client.from("shared_songs").select("data,owner_id,owner_email").eq("id", value: inv.songID).limit(1).execute(),
           let row = ((try? JSONDecoder().decode([[String: JSONValue]].self, from: res.data)) ?? []).first,
           var d = row["data"]?.object {
            d["id"] = .string(inv.songID)
            d["shared"] = true
            d["owner"] = row["owner_id"] ?? .string(inv.ownerID)
            d["ownerEmail"] = row["owner_email"] ?? .string(inv.ownerEmail)
            var members = (d["members"]?.array ?? []).compactMap(\.string)
            if !members.contains(uid) { members.append(uid) }
            d["members"] = .array(members.map { .string($0) })
            let now = Clock.nowMs
            d["updated"] = .number(now)
            d["_pushed"] = .number(now)
            library.add(Song(raw: d))
        }
        invites.removeAll { $0.id == inv.id }
        Haptics.success()
        session.toast = "You’re in. “\(inv.title)” is in your songs."
    }

    func decline(_ inv: Invite) async {
        banner = nil
        invites.removeAll { $0.id == inv.id }
        _ = try? await Backend.client.from("collab_invites").update(["status": "declined", "responded_at": .string(ISO8601DateFormatter().string(from: Date()))] as [String: JSONValue]).eq("id", value: inv.id).execute()
    }
}
