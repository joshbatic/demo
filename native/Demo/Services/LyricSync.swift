import Foundation
import AVFoundation
import Observation
import Supabase

/// Times every lyric line to the current recording (engines.md §4): the audio goes to the `lyric-sync`
/// edge function (Whisper) in one-minute pieces, and the heard words are lined up with the lyrics.
@MainActor @Observable
final class LyricSync {
    static let shared = LyricSync()

    private(set) var busySong: String?
    private(set) var done = 0
    private(set) var total = 0

    func progressText(_ name: String) -> String {
        guard total > 0 else { return "Getting “\(name)” ready to listen to…" }
        return done >= total ? "Lining the words up with your lyrics…" : "Timing every line to “\(name)”: \(done) of \(total) minutes heard."
    }

    static let chunk = 60.0, overlap = 2.0, parallel = 4, wait: UInt64 = 90

    enum SyncError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    func run(songID: String, library: LibraryStore, session: AppSession) async {
        guard let song = library.song(songID), let a = song.currentAudio else { return }
        guard session.plan.isPro else { session.upsell("sync"); return }
        guard !RemoteConfig.shared.syncOff else { session.toast = RemoteConfig.syncOffMessage; return }
        do { try await AIService.shared.ensureConsent(ask: true) } catch { return }
        guard session.userID != nil else { session.toast = "Sign in to sync lyrics."; return }
        let lines = song.syncableLines
        guard lines.count >= 2 else { session.toast = "Write the lyrics first, then sync them to the audio."; return }
        guard a.dur <= 720 else { session.toast = "That track is too long to sync (over 12 minutes)."; return }
        busySong = songID; done = 0; total = 0
        defer { busySong = nil; done = 0; total = 0 }
        do {
            let url = try await SongFiles.playableURL(a)
            let local: URL
            if url.isFileURL { local = url } else { local = try await SongFiles.namedCopy(a) }
            let (pcm, dur) = try await Task.detached(priority: .userInitiated) { try Self.pcm16k(local) }.value
            guard dur <= 720 else { throw SyncError.message("That track is too long to sync (over 12 minutes).") }
            let words = try await listen(pcm, prompt: lines.joined(separator: "\n"))
            guard !words.isEmpty else { throw SyncError.message("no words could be heard in that track.") }
            let al = Self.align(lines, words)
            guard var s = library.song(songID) else { return }
            s.raw["sync"] = .object(["audioId": .string(a.id), "at": .number(Clock.nowMs), "sig": .string(lines.joined(separator: "\n")),
                                     "lines": .array(al.lines.map { .object(["text": .string($0.0), "t": .number($0.1)]) }),
                                     "timed": .number(Double(al.timed)), "total": .number(Double(al.total))])
            s.touch()
            library.put(s)
            Haptics.success()
            session.toast = Double(al.timed) < Double(al.total) * 0.4 ? "Synced, but the vocals were hard to make out, so some lines are estimates" : "Lyrics synced to “\(a.name)”"
        } catch {
            let m = (error as? SyncError)?.errorDescription ?? SongFiles.message(error)
            session.toast = "Couldn’t sync: " + m
        }
    }

