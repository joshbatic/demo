import Foundation
import Observation
import Supabase
import UIKit

/// Live writing on the open song (data spec §3.7, engines.md §5): small text patches every 50 ms or so,
/// whole-song resyncs, formatting and file changes. A shared song uses `song:<id>` (co-writers and your own
/// devices); a song that's only yours uses `me:<your id>:<id>`, so your iPhone and Mac stay in step as you type.
/// Patches use the web's format on UTF-16 offsets so the web, Mac and iPhone can write together.
@MainActor @Observable
final class LiveSession {
    /// "Sam is writing…" for 2.5 s after their change arrives.
    private(set) var writing: String?

    static let fields = ["lyrics", "title", "artist", "chords", "notes", "key", "bpm", "tuning", "status"]
    /// The device id every payload carries (LIB_DEV), so a device ignores its own messages.
    static let dev: String = {
        if let d = UserDefaults.standard.string(forKey: "songpad:dev") { return d }
        let d = UUID().uuidString.lowercased(); UserDefaults.standard.set(d, forKey: "songpad:dev"); return d
    }()
    /// Private channels first; if the first private join is refused, public for the rest of the session.
    static var usePrivate = true
    private static var active: [String: RealtimeChannelV2] = [:]

    @ObservationIgnored private var songID = ""
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private weak var session: AppSession?
    @ObservationIgnored private weak var bridge: EditorBridge?
    @ObservationIgnored private var channel: RealtimeChannelV2?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var snap: [String: String] = [:]
    @ObservationIgnored private var snapRich = ""
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var lastSend = Date.distantPast
    @ObservationIgnored private var lastFull = Date.distantPast
    @ObservationIgnored private(set) var applying = false
    @ObservationIgnored private var writingTask: Task<Void, Never>?
    @ObservationIgnored private var ensureTask: Task<Void, Never>?
    /// whether the channel is the shared song's (a song that becomes shared rejoins on its own)
    @ObservationIgnored private(set) var topicShared = false

    var isOn: Bool { channel != nil }

    // MARK: joining

