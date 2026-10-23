import SwiftUI
import UIKit
import Supabase

// MARK: - colour (engines.md §6.3)

/// Hue (degrees), saturation and lightness, 0…1.
struct HSL: Hashable { var h: Double; var s: Double; var l: Double }

enum SharePalette {
    static func hsl(r: Double, g: Double, b: Double) -> HSL {
        let r = r / 255, g = g / 255, b = b / 255
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2, d = mx - mn
        var h = 0.0, s = 0.0
        if d > 0 {
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
            h *= 60
        }
        return HSL(h: h, s: s, l: l)
    }

    static func hex(_ x: UInt32) -> HSL { hsl(r: Double(x >> 16 & 255), g: Double(x >> 8 & 255), b: Double(x & 255)) }

    static func color(_ c: HSL) -> Color {
        let (r, g, b) = rgb(c)
        return Color(red: r, green: g, blue: b)
    }

    static func rgb(_ c: HSL) -> (Double, Double, Double) {
        let h = c.h / 360, s = c.s, l = c.l
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func f(_ t0: Double) -> Double {
            var t = t0; if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (f(h + 1.0 / 3), f(h), f(h - 1.0 / 3))
    }

    /// The cover's main colours: pixels grouped by hue, ranked by coverage and vividness (artPalette).
    static func fromArt(_ img: UIImage) -> [HSL] {
        let n = 40
        guard let cg = img.cgImage else { return [] }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return [] }
        struct Bin { var n = 0.0, r = 0.0, g = 0.0, b = 0.0, w = 0.0 }
        var bins: [String: Bin] = [:]
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] >= 128 {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let h = hsl(r: r, g: g, b: b)
            let grey = h.s < 0.14 || h.l < 0.07 || h.l > 0.96
            let k = grey ? "g\(Int((h.l * 4).rounded()))" : "h\(Int((h.h / 15).rounded()) % 24)"
            var bn = bins[k] ?? Bin()
            bn.n += 1; bn.r += r; bn.g += g; bn.b += b
            bn.w += (grey ? 0.35 : 0.6 + h.s) * (h.l < 0.12 || h.l > 0.92 ? 0.5 : 1)
            bins[k] = bn
        }
        var out: [HSL] = []
        for (_, b) in bins.sorted(by: { $0.value.w > $1.value.w }) {
            let c = hsl(r: b.r / b.n, g: b.g / b.n, b: b.b / b.n)
            if out.count < 5 && !out.contains(where: { p in
                (p.s < 0.14 && c.s < 0.14) || (p.s >= 0.14 && c.s >= 0.14 && min(abs(p.h - c.h), 360 - abs(p.h - c.h)) < 28)
            }) { out.append(c) }
        }
        return out
    }

    static func palette(_ s: Song) -> [HSL] {
        if let a = s.artDataURL, let img = CoverView.image(a) {
            let p = fromArt(img)
            if !p.isEmpty { return p }
        }
        return CoverPick(id: s.id).hexes.map(hex)
    }

    /// shSoft: pastel, the saturation held in a pleasant band.
    static func soft(_ c: HSL, _ l: Double) -> HSL {
        HSL(h: c.h, s: c.s < 0.14 ? min(c.s, 0.12) : max(0.42, min(0.78, c.s * 1.1)), l: l)
    }

    struct Background { var top: HSL; var bot: HSL; var glow: HSL; var ink: HSL }

    /// shBg: colour i washes diagonally into the next, with a glow of a third; text is a deep shade of the first.
    static func background(_ pal: [HSL], _ i: Int) -> Background {
        let n = max(1, pal.count)
        let a = pal.isEmpty ? HSL(h: 220, s: 0.1, l: 0.5) : pal[i % n]
        let b = pal.isEmpty ? a : pal[(i + 1) % n], g = pal.isEmpty ? b : pal[(i + 2) % n]
        return Background(top: soft(a, 0.86), bot: soft(b, 0.8), glow: soft(g, 0.88), ink: HSL(h: a.h.rounded(), s: a.s < 0.14 ? 0.08 : 0.4, l: 0.15))
    }

    static func css(_ c: HSL) -> String { "hsl(\(Int(c.h.rounded())),\(Int((c.s * 100).rounded()))%,\(Int((c.l * 100).rounded()))%)" }
}

// MARK: - the card

/// The share card (spec §2.7, the web's .shcard): pastel background, the player card, then the lyrics.
struct ShareCard: View {
    let song: Song
    let bg: SharePalette.Background
    var audio: FileItem?
    var lyrics = true
    var width: CGFloat = 360
    /// The sheet's preview fades out at the bottom (max height); the shared picture shows everything.
    var preview = false

