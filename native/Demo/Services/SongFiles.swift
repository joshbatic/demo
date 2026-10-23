import Foundation
import AVFoundation
import Supabase

/// An audio version or an attached file on a song (data spec §1.4.1–1.4.2), kept as raw JSON so unknown keys survive.
nonisolated struct FileItem: Identifiable, Hashable {
    var raw: [String: JSONValue]
    var id: String { raw["id"]?.string ?? "" }
    var name: String { get { raw["name"]?.string ?? "" } set { raw["name"] = .string(newValue) } }
    var path: String { raw["path"]?.string ?? "" }
    var kind: String { get { raw["kind"]?.string ?? "Other" } set { raw["kind"] = .string(newValue) } }
    var size: Double { raw["size"]?.number ?? 0 }
    var mime: String { raw["mime"]?.string ?? "" }
    var dur: Double { raw["dur"]?.number ?? 0 }
    var isCurrent: Bool { get { raw["cur"]?.bool ?? false } set { raw["cur"] = .bool(newValue) } }
    var peaks: [Double] { (raw["peaks"]?.array ?? []).compactMap(\.number) }
    var isLocal: Bool { path.hasPrefix("local:") }
    /// The uploader is the first path segment.
    func isMine(_ uid: String?) -> Bool { isLocal || (uid != nil && path.split(separator: "/").first.map(String.init) == uid) }
    var origExt: String? {
        guard let n = raw["orig"]?["name"]?.string, let e = n.split(separator: ".").last, n.contains(".") else { return nil }
        return e.uppercased()
    }
    var ext: String { (path.split(separator: ".").last.map(String.init) ?? "").lowercased() }
}

nonisolated extension Song {
    var audioItems: [FileItem] {
        get { (raw["audio"]?.array ?? []).compactMap { $0.object.map(FileItem.init) } }
        set { raw["audio"] = .array(newValue.map { .object($0.raw) }) }
    }
    var fileItems: [FileItem] {
        get { (raw["files"]?.array ?? []).compactMap { $0.object.map(FileItem.init) } }
        set { raw["files"] = .array(newValue.map { .object($0.raw) }) }
    }
    /// The ticked version, else the newest (spec §4.10).
    var currentAudio: FileItem? { audioItems.first(where: \.isCurrent) ?? audioItems.last }

    /// Records a file deletion so co-writers' copies drop it too (rmFiles, data spec §3.6).
    mutating func tombstoneFile(_ id: String) {
        var rm = raw["rmFiles"]?.object ?? [:]
        rm[id] = .number(Clock.nowMs)
        raw["rmFiles"] = .object(rm)
    }

    /// Lyric timings (data spec §1.4.3).
    struct SyncLine: Hashable { var text: String; var t: Double? }
    var syncAudioID: String? { raw["sync"]?["audioId"]?.string }
    var syncLines: [SyncLine] {
        (raw["sync"]?["lines"]?.array ?? []).compactMap { v in
            guard let o = v.object else { return nil }
            return SyncLine(text: o["text"]?.string ?? "", t: o["t"]?.number)
        }
    }
    var syncSig: String { raw["sync"]?["sig"]?.string ?? "" }
    /// The lines sync works on: non-blank, not [Section] tags.
    var syncableLines: [String] {
        lyrics.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("[") }
    }
    var syncIsStale: Bool { !syncSig.isEmpty && syncSig != syncableLines.joined(separator: "\n") }
}