    func start(songID: String, library: LibraryStore, session: AppSession, bridge: EditorBridge) {
        guard let s = library.song(songID), session.userID != nil else { return }
        stop()
        self.songID = songID; self.library = library; self.session = session; self.bridge = bridge
        takeSnapshot(s)
        if s.isShared { Collab.shared.liveSongID = songID }
        Task {
            if s.isShared { await Collab.shared.pull(songID) }
            if let s = library.song(songID) { takeSnapshot(s) }
            await join()
        }
        // re-ensure every 10 s
        ensureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let ch = self.channel else { continue }
                if ch.status != .subscribed && ch.status != .subscribing { await self.join() }
            }
        }
    }

    func stop() {
        flushNow()
        if Collab.shared.liveUp == songID { Collab.shared.liveUp = nil }
        tasks.forEach { $0.cancel() }; tasks = []
        ensureTask?.cancel(); ensureTask = nil
        sendTask?.cancel()
        if let ch = channel { Task { await Backend.client.removeChannel(ch) } }
        Self.active[songID] = nil
        channel = nil
        if Collab.shared.liveSongID == songID { Collab.shared.liveSongID = nil }
    }

    private func join() async {
        if let old = channel { await Backend.client.removeChannel(old) }
        tasks.forEach { $0.cancel() }; tasks = []
        let priv = Self.usePrivate
        let shared = library?.song(songID)?.isShared ?? false
        let topic = shared ? "song:\(songID)" : "me:\(session?.userID ?? ""):\(songID)"
        topicShared = shared
        let ch = Backend.client.channel(topic) { c in
            c.broadcast.receiveOwnBroadcasts = false
            c.isPrivate = priv
        }
        channel = ch
        Self.active[songID] = ch
        for ev in ["p", "fmt", "need", "full", "files", "gone"] {
            tasks.append(Task { [weak self] in
                for await msg in ch.broadcastStream(event: ev) {
                    guard let self, let payload = Self.json(msg["payload"]) else { continue }
                    self.receive(ev, payload)
                }
            })
        }
        if Collab.shared.liveUp == songID { Collab.shared.liveUp = nil }
        do {
            try await ch.subscribeWithError()
            guard channel === ch else { return }
            Collab.shared.liveUp = songID
        } catch {
            let m = "\(error)".lowercased()
            if priv && m.range(of: "unauthori|denied|permission|not allowed", options: .regularExpression) != nil {
                Self.usePrivate = false
                await join()
                return
            }
            try? await Task.sleep(for: .seconds(2))
            if channel === ch { await join() }
            return
        }
        // a joiner asks for the whole song
        send("need", ["u": .number(library?.song(songID)?.updated ?? 0)])
    }

    // MARK: sending

    private func takeSnapshot(_ s: Song) {
        snap = Dictionary(uniqueKeysWithValues: Self.fields.map { ($0, Self.value(s, $0)) })
        snapRich = s.rich
    }

    static func value(_ s: Song, _ k: String) -> String {
        guard let v = s.raw[k] else { return "" }
        if let t = v.string { return t }
        if let n = v.number { return n == n.rounded() ? String(Int(n)) : String(n) }
        return ""
    }

    /// The song changed here: send what changed (at most every 50 ms, so it feels instant on the other side).
    func localChanged() {
        guard channel != nil, !applying else { return }
        sendTask?.cancel()
        let wait = max(0, 0.05 - Date().timeIntervalSince(lastSend))
        sendTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.sendChanges()
        }
    }

    func flushNow() {
        guard channel != nil else { return }
        sendTask?.cancel()
        sendChanges()
        Collab.shared.syncShared()
    }

    private func sendChanges() {
        guard let s = library?.song(songID) else { return }
        var ch: [String: JSONValue] = [:]
        for k in Self.fields {
            let now = Self.value(s, k), old = snap[k] ?? ""
            if let p = Self.diff(old, now) { ch[k] = p; snap[k] = now }
        }
        lastSend = Date()
        if !ch.isEmpty {
            send("p", ["who": .string(session?.myName ?? ""), "u": .number(s.updated), "ch": .object(ch)])
        } else if s.rich != snapRich {
            // formatting changed without the words changing: sent whole
            send("fmt", ["u": .number(s.updated), "txt": .string(s.lyrics), "h": .string(s.rich)])
        }
        snapRich = s.rich
    }

    /// File changes (sfTouch) go to everyone straight away.
    func filesChanged() {
        guard let s = library?.song(songID) else { return }
        send("files", ["rm": s.raw["rmFiles"] ?? .object([:]), "audio": s.raw["audio"] ?? .array([]), "files": s.raw["files"] ?? .array([])])
    }

    private func send(_ event: String, _ body: [String: JSONValue]) {
        guard let ch = channel else { return }
        var b = body
        b["id"] = .string(songID); b["dev"] = .string(Self.dev)
        guard let obj = Self.anyJSON(.object(b)) else { return }
        Task { await ch.broadcast(event: event, message: obj) }
    }

    static func sendGone(_ songID: String) async {
        guard let ch = active[songID] else { return }
        if let obj = anyJSON(.object(["id": .string(songID), "dev": .string(dev)])) { await ch.broadcast(event: "gone", message: obj) }
    }

    // MARK: receiving

    private func receive(_ event: String, _ x: [String: JSONValue]) {
        guard x["id"]?.string == songID, x["dev"]?.string != Self.dev, let library else { return }
        switch event {
        case "p":
            guard let ch = x["ch"]?.object else { return }
            if bridge?.textView?.markedTextRange != nil {
                // mid-composition (IME): try again in a moment
                Task { try? await Task.sleep(for: .milliseconds(300)); self.receive(event, x) }
                return
            }
            var failed = false
            applying = true
            defer { applying = false }
            for (k, pv) in ch {
                guard Self.fields.contains(k), let p = pv.object else { continue }
                if k == "lyrics" {
                    guard let tv = bridge?.textView, let r = Self.patch(tv.text ?? "", p) else { failed = true; continue }
                    bridge?.applyRemote(at: r.at, delete: (p["d"]?.string ?? "").utf16.count, insert: p["i"]?.string ?? "")
                    if let sp = Self.patch(snap[k] ?? "", p) { snap[k] = sp.text } else { snap[k] = tv.text ?? "" }
                } else {
                    guard var s = library.song(songID), let r = Self.patch(Self.value(s, k), p) else { failed = true; continue }
                    s.raw[k] = .string(r.text)
                    library.put(s)
                    if let sp = Self.patch(snap[k] ?? "", p) { snap[k] = sp.text } else { snap[k] = r.text }
                }
            }
            if var s = library.song(songID) {
                s.updated = max(s.updated, x["u"]?.number ?? 0)
                if let who = x["who"]?.string, !who.isEmpty { s.raw["lastEditBy"] = .string(who) }
                if Self.fields.allSatisfy({ Self.value(s, $0) == (snap[$0] ?? "") }) { s.raw["_pushed"] = .number(s.updated) }
                library.put(s)
            }
            // the editor rewrote its formatting for the patched text: that isn't a change to send back
            if let now = library.song(songID) { snapRich = now.rich }
            showWriting(x["who"]?.string)
            if failed { send("need", [:]) }
        case "fmt":
            guard var s = library.song(songID), s.lyrics == x["txt"]?.string, let h = x["h"]?.string else { return }
            applying = true
            s.rich = h
            s.updated = max(s.updated, x["u"]?.number ?? 0)
            bridge?.lastEdit = .distantPast
            library.put(s)
            snapRich = h
            applying = false
        case "need":
            guard let s = library.song(songID), Date().timeIntervalSince(lastFull) > 0.8 else { return }
            if let u = x["u"]?.number, s.updated < u { return }
            lastFull = Date()
            var f: [String: JSONValue] = [:]
            for k in Self.fields { f[k] = .string(Self.value(s, k)) }
            f["rich"] = .string(s.rich)
            send("full", ["who": .string(session?.myName ?? ""), "u": .number(s.updated), "f": .object(f)])
        case "full":
            guard let f = x["f"]?.object, var s = library.song(songID) else { return }
            let pending = Self.fields.contains { Self.value(s, $0) != (snap[$0] ?? "") }
            if pending {
                // my unsent changes go first, then ask again
                sendChanges()
                Task { try? await Task.sleep(for: .milliseconds(400)); self.send("need", [:]) }
                return
            }
            let u = x["u"]?.number ?? 0
            let same = Self.fields.allSatisfy { (f[$0]?.string ?? "") == Self.value(s, $0) } && (f["rich"]?.string ?? "") == s.rich
            if s.updated > u && same { return }
            if same { return }
            applying = true
            for k in Self.fields { s.raw[k] = .string(f[k]?.string ?? "") }
            s.rich = f["rich"]?.string ?? ""
            s.updated = max(s.updated, u)
            s.raw["_pushed"] = .number(s.updated)
            if let who = x["who"]?.string, !who.isEmpty { s.raw["lastEditBy"] = .string(who) }
            bridge?.lastEdit = .distantPast
            library.put(s)
            takeSnapshot(s)
            applying = false
            showWriting(x["who"]?.string)
        case "files":
            guard var s = library.song(songID) else { return }
            if Collab.fileMerge(&s, rm: x["rm"]?.object ?? [:], audio: x["audio"]?.array ?? [], files: x["files"]?.array ?? []) {
                library.put(s)
            }
        case "gone":
            Task { try? await Task.sleep(for: .seconds(1.5)); await Collab.shared.goneCheck() }
        default: break
        }
    }

    private func showWriting(_ who: String?) {
        guard let who, !who.isEmpty else { return }
        writing = who.components(separatedBy: CharacterSet(charactersIn: " @")).first.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        writingTask?.cancel()
        writingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.writing = nil }
        }
    }

    // MARK: patches on UTF-16 (liveDiff / livePatch)

    static func diff(_ a: String, _ b: String) -> JSONValue? {
        if a == b { return nil }
        let A = Array(a.utf16), B = Array(b.utf16)
        let n = min(A.count, B.count)
        var p = 0
        while p < n && A[p] == B[p] { p += 1 }
        var q = 0
        while q < n - p && A[A.count - 1 - q] == B[B.count - 1 - q] { q += 1 }
        func str(_ x: ArraySlice<UInt16>) -> String { String(decoding: x, as: UTF16.self) }
        return .object([
            "f": .number(Double(p)),
            "d": .string(str(A[p..<(A.count - q)])),
            "i": .string(str(B[p..<(B.count - q)])),
            "c": .string(str(A[max(0, p - 16)..<p])),
            "a": .string(str(A[(A.count - q)..<min(A.count, A.count - q + 16)]))
        ])
    }

    /// Applies a patch where it belongs, even if text nearby changed; nil if it can't be placed.
    static func patch(_ text: String, _ P: [String: JSONValue]) -> (text: String, at: Int)? {
        let t = Array(text.utf16)
        let A = Array((P["a"]?.string ?? "").utf16), C = Array((P["c"]?.string ?? "").utf16)
        let D = Array((P["d"]?.string ?? "").utf16), I = Array((P["i"]?.string ?? "").utf16)
        let f = Int(P["f"]?.number ?? 0)
        func fits(_ q: Int) -> Bool { q >= 0 && q <= t.count && q + D.count <= t.count && Array(t[q..<(q + D.count)]) == D }
        func matchAt(_ q: Int, _ x: [UInt16]) -> Bool { q >= 0 && q + x.count <= t.count && Array(t[q..<(q + x.count)]) == x }
        func build(_ at: Int) -> (String, Int) {
            let at = min(max(0, at), t.count), end = min(t.count, at + D.count)
            let out = Array(t[0..<at]) + I + Array(t[end...])
            return (String(decoding: out, as: UTF16.self), at)
        }
        if fits(f) && matchAt(max(0, f - C.count), Array(C.suffix(min(C.count, f)))) && C.count <= f && matchAt(f + D.count, A) { return build(f) }
        var best = -1, bd = Int.max
        func cand(_ q: Int) { if fits(q) { let dd = abs(q - f); if dd < bd { bd = dd; best = q } } }
        func scan(_ key: [UInt16], _ toPos: (Int) -> Int) {
            guard !key.isEmpty, key.count <= t.count else { return }
            for k in 0...(t.count - key.count) where t[k] == key[0] && Array(t[k..<(k + key.count)]) == key { cand(toPos(k)) }
        }
        var n = C.count
        while n >= 3 && best < 0 { let key = Array(C.suffix(n)) + D; let nn = n; scan(key) { $0 + nn }; n = n > 8 ? 8 : n - 2 }
        var m = A.count
        while m >= 3 && best < 0 { scan(D + Array(A.prefix(m))) { $0 }; m = m > 8 ? 8 : m - 2 }
        if best < 0 && C.isEmpty && A.isEmpty { best = min(f, t.count) }
        guard best >= 0 else { return nil }
        return build(best)
    }

    // MARK: JSON bridges

    static func json(_ v: AnyJSON?) -> [String: JSONValue]? {
        guard let v, let d = try? JSONEncoder().encode(v) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: d))?.object
    }

    static func anyJSON(_ v: JSONValue) -> JSONObject? {
        guard let d = try? JSONEncoder().encode(v) else { return nil }
        return try? JSONDecoder().decode(JSONObject.self, from: d)
    }
}