    var body: some View {
        let ink = SharePalette.color(bg.ink)
        VStack(alignment: .leading, spacing: 0) {
            playerCard(ink)
            if lyrics {
                let blocks = ShareLink_.blocks(song)
                VStack(alignment: .leading, spacing: 0) {
                    if blocks.isEmpty {
                        Text("No lyrics yet").font(.system(size: 19, weight: .bold)).foregroundStyle(ink.opacity(0.5))
                    }
                    ForEach(Array(blocks.prefix(40).enumerated()), id: \.offset) { i, b in
                        switch b {
                        case .sec(let name):
                            Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink.opacity(0.5))
                                .padding(.top, i == 0 ? 0 : 14).padding(.bottom, 5)
                        case .gap:
                            Color.clear.frame(height: 8)
                        case .line(let t, _):
                            Text(t).font(.system(size: 19, weight: .bold)).tracking(-0.19).foregroundStyle(ink.opacity(0.95))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 5)
                        }
                    }
                }
                .padding(.top, 26)
                if !preview {
                    Text("Written in *[demo]").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.42)).padding(.top, 20).padding(.bottom, 26)
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 26).padding(.bottom, lyrics ? 0 : 26)
        .frame(width: width, alignment: .topLeading)
        .background {
            ZStack {
                LinearGradient(colors: [SharePalette.color(bg.top), SharePalette.color(bg.bot)], startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1))
                RadialGradient(colors: [SharePalette.color(bg.glow), SharePalette.color(bg.glow).opacity(0)], center: UnitPoint(x: 0.88, y: 0.04), startRadius: 0, endRadius: width * 0.72)
            }
        }
    }

    /// shCardDraw: white glass card, cover, title and details; with audio a play circle, the waveform and times.
    private func playerCard(_ ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                CoverView(song: song, size: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: ink.opacity(0.18), radius: 6, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.displayTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    let sub = [song.artist, song.key.isEmpty ? "" : "Key of " + song.key, song.bpm.isEmpty ? "" : song.bpm + " BPM"].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !sub.isEmpty { Text(sub).font(.system(size: 13.5)).foregroundStyle(ink.opacity(0.6)).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if audio != nil {
                    Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .offset(x: 1.5)
                        .frame(width: 40, height: 40).background(ink, in: Circle())
                }
            }
            .padding(12)
            if let a = audio {
                Waveform(peaks: a.peaks, progress: 0, duration: a.dur, height: 58) { _ in }
                    .allowsHitTesting(false)
                    .padding(.horizontal, 14)
                ZStack {
                    HStack { Text("0:00"); Spacer(); Text("-" + SongFiles.time(a.dur)) }
                        .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(ink.opacity(0.6))
                    HStack(spacing: 30) {
                        Image(systemName: "gobackward.15"); Image(systemName: "goforward.15")
                    }
                    .font(.system(size: 18)).foregroundStyle(ink)
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
            }
        }
        .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(ink.opacity(0.1), lineWidth: 0.5))
        .shadow(color: ink.opacity(0.14), radius: 15, y: 10)
    }
}

// MARK: - link mechanics (data spec §4.4)

enum ShareLink_ {
    enum Block: Hashable { case sec(String), gap, line(String, Double?) }

    /// The lyrics as blocks: tags become headings, blank runs one gap; lines carry their sync time when
    /// the sync belongs to the shared audio and matches the lyrics line for line.
    static func blocks(_ s: Song, audioID: String? = nil) -> [Block] {
        var out: [Block] = []
        let useSync = audioID != nil && s.syncAudioID == audioID && !s.syncIsStale
        let times = useSync ? s.syncLines.map(\.t) : []
        var li = 0
        for raw in s.lyrics.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if let last = out.last, last != .gap { out.append(.gap) }; continue }
            if let m = t.firstMatch(of: #/^\[([^\]]*)\]$/#) { out.append(.sec(String(m.1))); continue }
            out.append(.line(t, li < times.count ? times[li] : nil))
            li += 1
        }
        while out.last == .gap { out.removeLast() }
        return out
    }

    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
    static func newID() -> String { String((0..<10).map { _ in alphabet.randomElement()! }) }

    static func url(_ id: String) -> String { "https://\(Config.listenHost)/\(id)" }
}

// MARK: - the sheet

struct ShareSheet: View {
    let songID: String
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var palette: [HSL] = []
    @State private var pick = 0
    @AppStorage("share.audio") private var includeAudio = true
    @State private var busy: String?
    @State private var confirmStop = false
    @State private var shareURL: URL?