/// Song audio and files in Supabase Storage, plus the on-device copies (data spec §4).
nonisolated enum SongFiles {
    static let bucket = "song-files"
    static let audioKinds = ["Voice memo", "Demo", "Mix", "Master", "Other"]
    static let fileKinds = ["Stem", "Artwork", "Session", "Other"]

    // MARK: guesses

    static func audioKind(_ name: String) -> String {
        let n = name.lowercased()
        if n.range(of: "voice|memo|recording", options: .regularExpression) != nil { return "Voice memo" }
        if n.contains("master") { return "Master" }
        if n.contains("mix") { return "Mix" }
        return "Demo"
    }

    static func fileKind(_ name: String, mime: String) -> String {
        let n = name.lowercased()
        if n.range(of: "stem|vox|vocal|drum|bass|guitar|keys|synth|perc", options: .regularExpression) != nil { return "Stem" }
        if mime.hasPrefix("image/") { return "Artwork" }
        if n.range(of: #"\.(logicx|als|flp|ptx|rpp|band|cpr|song|zip)$"#, options: .regularExpression) != nil { return "Session" }
        return "Other"
    }

    /// The extension from the name (1–6 letters/digits), else the MIME subtype (sfExt).
    static func ext(_ name: String, mime: String) -> String {
        if let m = name.lowercased().firstMatch(of: #/\.([a-z0-9]{1,6})$/#) { return String(m.1) }
        let sub = mime.split(separator: "/").last.map(String.init) ?? "bin"
        let clean = sub.lowercased().filter { $0.isLetter || $0.isNumber }
        return clean.isEmpty ? "bin" : String(clean.prefix(6))
    }

    static func mime(forExt e: String) -> String {
        switch e.lowercased() {
        case "mp3": "audio/mpeg"; case "m4a", "mp4", "aac": "audio/mp4"; case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"; case "flac": "audio/flac"; case "caf": "audio/x-caf"
        case "ogg": "audio/ogg"; case "webm": "audio/webm"; case "png": "image/png"; case "jpg", "jpeg": "image/jpeg"
        case "pdf": "application/pdf"; case "zip": "application/zip"
        default: "application/octet-stream"
        }
    }

    static func needsConversion(_ ext: String) -> Bool { ["wav", "aif", "aiff", "flac"].contains(ext.lowercased()) }

    static func baseName(_ fileName: String) -> String {
        let n = (fileName as NSString).deletingPathExtension
        return n.isEmpty ? fileName : n
    }

    // MARK: formatting (sfSize, sfTime)

    static func size(_ n: Double) -> String {
        guard n > 0 else { return "" }
        if n >= 1_073_741_824 {
            let g = n / 1_073_741_824
            return (g < 10 && g.rounded() != g ? String(format: "%.1f", g) : String(Int(g.rounded()))) + " GB"
        }
        if n < 1_048_576 { return "\(max(1, Int((n / 1024).rounded()))) KB" }
        return String(format: n < 10_485_760 ? "%.1f MB" : "%.0f MB", n / 1_048_576)
    }

    static func time(_ sec: Double) -> String {
        let s = max(0, sec.isFinite ? sec : 0)
        return "\(Int(s) / 60):" + String(format: "%02d", Int(s) % 60)
    }

    // MARK: on-device files

    /// Bytes that only live on this device (`local:` items, memos not uploaded yet).
    static func localURL(_ id: String, ext: String) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "files", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: id + (ext.isEmpty ? "" : "." + ext))
    }

    static func localFile(for item: FileItem) -> URL? {
        let id = String(item.path.dropFirst("local:".count))
        let dir = URL.applicationSupportDirectory.appending(path: "files", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == id }
    }

    /// The audio cache: up to 500 MB, files over 60 MB aren't kept, trimmed to 85% oldest-first.
    static let cacheLimit: Int64 = 500 * 1_048_576
    static let cacheFileLimit = 60 * 1_048_576

    static func cacheURL(_ path: String) -> URL {
        let dir = URL.cachesDirectory.appending(path: "audio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = path.replacingOccurrences(of: "/", with: "_")
        return dir.appending(path: safe)
    }

    static func cache(_ data: Data, for path: String) {
        guard data.count <= cacheFileLimit else { return }
        let url = cacheURL(path)
        try? data.write(to: url, options: .atomic)
        trimCache()
    }

    static func trimCache() {
        let dir = URL.cachesDirectory.appending(path: "audio", directoryHint: .isDirectory)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { u -> (URL, Int64, Date)? in
            guard let v = try? u.resourceValues(forKeys: keys) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentAccessDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > cacheLimit else { return }
        entries.sort { $0.2 < $1.2 }
        for e in entries where total > cacheLimit * 85 / 100 {
            try? FileManager.default.removeItem(at: e.0)
            total -= e.1
        }
    }

    // MARK: storage

    private static var storage: StorageFileApi { Backend.client.storage.from(bucket) }

    /// Signed links, kept until a minute before they expire.
    private static let urlCache = SignedURLCache()

    static func signedURL(_ path: String) async throws -> URL {
        if let u = await urlCache.get(path) { return u }
        let u = try await storage.createSignedURL(path: path, expiresIn: 3600)
        await urlCache.put(path, u, expires: Date().addingTimeInterval(3600 - 60))
        return u
    }

    /// Something AVPlayer or Quick Look can open: the device copy, the cache, or (for big files) a signed link.
    /// Small files are downloaded into the cache the first time.
    static func playableURL(_ item: FileItem) async throws -> URL {
        if item.isLocal {
            guard let u = localFile(for: item) else { throw FileError.missing }
            return u
        }
        let cached = cacheURL(item.path)
        if FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
            return cached
        }
        if item.size > 0 && item.size > Double(cacheFileLimit) { return try await signedURL(item.path) }
        let data = try await storage.download(path: item.path)
        if data.count <= cacheFileLimit {
            cache(data, for: item.path)
            return cached
        }
        return try await signedURL(item.path)
    }

    /// A file opened with its own name (for Quick Look and sharing).
    static func namedCopy(_ item: FileItem) async throws -> URL {
        let src = try await playableURL(item)
        let dir = FileManager.default.temporaryDirectory.appending(path: item.id, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = item.name.isEmpty ? item.id : item.name
        let dest = dir.appending(path: name.hasSuffix("." + item.ext) || item.ext.isEmpty ? name : name + "." + item.ext)
        try? FileManager.default.removeItem(at: dest)
        if src.isFileURL {
            try FileManager.default.copyItem(at: src, to: dest)
        } else {
            let (tmp, _) = try await URLSession.shared.download(from: src)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        return dest
    }

    /// Whether there's room to upload `bytes` more (sfRoom: my_storage, cached 30 s).
    static func checkRoom(_ bytes: Int) async throws {
        if await MainActor.run(body: { RemoteConfig.shared.uploadsOff }) { throw FileError.paused }
        if let st = try? await storageState(), let limit = st.limit, st.used + Int64(bytes) > limit {
            throw FileError.full(limit)
        }
    }

    struct StorageState { var used: Int64; var limit: Int64? }
    private static let stateCache = StateCache()

    static func storageState(force: Bool = false) async throws -> StorageState {
        if !force, let s = await stateCache.get() { return s }
        let v = try await Backend.rpc("my_storage")
        let row = v.array?.first ?? v
        let s = StorageState(used: Int64(row["used_bytes"]?.number ?? 0), limit: row["limit_bytes"]?.number.map { Int64($0) })
        await stateCache.put(s)
        return s
    }

    static func upload(_ data: Data, to path: String, mime: String, upsert: Bool = false) async throws {
        try await checkRoom(data.count)
        _ = try await storage.upload(path, data: data, options: FileOptions(contentType: mime.isEmpty ? "application/octet-stream" : mime, upsert: upsert))
        await stateCache.add(Int64(data.count))
        if mime.hasPrefix("audio/") { cache(data, for: path) }
    }

    static func remove(_ path: String) async {
        guard !path.isEmpty, !path.hasPrefix("local:") else { return }
        _ = try? await storage.remove(paths: [path])
        try? FileManager.default.removeItem(at: cacheURL(path))
    }

    static func copy(_ from: String, to: String) async throws {
        _ = try await storage.copy(from: from, to: to)
    }

    // MARK: audio processing

    /// Duration in seconds, to one decimal.
    static func duration(_ url: URL) async -> Double {
        guard let d = try? await AVURLAsset(url: url).load(.duration) else { return 0 }
        let s = CMTimeGetSeconds(d)
        return s.isFinite ? (s * 10).rounded() / 10 : 0
    }

    /// The waveform: `bins` peaks 0–100, `round((v/max)^0.7 * 100)` (spec §4.10).
    static func peaks(_ url: URL, bins: Int = 180) async -> [Int] {
        await Task.detached(priority: .utility) { () async -> [Int] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else { return [] }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                           AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000]
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(out)
            guard reader.startReading() else { return [] }
            var samples: [Int16] = []
            samples.reserveCapacity(8000 * 240)
            while let buf = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
                let len = CMBlockBufferGetDataLength(block)
                var chunk = [Int16](repeating: 0, count: len / 2)
                chunk.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: p.baseAddress!) }
                samples.append(contentsOf: chunk)
            }
            guard !samples.isEmpty else { return [] }
            let per = max(1, samples.count / bins)
            var raw: [Double] = []
            for b in 0..<bins {
                let lo = b * per, hi = min(samples.count, lo + per)
                guard lo < hi else { raw.append(0); continue }
                var m: Int32 = 0
                for i in lo..<hi { m = max(m, abs(Int32(samples[i]))) }
                raw.append(Double(m))
            }
            let mx = raw.max() ?? 0
            guard mx > 0 else { return raw.map { _ in 0 } }
            return raw.map { Int((pow($0 / mx, 0.7) * 100).rounded()) }
        }.value
    }

    /// 60 peaks taken from the 180 (idea memos).
    static func peaks60(_ p180: [Int]) -> [Int] {
        guard p180.count >= 60 else { return p180 }
        return (0..<60).map { i in p180[(i * 3)..<min(p180.count, i * 3 + 3)].max() ?? 0 }
    }

    /// WAV / AIFF / FLAC are converted before upload: to MP3 with LAME (like the web), else AAC.
    /// Returns the new file and its extension and MIME type.
    static func convertForUpload(_ src: URL) async throws -> (URL, String, String) {
        if MP3.available, let u = try? await MP3.encode(src) { return (u, "mp3", "audio/mpeg") }
        return (try await convertToAAC(src), "m4a", "audio/mp4")
    }

    /// The format conversions turn into: "MP3", or "AAC" without LAME.
    static var convertName: String { MP3.available ? "MP3" : "AAC" }

    /// WAV / AIFF / FLAC to AAC (.m4a), when LAME isn't there.
    static func convertToAAC(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw FileError.convert }
        let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        try await ex.export(to: dest, as: .m4a)
        return dest
    }

    // MARK: errors (sfErr)

    enum FileError: Error { case missing, full(Int64), convert, paused }

    static func message(_ error: Error) -> String {
        if let f = error as? FileError {
            switch f {
            case .missing: return "that file isn’t on this device any more."
            case .full(let l): return "you’ve used all \(size(Double(l))) of your storage. Delete some audio or files to make room."
            case .convert: return "it couldn’t be converted."
            case .paused: return "adding music and files is paused for maintenance. Try again shortly."
            }
        }
        let m = "\(error) \((error as NSError).localizedDescription)".lowercased()
        if m.contains("paused for maintenance") { return "adding music and files is paused for maintenance. Try again shortly." }
        if m.contains("storage full") || m.contains("under limit") { return "you’ve used all of your storage. Delete some audio or files to make room." }
        if m.contains("bucket not found") { return "audio storage isn’t set up yet." }
        if m.contains("object not found") || m.contains("not_found") || m.contains("404") {
            return "that file isn’t in storage any more. It may have been replaced or deleted on another device, or it was shared by someone whose files you can’t open yet."
        }
        if m.contains("payload too large") || m.contains("maximum allowed size") || m.contains("too large") { return "it’s bigger than the upload limit." }
        if m.contains("row-level security") || m.contains("unauthori") || m.contains("not allowed") || m.contains("permission") { return "you don’t have access to that file." }
        if m.contains("network") || m.contains("offline") || m.contains("timed out") || m.contains("connection") { return "check your connection and try again." }
        return "something went wrong."
    }
}

private actor SignedURLCache {
    private var map: [String: (URL, Date)] = [:]
    func get(_ k: String) -> URL? { if let (u, e) = map[k], e > Date() { return u }; return nil }
    func put(_ k: String, _ u: URL, expires: Date) { map[k] = (u, expires) }
}

private actor StateCache {
    private var state: SongFiles.StorageState?
    private var at = Date.distantPast
    func get() -> SongFiles.StorageState? { Date().timeIntervalSince(at) < 30 ? state : nil }
    func put(_ s: SongFiles.StorageState) { state = s; at = Date() }
    func add(_ n: Int64) { state?.used += n }
}
