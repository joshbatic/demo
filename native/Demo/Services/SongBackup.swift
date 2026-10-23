import Foundation

// MARK: - folders (spec §3.6)

extension LibraryStore {
    /// Every folder name in use.
    var folderNames: [String] {
        var seen = Set<String>(), out: [String] = []
        for s in songs.sorted(by: { $0.updated > $1.updated }) where !s.folder.isEmpty && !seen.contains(s.folder) {
            seen.insert(s.folder); out.append(s.folder)
        }
        return out
    }

    /// "New Folder", "New Folder 2"… whichever is free.
    func freeFolderName() -> String {
        let names = Set(songs.map(\.folder))
        var f = "New Folder", n = 1
        while names.contains(f) { n += 1; f = "New Folder \(n)" }
        return f
    }

    /// createFolder: a placeholder song (`ph`) so the empty folder shows. Returns the folder's name.
    @discardableResult
    func createFolder() -> String {
        let f = freeFolderName()
        var s = Song.new(artist: "", folder: f)
        s.raw["artist"] = nil
        s.raw["ph"] = 1
        add(s)
        return f
    }

    /// renameFolder: every song in it gets the new name. Returns how many moved, or nil when ignored.
    func renameFolder(_ old: String, to new: String) -> Int? {
        let nv = new.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !nv.isEmpty, nv != old, nv != "Unfiled", nv != "Songs" else { return nil }
        var n = 0
        for var s in songs where s.folder == old {
            s.folder = nv; s.touch(); put(s); n += 1
        }
        return n
    }

    /// moveSongToFolder: "" is no folder. Drops an empty placeholder left behind in the target.
    func move(_ id: String, to folder: String) {
        guard var s = song(id), s.folder != folder else { return }
        s.folder = folder
        s.raw.removeValue(forKey: "ph")
        s.touch()
        put(s)
        for x in songs where x.id != id && x.isPlaceholder && x.folder == folder && x.title.isEmpty
            && x.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            delete(x.id)
        }
    }
}

// MARK: - import / export (spec §3.7)

extension LibraryStore {
    /// importSongs: returns (added, updated, skipped).
    func importSongs(_ list: [JSONValue]) -> (Int, Int, Int) {
        var added = 0, upd = 0, skip = 0
        for v in list {
            guard var o = v.object, let id = o["id"], case .string = id else { skip += 1; continue }
            for k in ["shared", "owner", "members"] { o.removeValue(forKey: k) }
            for k in o.keys where k.hasPrefix("_") { o.removeValue(forKey: k) }
            for k in ["title", "lyrics", "rich", "chords", "notes", "artist", "folder", "status", "key", "bpm", "tuning", "capo", "time"] {
                if let x = o[k] { switch x { case .string, .null: break; default: o[k] = .string(x.string ?? "") } }
            }
            if o["lyrics"] == nil || o["lyrics"]!.isNull { o["lyrics"] = "" }
            let was = o["updated"]?.number ?? 0
            for k in ["credits", "audio", "files", "versions"] where o[k] != nil && o[k]!.array == nil { o.removeValue(forKey: k) }
            // a restored song is "edited now", so a deletion recorded before the restore doesn't remove it again
            o["updated"] = .number(Clock.nowMs)
            let s = Song(raw: o)
            if let ex = song(s.id) {
                if !ex.isShared && was > ex.updated { put(s); upd += 1 } else { skip += 1 }
            } else {
                add(s); added += 1
            }
        }
        return (added, upd, skip)
    }