    private var song: Song? { library.song(songID) }
    private var myShare: [String: JSONValue]? {
        guard let uid = session.userID else { return nil }
        return song?.raw["shares"]?[uid]?.object
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let s = song {
                    let bg = SharePalette.background(palette, pick)
                    VStack(spacing: 0) {
                        card(s, bg)
                        if palette.count > 1 { swatches }
                        linkGroup(s, bg)
                        if let m = myShare, let id = m["id"]?.string, busy == nil, let u = URL(string: ShareLink_.url(id)) {
                            HStack(spacing: 8) {
                                ShareLink(item: u) { pill("Share Link", filled: true) }
                                Button { confirmStop = true } label: { pill("Stop Sharing", filled: false, red: true) }
                            }
                            .buttonStyle(PressScale())
                            .padding(.horizontal, 20).padding(.bottom, 8)
                        }
                        HStack(spacing: 8) {
                            Button { shareImage(s, bg) } label: { pill("Share Image", filled: myShare == nil) }
                            Button {
                                UIPasteboard.general.string = (s.title.isEmpty ? "" : s.title + (s.artist.isEmpty ? "" : " – " + s.artist) + "\n\n") + s.lyrics
                                Haptics.success(); session.toast = "Copied"
                            } label: { pill("Copy Lyrics", filled: false) }
                        }
                        .buttonStyle(PressScale())
                        .padding(.horizontal, 20)
                        if myShare != nil {
                            Text("The link shows the song as of your last update.")
                                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .padding(.horizontal, 20).padding(.top, 8)
                        }
                    }
                    .padding(.top, 4).padding(.bottom, 24)
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
            .confirmationDialog("Stop the share link?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop Sharing", role: .destructive) { Task { await stopLink() } }
            } message: { Text("Anyone with the link can no longer open it.") }
            .sheet(item: Binding(get: { shareURL.map(IdentURL.init) }, set: { shareURL = $0?.url })) { u in
                ActivityView(items: [u.url])
            }
        }
        .presentationDetents([.fraction(0.88)])
        .task { if let s = song { palette = SharePalette.palette(s) } }
    }

    /// The preview: at most about half the screen, fading out at the bottom.
    private func card(_ s: Song, _ bg: SharePalette.Background) -> some View {
        GeometryReader { g in
            ShareCard(song: s, bg: bg, audio: includeAudio ? s.currentAudio : nil, width: g.size.width, preview: true)
        }
        .frame(height: min(UIScreen.main.bounds.height * 0.48, 440))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0.78), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .shadow(color: .black.opacity(0.12), radius: 15, y: 10)
        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 14)
    }

    private var swatches: some View {
        HStack(spacing: 12) {
            ForEach(palette.indices, id: \.self) { i in
                let b = SharePalette.background(palette, i)
                Button { guard pick != i else { return }; Haptics.selection(); pick = i } label: {
                    ZStack {
                        RadialGradient(colors: [SharePalette.color(b.glow), SharePalette.color(b.glow).opacity(0)], center: UnitPoint(x: 0.88, y: 0.04), startRadius: 0, endRadius: 24)
                            .background(LinearGradient(colors: [SharePalette.color(b.top), SharePalette.color(b.bot)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .padding(2.5)
                    .overlay(Circle().strokeBorder(Theme.tint, lineWidth: pick == i ? 2 : 0))
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Colour \(i + 1)").accessibilityAddTraits(pick == i ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 16)
    }

    /// The glass group: Link (with Create Link / Update) and Include audio.
    private func linkGroup(_ s: Song, _ bg: SharePalette.Background) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link").font(.system(size: 17))
                    ForEach(linkLines, id: \.self) { Text($0).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if busy != nil {
                    ProgressView()
                } else if session.userID != nil {
                    Button { makeLink(s, bg) } label: {
                        Text(myShare == nil ? "Create Link" : "Update").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(myShare == nil ? Theme.onTint : Theme.tint)
                            .padding(.horizontal, 16).frame(height: 32)
                            .background(myShare == nil ? Theme.tint : BarFill.color, in: Capsule())
                    }
                    .buttonStyle(PressScale())
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10).frame(minHeight: 58)
            if let a = s.currentAudio {
                Divider().padding(.leading, 20)
                Toggle(isOn: $includeAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include audio").font(.system(size: 17))
                        if includeAudio {
                            Text(a.name).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            Text(s.syncAudioID == a.id && !s.syncLines.isEmpty ? "Plays with the lyrics lit in time" : "Plays from the link").font(.system(size: 13)).foregroundStyle(.secondary)
                        } else {
                            Text("Lyrics only").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 10).frame(minHeight: 58)
            }
        }
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 20).padding(.bottom, 16)
    }

    private var linkLines: [String] {
        if let b = busy { return [b] }
        if session.userID == nil { return ["Sign in to make a link"] }
        if let m = myShare, let id = m["id"]?.string {
            var l = [Config.listenHost + "/" + id]
            if let at = m["at"]?.number { l.append("Updated " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: at / 1000), relativeTo: Date())) }
            return l
        }
        return ["Anyone can open it, no account needed"]
    }

    /// The web's .go2 pills: filled, or a light "ghost" (red for Stop Sharing).
    private func pill(_ t: String, filled: Bool, red: Bool = false) -> some View {
        Text(t).font(.system(size: 15.5, weight: .semibold))
            .foregroundStyle(red ? Color.red : filled ? Theme.onTint : Theme.tint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(filled ? Theme.tint : BarFill.color, in: Capsule())
    }

    struct IdentURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

    // MARK: the picture

    @MainActor
    private func render(_ v: some View, scale: CGFloat) -> UIImage? {
        let r = ImageRenderer(content: v.environment(\.colorScheme, .light))
        r.scale = scale
        return r.uiImage
    }

    private func shareImage(_ s: Song, _ bg: SharePalette.Background) {
        guard let img = render(ShareCard(song: s, bg: bg, audio: includeAudio ? s.currentAudio : nil, width: 400), scale: 1080 / 400),
              let png = img.pngData() else { session.toast = "Couldn’t make the image"; return }
        let name = (s.displayTitle.replacingOccurrences(of: "/", with: "-")) + ".png"
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? png.write(to: url)
        shareURL = url
    }

    // MARK: the link

    private func makeLink(_ s: Song, _ bg: SharePalette.Background) {
        guard let uid = session.userID else { return }
        let id = myShare?["id"]?.string ?? ShareLink_.newID()
        let existed = myShare != nil
        // copied during the tap, before the upload finishes
        UIPasteboard.general.string = ShareLink_.url(id)
        busy = existed ? "Updating the link…" : "Making the link…"
        let withAudio = includeAudio && session.plan.isPro ? s.currentAudio : nil
        let artImg: UIImage? = s.artDataURL.flatMap(CoverView.image) ?? render(CoverView(song: s, size: 480), scale: 1)
        let ogImg = render(ShareCard(song: s, bg: bg, audio: withAudio, lyrics: false, width: 1200 / 2.85)
                            .frame(width: 1200 / 2.85, height: 630 / 2.85), scale: 2.85)
        Task {
            defer { busy = nil }
            do {
                try await withThrowingTaskGroup(of: Void.self) { g in
                    g.addTask { @MainActor in
                        try await publish(s, id: id, uid: uid, bg: bg, audio: withAudio, art: artImg, og: ogImg)
                    }
                    g.addTask { try await Task.sleep(for: .seconds(180)); throw ShareError.timeout }
                    try await g.next()
                    g.cancelAll()
                }
                Haptics.success()
                session.toast = existed ? "Link updated and copied" : "Link ready and copied"
            } catch ShareError.timeout {
                session.toast = "It took too long. Check your connection and try again."
            } catch {
                session.toast = "Couldn’t make the link: " + SongFiles.message(error) + (existed ? "" : " (the copied link won’t work)")
            }
        }
    }

    enum ShareError: Error { case timeout }

    private func publish(_ s: Song, id: String, uid: String, bg: SharePalette.Background, audio: FileItem?, art: UIImage?, og: UIImage?) async throws {
        let bucket = Backend.client.storage.from("shares")
        let v = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let folder = "\(uid)/\(id)"
        func put(_ data: Data, _ name: String, _ type: String) async throws -> String {
            let path = folder + "/" + name
            _ = try await bucket.upload(path, data: data, options: FileOptions(cacheControl: "31536000", contentType: type, upsert: true))
            return try bucket.getPublicURL(path: path, download: nil as String?).absoluteString
        }
        var data: [String: JSONValue] = ["v": .number(1), "title": .string(s.title), "artist": .string(s.artist), "key": .string(s.key), "bpm": .string(s.bpm)]
        data["blocks"] = .array(ShareLink_.blocks(s, audioID: audio?.id).map { b in
            switch b {
            case .sec(let n): return .object(["sec": .string(n)])
            case .gap: return .object(["gap": true])
            case .line(let t, let time): return .object(["line": .string(t), "t": time.map { .number($0) } ?? .null])
            }
        })
        let a = bg.top, k = "\(Int(a.h.rounded())),\(a.s < 0.14 ? 8 : 40)%,15%"
        data["bg"] = .object(["top": .string(SharePalette.css(bg.top)), "bot": .string(SharePalette.css(bg.bot)), "glow": .string(SharePalette.css(bg.glow)), "k": .string(k)])
        var keep = Set<String>()
        if let art, let jpg = art.jpegData(compressionQuality: 0.9) {
            let n = "art-\(v).jpg"; keep.insert(n)
            data["art"] = .string(try await put(jpg, n, "image/jpeg"))
        }
        if let og, let jpg = og.jpegData(compressionQuality: 0.86) {
            let n = "og-\(v).jpg"; keep.insert(n)
            data["og"] = .string(try await put(jpg, n, "image/jpeg"))
        }
        var aid: String?, aname: String?
        if let a = audio {
            let prev = myShare
            let ext = a.ext.isEmpty ? "mp3" : a.ext
            if prev?["aid"]?.string == a.id, let old = (try? await bucket.list(path: folder))?.first(where: { $0.name.hasPrefix("audio-") }) {
                keep.insert(old.name)
                data["audio"] = .object(["src": .string(try bucket.getPublicURL(path: folder + "/" + old.name, download: nil as String?).absoluteString),
                                         "name": .string(a.name), "dur": .number(a.dur), "peaks": .array(a.peaks.map { .number($0) })])
            } else {
                let n = "audio-\(v).\(ext)"; keep.insert(n)
                let path = folder + "/" + n
                do {
                    guard !a.isLocal, a.size <= 40 * 1_048_576 else { throw ShareError.timeout }
                    _ = try await Backend.client.storage.from(SongFiles.bucket).copy(from: a.path, to: path, options: DestinationOptions(destinationBucket: "shares"))
                } catch {
                    let local = try await SongFiles.playableURL(a)
                    let bytes = local.isFileURL ? try Data(contentsOf: local) : try await URLSession.shared.data(from: local).0
                    _ = try await bucket.upload(path, data: bytes, options: FileOptions(cacheControl: "31536000", contentType: a.mime.isEmpty ? "audio/mpeg" : a.mime, upsert: true))
                }
                data["audio"] = .object(["src": .string(try bucket.getPublicURL(path: path, download: nil as String?).absoluteString),
                                         "name": .string(a.name), "dur": .number(a.dur), "peaks": .array(a.peaks.map { .number($0) })])
            }
            aid = a.id; aname = a.name
        } else { data["audio"] = .null }
        let row: [String: JSONValue] = ["id": .string(id), "owner": .string(uid), "song_id": .string(s.id), "data": .object(data),
                                        "updated_at": .string(ISO8601DateFormatter().string(from: Date()))]
        _ = try await Backend.client.from("shares").upsert(row, onConflict: "id").execute()
        // tidy: files from older versions of this link
        if let files = try? await bucket.list(path: folder) {
            let old = files.map(\.name).filter { !keep.contains($0) }.map { folder + "/" + $0 }
            if !old.isEmpty { _ = try? await bucket.remove(paths: old) }
        }
        guard var now = library.song(s.id) else { return }
        var shares = now.raw["shares"]?.object ?? [:]
        var mine: [String: JSONValue] = ["id": .string(id), "at": .number(Clock.nowMs), "audio": .bool(audio != nil), "by": .string(uid)]
        if let aid { mine["aid"] = .string(aid) }
        if let aname { mine["aname"] = .string(aname) }
        shares[uid] = .object(mine)
        now.raw["shares"] = .object(shares)
        now.touch()
        library.put(now)
    }

    private func stopLink() async {
        guard let uid = session.userID, let id = myShare?["id"]?.string else { return }
        _ = try? await Backend.client.from("shares").delete().eq("id", value: id).execute()
        let bucket = Backend.client.storage.from("shares")
        if let files = try? await bucket.list(path: "\(uid)/\(id)") {
            let paths = files.map { "\(uid)/\(id)/" + $0.name }
            if !paths.isEmpty { _ = try? await bucket.remove(paths: paths) }
        }
        if var s = library.song(songID) {
            var shares = s.raw["shares"]?.object ?? [:]
            shares.removeValue(forKey: uid)
            s.raw["shares"] = .object(shares)
            s.touch(); library.put(s)
        }
        Haptics.thud()
        session.toast = "The link no longer works"
    }
}

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
