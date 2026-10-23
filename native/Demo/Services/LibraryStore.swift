import Foundation
import Observation
import Supabase

/// The signed-in account's songs and ideas: kept on the device, and synced with `cloud_library`
/// exactly the way the web app does it (spec §2), so all clients can share one library safely.
@MainActor @Observable
final class LibraryStore {
    private(set) var uid: String?
    var songs: [Song] = []
    var ideas: [Idea] = []
    /// Pinned songs, per device like the web (`songpad:pins`): id → ms pinned.
    var pins: [String: Double] = [:]
    private(set) var syncing = false
    var notice: String?

    /// The song open in the editor and when it was last typed in: it always keeps its local copy in a merge.
    var editingID: String?
    @ObservationIgnored var lastTyping = Date.distantPast
    var ideaEditingID: String?
    /// Runs after each save to the device (shared songs push their changes from here).
    @ObservationIgnored var onSaved: (() -> Void)?

    // sync bookkeeping: not watched by any screen
    @ObservationIgnored private var tomb = Tombs()
    @ObservationIgnored private var base: BaseIDs?
    @ObservationIgnored private var seenAt: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false

    nonisolated struct Tombs: Codable { var songs: [String: Double] = [:]; var ideas: [String: Double] = [:] }
    nonisolated struct BaseIDs: Codable { var songs: [String]; var ideas: [String] }
    private nonisolated struct Stored: Codable {
        var songs: [JSONValue]; var ideas: [JSONValue]; var tomb: Tombs; var base: BaseIDs?; var seenAt: String?
    }

    static let tombTTL: Double = 90 * 86_400_000

    // MARK: loading

    func open(uid: String) {
        guard uid != self.uid else { return }
        close()
        self.uid = uid
        pins = (UserDefaults.standard.dictionary(forKey: "songpad:pins") as? [String: Double]) ?? [:]
        if let data = try? Data(contentsOf: fileURL(uid)), let st = try? JSONDecoder().decode(Stored.self, from: data) {
            songs = st.songs.compactMap { $0.object.map(Song.init(raw:)) }.filter { !$0.id.isEmpty }
            ideas = st.ideas.compactMap { $0.object.map(Idea.init(raw:)) }.filter { !$0.id.isEmpty }
            tomb = st.tomb; base = st.base; seenAt = st.seenAt
        } else {
            // a fresh device starts empty *with no base*, so its first sync can't infer any deletes
            songs = []; ideas = []; tomb = Tombs(); base = nil; seenAt = nil
        }
        // every library starts with the "How *[demo] works" song (once; deleting it is for good)
        let seeded = Guide.seed(songs, uid: uid)
        if seeded != songs { songs = seeded; flushSave() }
        sync()
        startPolling()
    }

    func close() {
        flushSave()
        pollTask?.cancel(); pushTask?.cancel(); saveTask?.cancel()
        uid = nil; songs = []; ideas = []; tomb = Tombs(); base = nil; seenAt = nil
    }

    private func fileURL(_ uid: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library-\(uid).json")
    }

    // MARK: editing

    func song(_ id: String) -> Song? { songs.first { $0.id == id } }

    /// Saves a changed song (the caller has already bumped `updated` where the user changed something).
    func put(_ song: Song, typing: Bool = false) {
        if let i = songs.firstIndex(where: { $0.id == song.id }) { songs[i] = song } else { songs.insert(song, at: 0) }
        if typing { lastTyping = Date() }
        changed()
    }

    func add(_ song: Song) { songs.insert(song, at: 0); changed() }

    /// Saves bookkeeping on a song (like when it was last pushed) without counting as an edit.
    func putQuietly(_ song: Song) {
        if let i = songs.firstIndex(where: { $0.id == song.id }) { songs[i] = song }
        changed()
    }

    /// A shared song that's gone (its owner stopped sharing or deleted it): off this device and the library.
    func dropLocally(_ id: String) {
        if editingID == id { editingID = nil }
        delete(id)
    }

    /// Removes a song for good, on every device (the tombstone is recorded straight away).
    func delete(_ id: String) {
        songs.removeAll { $0.id == id }
        tomb.songs[id] = Clock.nowMs
        pins.removeValue(forKey: id); savePins()
        changed()
    }

    func putIdea(_ idea: Idea) {
        if let i = ideas.firstIndex(where: { $0.id == idea.id }) { ideas[i] = idea } else { ideas.insert(idea, at: 0) }
        changed()
    }

    func deleteIdea(_ id: String) { ideas.removeAll { $0.id == id }; tomb.ideas[id] = Clock.nowMs; changed() }

    func isPinned(_ id: String) -> Bool { pins[id] != nil }
    func setPin(_ id: String, _ on: Bool) { if on { pins[id] = Clock.nowMs } else { pins.removeValue(forKey: id) }; savePins() }
    private func savePins() { UserDefaults.standard.set(pins, forKey: "songpad:pins") }