    /// Reads picked files (JSON backups, single songs, or plain text) and imports them. Returns the toast.
    func importFiles(_ urls: [URL]) -> String {
        var all: [JSONValue] = [], bad = 0
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: u), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { bad += 1; continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if u.pathExtension.lowercased() == "json" || trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
                guard let d = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { bad += 1; continue }
                if let a = d.array { all += a } else if let a = d["songs"]?.array { all += a } else { all.append(d) }
            } else {
                all.append(.object(SongBackup.fromText(text, name: u.lastPathComponent)))
            }
        }
        let r = importSongs(all)
        var t = r.0 > 0 ? "\(r.0) song\(r.0 > 1 ? "s" : "") added" : "No new songs"
        if r.1 > 0 { t += ", \(r.1) updated" }
        if r.2 > 0 { t += ", \(r.2) already here" }
        if bad > 0 { t += ", \(bad) file\(bad > 1 ? "s" : "") unreadable" }
        return t
    }

    /// Writes the backup to a temporary file for the share sheet; nil when there's nothing to export.
    func exportFile() -> URL? {
        let mine = songs.filter { !$0.isShared }
        guard !mine.isEmpty else { return nil }
        let day = String(LibraryStore.iso(Date()).prefix(10))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("*[demo] backup \(day).json")
        guard let data = SongBackup.backupJSON(mine), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
}

enum SongBackup {
    /// backupJSON: {"app":"*[demo]","saved":<ISO>,"songs":[…]} without device-only `_` keys.
    static func backupJSON(_ songs: [Song]) -> Data? {
        let obj: JSONValue = .object(["app": "*[demo]", "saved": .string(LibraryStore.iso(Date())), "songs": .array(songs.map(\.cloudJSON))])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try? enc.encode(obj)
    }

    /// fromText (engines.md §3.6): title, an optional details line, lyrics, then --- Chords --- / --- Notes ---.
    static func fromText(_ raw: String, name: String) -> [String: JSONValue] {
        let txt = raw.replacingOccurrences(of: "\r", with: "")
        let L = txt.components(separatedBy: "\n")
        var title = (L.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var i = 1
        var meta: [String: JSONValue] = [:]
        if L.count > 1, L[1].range(of: #" · |^(by |Key: |Status: |Capo: |Tuning: )|BPM"#, options: .regularExpression) != nil {
            for p in L[1].components(separatedBy: " · ") {
                if p.hasPrefix("by ") { meta["artist"] = .string(String(p.dropFirst(3))) }
                else if p.hasPrefix("Key: ") { meta["key"] = .string(String(p.dropFirst(5))) }
                else if let m = p.firstMatch(of: #/^(\d+) BPM/#) { meta["bpm"] = .string(String(m.1)) }
                else if p.hasPrefix("Capo: ") { meta["capo"] = .string(String(p.dropFirst(6))) }
                else if p.hasPrefix("Tuning: ") { meta["tuning"] = .string(String(p.dropFirst(8))) }
                else if p.hasPrefix("Status: ") { meta["status"] = .string(String(p.dropFirst(8))) }
            }
            i = 2
        }
        var body = L.dropFirst(i).joined(separator: "\n")
        while body.hasPrefix("\n") { body.removeFirst() }
        var ch = "", nt = ""
        if let r = body.range(of: "\n--- Notes ---\n") {
            nt = String(body[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines); body = String(body[..<r.lowerBound])
        }
        if let r = body.range(of: "\n--- Chords ---\n") {
            ch = String(body[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines); body = String(body[..<r.lowerBound])
        }
        if title.isEmpty || title.count > 80 {
            body = txt
            title = name.replacingOccurrences(of: #"\.[^.]+$"#, with: "", options: .regularExpression)
            if title.isEmpty { title = "Imported" }
        }
        while let last = body.last, last.isWhitespace { body.removeLast() }
        let now = Clock.nowMs
        var o: [String: JSONValue] = [
            "id": .string("s\(Int64(now))\(Int.random(in: 0..<10_000))"), "title": .string(title), "lyrics": .string(body),
            "chords": .string(ch), "notes": .string(nt), "status": "Idea", "folder": "", "updated": .number(now)
        ]
        for (k, v) in meta { o[k] = v }
        return o
    }
}
