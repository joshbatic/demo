import AVFoundation
import Foundation

/// Tempo and key from a song's audio (the web's tkAnalyze, the same steps): the middle of the song, up to two
/// minutes, mono at 11 kHz. Tempo from how often the hits repeat; key from which notes sound most, matched
/// against the usual major and minor shapes, with the bass deciding between a minor key and its relative major.
/// Keys come back in the Details picker's names ("A", "Am", "Eb", …).
nonisolated enum TempoKey {
    struct Result { var bpm: Int; var key: String }

    static let notes = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    private static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    private static let rate: Double = 11025

    static func analyze(_ url: URL) async -> Result? {
        await Task.detached(priority: .utility) { () async -> Result? in
            guard let x = await samples(url), x.count > Int(rate * 6) else { return nil }
            return Result(bpm: tempo(x, sr: rate), key: key(x, sr: rate))
        }.value
    }

    /// "Am" → "A minor", "Eb" → "Eb major"
    static func name(_ k: String) -> String { k.hasSuffix("m") ? String(k.dropLast()) + " minor" : k + " major" }

    // MARK: reading

    private static func samples(_ url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false,
                                       AVNumberOfChannelsKey: 1, AVSampleRateKey: rate]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(out)
        guard reader.startReading() else { return nil }
        var x: [Float] = []
        while let buf = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
            let len = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: p.baseAddress!) }
            x.append(contentsOf: chunk)
        }
        // the middle two minutes
        let max = Int(rate * 120)
        if x.count > max { let s = (x.count - max) / 2; x = Array(x[s..<(s + max)]) }
        return x
    }

    // MARK: spectra

    private static func fft(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>, _ n: Int) {
        var j = 0
        for i in 1..<n {
            var b = n >> 1
            while j & b != 0 { j ^= b; b >>= 1 }
            j ^= b
            if i < j { let tr = re[i]; re[i] = re[j]; re[j] = tr; let ti = im[i]; im[i] = im[j]; im[j] = ti }
        }
        var l = 2
        while l <= n {
            let a = -2 * Double.pi / Double(l), wr = cos(a), wi = sin(a)
            var i = 0
            while i < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<(l / 2) {
                    let p = i + k, q = p + l / 2
                    let tr = re[q] * cr - im[q] * ci, ti = re[q] * ci + im[q] * cr
                    re[q] = re[p] - tr; im[q] = im[p] - ti; re[p] += tr; im[p] += ti
                    let nr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = nr
                }
                i += l
            }
            l <<= 1
        }
    }

    /// Hann-windowed magnitude spectra, `n` long, every `hop` samples.
    private static func spectra(_ x: [Float], n: Int, hop: Int, _ each: (UnsafeBufferPointer<Double>) -> Void) {
        let re = UnsafeMutablePointer<Double>.allocate(capacity: n), im = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let mag = UnsafeMutablePointer<Double>.allocate(capacity: n / 2)
        defer { re.deallocate(); im.deallocate(); mag.deallocate() }
        let w = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
        x.withUnsafeBufferPointer { xs in
            var s = 0
            while s + n <= xs.count {
                for i in 0..<n { re[i] = Double(xs[s + i]) * w[i]; im[i] = 0 }
                fft(re, im, n)
                for i in 0..<(n / 2) { mag[i] = (re[i] * re[i] + im[i] * im[i]).squareRoot() }
                each(UnsafeBufferPointer(start: mag, count: n / 2))
                s += hop
            }
        }
    }

    // MARK: tempo

    static func tempo(_ x: [Float], sr: Double) -> Int {
        let n = 512, hop = 64
        var prev: [Double]? = nil, env: [Double] = []
        spectra(x, n: n, hop: hop) { m in
            var f = 0.0
            var cur = [Double](repeating: 0, count: m.count)
            for i in 1..<m.count {
                cur[i] = log(1 + 100 * m[i])
                if let prev { let d = cur[i] - prev[i]; if d > 0 { f += d } }
            }
            prev = cur; env.append(f)
        }
        let N = env.count, fps = sr / Double(hop)
        guard Double(N) >= fps * 6 else { return 0 }
        // take away the slow trend so only the hits are left
        let W = Int((fps * 0.4).rounded())
        var o = [Double](repeating: 0, count: N), acc = 0.0
        for i in 0..<N {
            acc += env[i]; if i >= W { acc -= env[i - W] }
            o[i] = max(0, env[i] - acc / Double(min(i + 1, W)))
        }
        let lo = Int(floor(fps * 60 / 200)), hi = Int(ceil(fps * 60 / 55))
        var ac = [Double](repeating: 0, count: hi * 4 + 2)
        for L in lo..<ac.count where L < N {
            var s = 0.0
            for i in 0..<(N - L) { s += o[i] * o[i + L] }
            ac[L] = s / Double(N - L)
        }
        func at(_ t: Double) -> Double {
            let a = Int(floor(t)), f = t - Double(a)
            return a + 1 < ac.count ? ac[a] * (1 - f) + ac[a + 1] * f : 0
        }
        // score each tempo by its beat and the next three, leaning gently toward 120
        var best = 0.0, bt = 0.0, bpm = 55.0
        while bpm <= 200 {
            let Lf = fps * 60 / bpm
            var sc = at(Lf) + 0.5 * at(2 * Lf) + 0.33 * at(3 * Lf) + 0.25 * at(4 * Lf) + 0.5 * at(Lf / 2 > Double(lo) ? Lf / 2 : Lf)
            sc *= exp(-0.5 * pow(log2(bpm / 120) / 1.1, 2))
            if sc > best { best = sc; bt = bpm }
            bpm += 0.25
        }
        guard bt > 0 else { return 0 }
        while bt < 70 { bt *= 2 }
        while bt >= 180 { bt /= 2 }
        return Int(bt.rounded())
    }

    // MARK: key

    static func key(_ x: [Float], sr: Double) -> String {
        let n = 4096
        var ch = [Double](repeating: 0, count: 12), bass = [Double](repeating: 0, count: 12)
        let bin: [Int] = (0..<(n / 2)).map { i in
            let f = Double(i) * sr / Double(n)
            if f < 60 || f > 2000 { return -1 }
            return ((Int((12 * log2(f / 440)).rounded()) + 9) % 12 + 12) % 12
        }
        spectra(x, n: n, hop: n / 2) { m in
            var c = [Double](repeating: 0, count: 12), cb = [Double](repeating: 0, count: 12), t = 0.0, tb = 0.0
            for i in 0..<m.count where bin[i] >= 0 {
                let v = m[i] * m[i]
                c[bin[i]] += v; t += v
                if Double(i) * sr / Double(n) < 260 { cb[bin[i]] += v; tb += v }
            }
            if t > 0 { for i in 0..<12 { ch[i] += (c[i] / t).squareRoot() } }
            if tb > 0 { for i in 0..<12 { bass[i] += (cb[i] / tb).squareRoot() } }
        }
        // the bass usually sits on the home note, which tells a minor key from its relative major
        for j in 0..<12 { ch[j] += bass[j] }
        func corr(_ p: [Double], _ r: Int) -> Double {
            var mx = 0.0, mp = 0.0
            for i in 0..<12 { mx += ch[(i + r) % 12]; mp += p[i] }
            mx /= 12; mp /= 12
            var a = 0.0, b = 0.0, c = 0.0
            for i in 0..<12 { let dx = ch[(i + r) % 12] - mx, dp = p[i] - mp; a += dx * dp; b += dx * dx; c += dp * dp }
            return b > 0 && c > 0 ? a / (b * c).squareRoot() : 0
        }
        var best = -2.0, key = ""
        for r in 0..<12 {
            let a = corr(major, r), b = corr(minor, r)
            if a > best { best = a; key = notes[r] }
            if b > best { best = b; key = notes[r] + "m" }
        }
        return best > 0.3 ? key : ""
    }
}