    /// Every change: write to the device shortly, then sync (250 ms / 900 ms, like the web).
    private func changed() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.flushSave()
            self?.onSaved?()
        }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1150))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    func flushSave() {
        guard let uid else { return }
        let st = Stored(songs: songs.map { .object($0.raw) }, ideas: ideas.map { .object($0.raw) }, tomb: tomb, base: base, seenAt: seenAt)
        let url = fileURL(uid)
        guard let data = try? JSONEncoder().encode(st) else { return }
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: sync (spec §2.3)

    private nonisolated struct Row: Decodable { let data: JSONValue; let updated_at: String }
    private nonisolated struct AtRow: Decodable { let updated_at: String }
    private nonisolated struct Write: Encodable { let data: JSONValue; let updated_at: String }
    private nonisolated struct Insert: Encodable { let user_id: String; let data: JSONValue; let updated_at: String }

    /// Runs a sync now (one at a time; a request during one runs once more afterwards).
    func sync() {
        guard uid != nil else { return }
        if running { again = true; return }
        running = true; syncing = true
        Task {
            await attempt(tries: 0)
            running = false; syncing = false
            if again { again = false; sync() }
        }
    }

    private func attempt(tries: Int) async {
        guard let uid else { return }
        let client = Backend.client
        let rows: [Row]
        do {
            rows = try await client.from("cloud_library").select("data, updated_at").eq("user_id", value: uid).limit(1).execute().value
        } catch {
            if base == nil { notice = "Couldn’t reach cloud storage: \(describe(error))" }
            return
        }
        guard uid == self.uid else { return }
        let row = rows.first
        let remote = Remote(row?.data)
        let prevAt = row?.updated_at
        let now = Clock.nowMs

        tomb.songs = maxPerKey(tomb.songs, remote.deletedSongs)
        tomb.ideas = maxPerKey(tomb.ideas, remote.deletedIdeas)
        let pinS = (editingID != nil && Date().timeIntervalSince(lastTyping) < 4) ? editingID : nil

        let mergedSongs = Self.merge(local: songs.map(\.raw), remote: remote.songs, tomb: &tomb.songs, base: base?.songs, now: now, pin: pinS)
        let mergedIdeas = Self.merge(local: ideas.map(\.raw), remote: remote.ideas, tomb: &tomb.ideas, base: base?.ideas, now: now, pin: ideaEditingID)

        // apply, keeping each item's device-only `_` keys
        let oldSongs = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newSongs = mergedSongs.map { m -> Song in
            var s = Song(raw: m)
            if let o = oldSongs[s.id] { for (k, v) in o.raw where k.hasPrefix("_") && s.raw[k] == nil { s.raw[k] = v } }
            return s
        }
        if newSongs != songs { songs = newSongs }
        let newIdeas = mergedIdeas.map(Idea.init(raw:))
        if newIdeas != ideas { ideas = newIdeas }

        let payload = Self.payload(songs: songs.map(\.cloudJSON), ideas: ideas.map(\.cloudJSON), tomb: tomb)
        let was = Self.payload(songs: remote.songs.map { .object($0.filter { !$0.key.hasPrefix("_") }) }, ideas: remote.ideas.map { .object($0.filter { !$0.key.hasPrefix("_") }) }, tombJSON: remote.deletedJSON)
        if row != nil && !remote.legacy && CanonicalJSON.string(payload) == CanonicalJSON.string(was) {
            seenAt = prevAt
            base = BaseIDs(songs: songs.map(\.id), ideas: ideas.map(\.id))
            flushSave()
            return
        }

        let stamp = Self.iso(Date())
        var lost = false
        do {
            if let prevAt {
                // compare-and-swap: only replace the row nobody else has written since we read it
                let r: [AtRow] = try await client.from("cloud_library").update(Write(data: payload, updated_at: stamp))
                    .eq("user_id", value: uid).eq("updated_at", value: Self.normalise(prevAt))
                    .select("updated_at").execute().value
                if r.isEmpty { lost = true } else { seenAt = r[0].updated_at }
            } else {
                let r: [AtRow] = try await client.from("cloud_library").insert(Insert(user_id: uid, data: payload, updated_at: stamp))
                    .select("updated_at").execute().value
                seenAt = r.first?.updated_at
            }
        } catch let e as PostgrestError where e.code == "23505" {
            lost = true
        } catch {
            notice = "Couldn’t sync to your account: \(describe(error))"
            return
        }
        if lost {
            if tries < 3 { await attempt(tries: tries + 1) }
            return
        }
        base = BaseIDs(songs: songs.map(\.id), ideas: ideas.map(\.id))
        flushSave()
    }

    /// The web's libMergeList, exactly: whole-item last-writer-wins on `updated`, local wins ties
    /// unless the remote's canonical JSON sorts higher, tombstones beat anything not newer than them,
    /// and an id that was here at the last sync but isn't any more is a delete.
    static func merge(local: [[String: JSONValue]], remote: [[String: JSONValue]], tomb: inout [String: Double], base: [String]?, now: Double, pin: String?) -> [[String: JSONValue]] {
        func id(_ x: [String: JSONValue]) -> String? { x["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        func upd(_ x: [String: JSONValue]) -> Double { x["updated"]?.number ?? 0 }
        func clean(_ x: [String: JSONValue]) -> JSONValue { .object(x.filter { !$0.key.hasPrefix("_") }) }
        var have = Set<String>()
        for x in local { if let i = id(x) { have.insert(i) } }
        if let base { for i in base where !have.contains(i) && tomb[i] == nil { tomb[i] = now } }
        var rb: [String: [String: JSONValue]] = [:]
        for r in remote { if let i = id(r) { rb[i] = r } }
        var out: [[String: JSONValue]] = [], used = Set<String>()
        for x in local {
            guard let i = id(x), !used.contains(i) else { continue }
            used.insert(i)
            var w = x
            if let r = rb[i], i != pin {
                let ru = upd(r), xu = upd(x)
                if ru > xu || (ru == xu && jsGreater(CanonicalJSON.string(clean(r)), CanonicalJSON.string(clean(x)))) { w = r }
            }
            if i != pin, let t = tomb[i], t >= upd(w) { continue }
            out.append(w)
        }
        for r in remote {
            guard let i = id(r), !used.contains(i) else { continue }
            used.insert(i)
            if let t = tomb[i], t >= upd(r) { continue }
            out.append(r)
        }
        for (k, t) in tomb where now - t > tombTTL { tomb.removeValue(forKey: k) }
        return out
    }

    /// JavaScript string comparison (UTF-16 code units).
    static func jsGreater(_ a: String, _ b: String) -> Bool { Array(b.utf16).lexicographicallyPrecedes(Array(a.utf16)) }

    private static func sortByID(_ items: [JSONValue]) -> [JSONValue] {
        items.sorted { Array(($0["id"]?.string ?? "").utf16).lexicographicallyPrecedes(Array(($1["id"]?.string ?? "").utf16)) }
    }

    static func payload(songs: [JSONValue], ideas: [JSONValue], tomb: Tombs) -> JSONValue {
        payload(songs: songs, ideas: ideas, tombJSON: .object([
            "songs": .object(tomb.songs.mapValues { .number($0) }),
            "ideas": .object(tomb.ideas.mapValues { .number($0) })
        ]))
    }

    static func payload(songs: [JSONValue], ideas: [JSONValue], tombJSON: JSONValue) -> JSONValue {
        .object(["v": 2, "songs": .array(sortByID(songs)), "ideas": .array(sortByID(ideas)), "deleted": tombJSON])
    }

    private func maxPerKey(_ a: [String: Double], _ b: [String: Double]) -> [String: Double] {
        var o = a
        for (k, v) in b where (o[k] ?? -1) < v { o[k] = v }
        return o
    }

    /// The row's `data`, read leniently: v2 object, or a legacy bare array of songs.
    private nonisolated struct Remote {
        var songs: [[String: JSONValue]] = [], ideas: [[String: JSONValue]] = []
        var deletedSongs: [String: Double] = [:], deletedIdeas: [String: Double] = [:]
        var deletedJSON: JSONValue = .object(["songs": .object([:]), "ideas": .object([:])])
        var legacy = false
        init(_ d: JSONValue?) {
            guard let d else { return }
            if let arr = d.array { legacy = true; songs = arr.compactMap(\.object); return }
            songs = d["songs"]?.array?.compactMap(\.object) ?? []
            ideas = d["ideas"]?.array?.compactMap(\.object) ?? []
            let del = d["deleted"]
            deletedSongs = (del?["songs"]?.object ?? [:]).compactMapValues(\.number)
            deletedIdeas = (del?["ideas"]?.object ?? [:]).compactMapValues(\.number)
            deletedJSON = .object(["songs": .object(del?["songs"]?.object ?? [:]), "ideas": .object(del?["ideas"]?.object ?? [:])])
        }
    }

    // MARK: polling (spec §2.2: every 20 s while open)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.checkRemote()
            }
        }
    }

    func checkRemote() async {
        guard let uid, !running else { return }
        let rows: [AtRow]? = try? await Backend.client.from("cloud_library").select("updated_at").eq("user_id", value: uid).limit(1).execute().value
        if let at = rows?.first?.updated_at, at != seenAt { sync() }
    }

    // MARK: helpers

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// "+00:00" can turn into a space in a URL query; "Z" means the same instant and is safe.
    static func normalise(_ ts: String) -> String {
        ts.hasSuffix("+00:00") ? String(ts.dropLast(6)) + "Z" : ts
    }
}
