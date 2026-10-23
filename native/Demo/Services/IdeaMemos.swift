import Foundation

nonisolated extension Idea {
    /// The voice memo, shaped like a file item so the player and storage helpers can use it.
    var memo: FileItem? { raw["memo"]?.object.map(FileItem.init) }
    var usedSongID: String? { raw["used"]?.string }
    var created: Double { raw["created"]?.number ?? updated }
}

/// Idea voice memos and "Start a Song" (spec §5, data spec §1.5).
@MainActor
enum IdeaMemos {
    static let freeLimit = 10

    /// Keeps a finished recording as an idea: on the device first (`local:`, `pend`), then uploaded for Pro.
    @discardableResult
    static func save(_ url: URL, dur: Double, text: String, library: LibraryStore, session: AppSession) async -> Bool {
        guard dur >= 0.6 else {
            try? FileManager.default.removeItem(at: url)
            session.toast = "That was too short to keep."
            return false
        }
        let memoID = UUID().uuidString.lowercased()
        let dest = SongFiles.localURL(memoID, ext: "m4a")
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: url, to: dest) } catch {
            session.toast = "Couldn’t save the recording."
            return false
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let p = SongFiles.peaks60(await SongFiles.peaks(dest))
        let now = Clock.nowMs
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let idea = Idea(raw: [
            "id": .string(UUID().uuidString.lowercased()), "text": .string(t), "kind": .string(t.isEmpty ? "memo" : "line"),
            "tags": .array([]), "created": .number(now), "updated": .number(now),
            "memo": .object(["id": .string(memoID), "path": .string("local:\(memoID)"), "mime": "audio/mp4",
                             "size": .number(size), "dur": .number((dur * 10).rounded() / 10),
                             "peaks": .array(p.map { .number(Double($0)) }), "pend": true])
        ])
        library.putIdea(idea)
        Haptics.success()
        session.toast = "Voice memo saved"
        await upload(idea.id, library: library, session: session)
        return true
    }

    /// Uploads a memo still on the device (Pro and signed in only; Free memos stay on the device).
    static func upload(_ ideaID: String, library: LibraryStore, session: AppSession) async {
        guard session.plan.isPro, let uid = session.userID,
              let idea = library.ideas.first(where: { $0.id == ideaID }), let m = idea.memo, m.isLocal,
              let file = SongFiles.localFile(for: m), let data = try? Data(contentsOf: file) else { return }
        let memoID = String(m.path.dropFirst("local:".count))
        let path = "\(uid)/ideas/\(memoID).m4a"
        do {
            try await SongFiles.upload(data, to: path, mime: m.mime.isEmpty ? "audio/mp4" : m.mime, upsert: true)
        } catch { return }   // retried next time Ideas opens
        guard var now = library.ideas.first(where: { $0.id == ideaID }), var memo = now.raw["memo"]?.object else { return }
        memo["path"] = .string(path)
        memo.removeValue(forKey: "pend")
        now.raw["memo"] = .object(memo)
        now.updated = Clock.nowMs
        library.putIdea(now)
        try? FileManager.default.removeItem(at: file)
    }

    /// Pending memos are retried whenever Ideas shows (data spec §4.2).
    static func uploadPending(library: LibraryStore, session: AppSession) async {
        guard session.plan.isPro, session.userID != nil else { return }
        for i in library.ideas where i.memo?.isLocal == true { await upload(i.id, library: library, session: session) }
    }

    /// Deleting an idea deletes its recording too.
    static func deleteFile(_ m: FileItem?) {
        guard let m else { return }
        if AudioPlayer.shared.key?.hasSuffix(m.id) == true { AudioPlayer.shared.stop() }
        if m.isLocal { if let u = SongFiles.localFile(for: m) { try? FileManager.default.removeItem(at: u) } }
        else { Task { await SongFiles.remove(m.path) } }
    }

    static func memoCount(_ library: LibraryStore) -> Int { library.ideas.filter { $0.memo != nil }.count }

    /// Start a Song (ideaToSong): a new song from the idea's text; a memo becomes its first audio (Pro).
    static func startSong(_ idea: Idea, library: LibraryStore, session: AppSession) async -> String {
        var s = Song.new(artist: session.myName)
        let t = idea.text
        switch idea.kind {
        case "idea":
            let first = t.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if first.count <= 60 { s.title = first }
            s.notes = t
        case "concept":
            s.notes = t
            s.raw["brief"] = .object(["more": .string(String(t.prefix(600)))])
        default:
            if !t.isEmpty { s.lyrics = t + "\n" }
        }
        s.status = "Idea"
        var withMemo = false
        if let m = idea.memo {
            if session.plan.isPro {
                let newID = UUID().uuidString.lowercased()
                var path = ""
                do {
                    if let uid = session.userID {
                        path = "\(uid)/\(s.id)/\(newID).m4a"
                        if m.isLocal, let f = SongFiles.localFile(for: m), let data = try? Data(contentsOf: f) {
                            try await SongFiles.upload(data, to: path, mime: "audio/mp4")
                        } else {
                            try await SongFiles.copy(m.path, to: path)
                        }
                    } else if let f = SongFiles.localFile(for: m) {
                        path = "local:\(newID)"
                        try FileManager.default.copyItem(at: f, to: SongFiles.localURL(newID, ext: "m4a"))
                    }
                    if !path.isEmpty {
                        var a = m.raw
                        a["id"] = .string(newID); a["path"] = .string(path); a["kind"] = "Voice memo"; a["cur"] = true
                        a["name"] = .string(t.isEmpty ? "Voice memo" : String(t.components(separatedBy: "\n")[0].prefix(40)))
                        a["added"] = .number(Clock.nowMs)
                        a.removeValue(forKey: "pend")
                        if (m.peaks.count) < 180, let f = try? await SongFiles.playableURL(FileItem(raw: a)) {
                            a["peaks"] = .array(await SongFiles.peaks(f).map { .number(Double($0)) })
                        }
                        s.audioItems = [FileItem(raw: a)]
                        withMemo = true
                    }
                } catch {
                    session.toast = "Couldn’t add the voice memo: " + SongFiles.message(error)
                }
            } else {
                session.upsell("audio", "Your voice memo stays in Ideas. Pro adds recordings to songs.")
            }
        }
        s.touch()
        library.add(s)
        var used = idea
        used.raw["used"] = .string(s.id)
        used.updated = Clock.nowMs
        library.putIdea(used)
        Haptics.success()
        if withMemo || idea.memo == nil || session.plan.isPro {
            session.toast = withMemo ? "New song from your voice memo" : "New song from your idea"
        }
        return s.id
    }
}