/// Fills an empty Key and BPM from a song's audio (the web's tkFill): when a version is added, and when Details
/// opens on a song that has audio but no key or tempo yet. Only empty fields change; each version is listened to once.
@MainActor
enum TempoKeyFill {
    static func run(songID: String, itemID: String, url: URL?, library: LibraryStore, session: AppSession) async {
        guard var s = library.song(songID), s.key.isEmpty || s.bpm.isEmpty,
              let i = s.audioItems.firstIndex(where: { $0.id == itemID }), s.audioItems[i].raw["tk"] == nil else { return }
        // mark it first, so it's only tried once even if this fails
        var items = s.audioItems
        items[i].raw["tk"] = .number(1)
        s.audioItems = items
        library.put(s)
        let item = items[i]
        var file = url
        if file == nil { file = try? await SongFiles.playableURL(item) }
        guard let file, file.isFileURL, let r = await TempoKey.analyze(file) else { return }
        guard var now = library.song(songID) else { return }
        var got: [String] = []
        if now.bpm.isEmpty && r.bpm > 0 { now.bpm = String(r.bpm); got.append("\(r.bpm) BPM") }
        if now.key.isEmpty && !r.key.isEmpty { now.key = r.key; got.append(TempoKey.name(r.key)) }
        guard !got.isEmpty else { return }
        now.touch(); library.put(now)
        session.toast = "Found \(got.joined(separator: " in ")) from “\(item.name)”. Change it in Details if it’s off."
    }

    /// Details opened: the current version, if the key or tempo is still empty.
    static func check(songID: String, library: LibraryStore, session: AppSession) {
        guard let s = library.song(songID), s.key.isEmpty || s.bpm.isEmpty, let a = s.currentAudio, a.raw["tk"] == nil,
              session.plan.isPro || a.isMine(session.userID) else { return }
        Task { await run(songID: songID, itemID: a.id, url: nil, library: library, session: session) }
    }
}