    /// The track decoded and resampled to 16 kHz mono.
    nonisolated static func pcm16k(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw SyncError.message("that audio couldn’t be read.") }
        let dur = Double(file.length) / inFmt.sampleRate
        var out: [Float] = []
        out.reserveCapacity(Int(dur * 16000) + 16000)
        let inCap: AVAudioFrameCount = 32768
        var finished = false
        while !finished {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 16384) else { break }
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap) else { st.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuf)
                    if inBuf.frameLength == 0 { st.pointee = .endOfStream; return nil }
                    st.pointee = .haveData
                    return inBuf
                } catch { st.pointee = .endOfStream; return nil }
            }
            if let ch = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error || outBuf.frameLength == 0 { finished = true }
        }
        return (out, dur)
    }

    struct Word { var w: String; var s: Double }

    /// Sends the pieces, four at a time, and keeps each piece's words from its own minute.
    private func listen(_ pcm: [Float], prompt: String) async throws -> [Word] {
        let sr = 16000.0
        let n = max(1, Int((Double(pcm.count) / sr / Self.chunk).rounded(.up)))
        total = n; done = 0
        var results = [[Word]](repeating: [], count: n)
        try await withThrowingTaskGroup(of: (Int, [Word]).self) { g in
            var next = 0
            while next < min(Self.parallel, n) {
                let k = next; next += 1
                g.addTask { @MainActor in (k, try await self.piece(pcm, k: k, count: n, prompt: prompt)) }
            }
            while let r = try await g.next() {
                results[r.0] = r.1
                done += 1
                if next < n {
                    let k = next; next += 1
                    g.addTask { @MainActor in (k, try await self.piece(pcm, k: k, count: n, prompt: prompt)) }
                }
            }
        }
        return results.flatMap { $0 }
    }

    private func piece(_ pcm: [Float], k: Int, count: Int, prompt: String) async throws -> [Word] {
        let sr = 16000.0
        let total = Double(pcm.count) / sr
        let a = max(0, Double(k) * Self.chunk - Self.overlap), b = min(total, Double(k + 1) * Self.chunk + Self.overlap)
        let part = Array(pcm[Int(a * sr)..<min(pcm.count, Int((b * sr).rounded(.up)))])
        // a small 48 kbps MP3 like the web; WAV when LAME isn't there
        let mp3 = MP3.encodeMono(part, sampleRate: Int(sr), kbps: 48)
        let audio = mp3 ?? Self.wav16(part, sr: Int(sr))
        let name = mp3 != nil ? "part\(k).mp3" : "part\(k).wav"
        let type = mp3 != nil ? "audio/mpeg" : "audio/wav"
        func send() async throws -> JSONValue {
            try await withThrowingTaskGroup(of: JSONValue.self) { g in
                g.addTask { try await Self.post(audio, name: name, type: type, prompt: prompt) }
                g.addTask { try await Task.sleep(for: .seconds(Self.wait)); throw SyncError.message("the sync server took too long to answer. Try again in a moment.") }
                let r = try await g.next()!
                g.cancelAll()
                return r
            }
        }
        var d: JSONValue
        do { d = try await send() }
        catch {
            let m = (error as? SyncError)?.errorDescription ?? "\(error)"
            if m.range(of: "sign in|deployed|too long to sync|isn.t set up|limit|a minute|paused", options: [.regularExpression, .caseInsensitive]) != nil { throw error }
            d = try await send()
        }
        if let e = d["error"]?.string { throw SyncError.message(e) }
        let lo = Double(k) * Self.chunk, hi = Double(k + 1) * Self.chunk, len = b - a
        let bad = (d["segments"]?.array ?? []).compactMap { g -> (Double, Double)? in
            guard let ns = g["ns"]?.number, let lp = g["lp"]?.number, ns > 0.6, lp < -0.8 else { return nil }
            return (g["s"]?.number ?? 0, g["e"]?.number ?? 0)
        }
        return (d["words"]?.array ?? []).compactMap { w -> Word? in
            guard let s = w["s"]?.number, let t = w["w"]?.string, s <= len + 0.5 else { return nil }
            if bad.contains(where: { s >= $0.0 - 0.05 && s <= $0.1 + 0.05 }) { return nil }
            let abs = s + a
            guard abs >= lo && (abs < hi || k == count - 1) else { return nil }
            return Word(w: t, s: abs)
        }
    }

    /// One piece as multipart form data (`audio`, `prompt`) to the edge function.
    nonisolated private static func post(_ wav: Data, name: String, type: String, prompt: String) async throws -> JSONValue {
        let boundary = "----demo" + UUID().uuidString
        var body = Data()
        func s(_ x: String) { body.append(Data(x.utf8)) }
        s("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"\(name)\"\r\nContent-Type: \(type)\r\n\r\n")
        body.append(wav)
        s("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n\(prompt)\r\n--\(boundary)--\r\n")
        do {
            return try await Backend.client.functions.invoke("lyric-sync", options: FunctionInvokeOptions(headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"], body: body)) { data, _ in
                (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            }
        } catch let FunctionsError.httpError(code, data) {
            if code == 404 { throw SyncError.message("the lyric-sync function isn’t deployed on Supabase yet (or is named differently).") }
            if code == 401 { throw SyncError.message("Supabase didn’t accept your sign-in. Sign out and back in, then try again.") }
            if [504, 546, 408].contains(code) { throw SyncError.message("the sync server took too long to answer. Try again in a moment.") }
            let j = try? JSONDecoder().decode(JSONValue.self, from: data)
            throw SyncError.message(j?["error"]?.string ?? "the sync server returned an error (\(code)).")
        } catch let e as SyncError {
            throw e
        } catch {
            throw SyncError.message("check your connection and try again.")
        }
    }

    nonisolated static func wav16(_ f: [Float], sr: Int) -> Data {
        var d = Data(capacity: 44 + f.count * 2)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(UInt32(36 + f.count * 2)); d.append(Data("WAVE".utf8)); d.append(Data("fmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(f.count * 2))
        var samples = [Int16](repeating: 0, count: f.count)
        for i in 0..<f.count { let v = max(-1, min(1, f[i])); samples[i] = v < 0 ? Int16(v * 32768) : Int16(v * 32767) }
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    // MARK: alignment (alignLyrics)

    static let stop: Set<String> = ["a", "an", "the", "i", "im", "you", "me", "my", "we", "it", "its", "is", "was", "be", "to", "of", "in", "on", "at", "and", "or", "but", "so", "for", "your", "oh", "ooh", "yeah", "la", "na", "da"]

    nonisolated static func normWords(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "[’‘`']", with: "", options: .regularExpression).replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "[^a-z0-9\\s]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    nonisolated static func lev(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var p = Array(0...b.count)
        for i in 1...a.count {
            var c = [Int](repeating: 0, count: b.count + 1)
            c[0] = i
            for j in 1...b.count {
                c[j] = min(p[j] + 1, c[j - 1] + 1, p[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            p = c
        }
        return p[b.count]
    }

    nonisolated static func wordScore(_ a: String, _ b: String) -> Int32 {
        if a == b { return stop.contains(a) ? 2 : 4 }
        if a.count < 3 || b.count < 3 { return -2 }
        return Double(lev(Array(a), Array(b))) / Double(max(a.count, b.count)) <= 0.34 ? 2 : -2
    }

    nonisolated static func align(_ lines: [String], _ words: [Word]) -> (lines: [(String, Double)], timed: Int, total: Int) {
        var L: [String] = [], li: [Int] = []
        for (i, l) in lines.enumerated() { for w in normWords(l) { L.append(w); li.append(i) } }
        var W: [String] = [], wt: [Double] = []
        for x in words { for w in normWords(x.w) { W.append(w); wt.append(x.s) } }
        let n = L.count, m = W.count
        var times = [Double?](repeating: nil, count: lines.count)
        if n > 0 && m > 0 {
            let GL: Int32 = -2, GW: Int32 = -1, cols = m + 1
            var S = [Int32](repeating: 0, count: (n + 1) * cols), D = [UInt8](repeating: 0, count: (n + 1) * cols)
            for i in 1...n { S[i * cols] = Int32(i) * GL; D[i * cols] = 2 }
            for j in 1...m { S[j] = 0; D[j] = 3 }
            for i in 1...n {
                for j in 1...m {
                    let diag = S[(i - 1) * cols + j - 1] + wordScore(L[i - 1], W[j - 1])
                    let up = S[(i - 1) * cols + j] + GL
                    let left = S[i * cols + j - 1] + (i == n ? 0 : GW)
                    let k = i * cols + j
                    if left >= diag && left >= up { S[k] = left; D[k] = 3 } else if diag >= up { S[k] = diag; D[k] = 1 } else { S[k] = up; D[k] = 2 }
                }
            }
            var tokT = [Double?](repeating: nil, count: n)
            var i = n, j = m
            while i > 0 || j > 0 {
                let d: UInt8 = i > 0 && j > 0 ? D[i * cols + j] : (i > 0 ? 2 : 3)
                if d == 1 { if wordScore(L[i - 1], W[j - 1]) > 0 { tokT[i - 1] = wt[j - 1] }; i -= 1; j -= 1 }
                else if d == 2 { i -= 1 } else { j -= 1 }
            }
            var first = [Double?](repeating: nil, count: lines.count), hit = [Int](repeating: 0, count: lines.count)
            var real = [Int](repeating: 0, count: lines.count), cnt = [Int](repeating: 0, count: lines.count)
            for k in 0..<n {
                let ln = li[k]
                cnt[ln] += 1
                if let t = tokT[k] { hit[ln] += 1; if !stop.contains(L[k]) { real[ln] += 1 }; if first[ln] == nil { first[ln] = t } }
            }
            for q in 0..<lines.count {
                if let f = first[q], real[q] > 0, hit[q] >= max(1, Int((Double(cnt[q]) * 0.3).rounded(.up))), hit[q] >= 2 || cnt[q] <= 2 { times[q] = f }
            }
        }
        let timed = times.compactMap { $0 }.count
        var last = -1.0
        for a in 0..<times.count { if let t = times[a] { if t < last { times[a] = nil } else { last = t } } }
        for b in 0..<times.count where times[b] == nil {
            var pv = b - 1; while pv >= 0 && times[pv] == nil { pv -= 1 }
            var nx = b + 1; while nx < times.count && times[nx] == nil { nx += 1 }
            let tp = pv >= 0 ? times[pv] : nil, tn = nx < times.count ? times[nx] : nil
            if let tp, let tn { times[b] = tp + (tn - tp) * Double(b - pv) / Double(nx - pv) }
            else if let tn { times[b] = max(0, tn - 3 * Double(nx - b)) }
            else if let tp { times[b] = tp + 3 * Double(b - pv) }
            else { times[b] = 3 * Double(b) }
        }
        return (lines.enumerated().map { ($0.element, ((times[$0.offset] ?? 0) * 100).rounded() / 100) }, timed, lines.count)
    }
}
