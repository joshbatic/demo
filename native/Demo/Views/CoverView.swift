import SwiftUI
import UIKit

/// A song's cover: its own artwork, or the generated one the web draws (spec §1.8) — a pastel
/// gradient picked from the song's id, a glow, and one white bar per lyric line — so a song looks
/// the same on every device.
struct CoverView: View {
    let song: Song
    var size: CGFloat = 52
    var corner: CGFloat { size * 0.26 }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let art = song.artDataURL, let img = CoverView.image(art) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                generated
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    private var generated: some View {
        let k = CoverPick(id: song.id)
        let rows = CoverView.rows(song.lyrics)
        return Canvas { ctx, sz in
            let s = sz.width / 40
            let rect = CGRect(origin: .zero, size: sz)
            let x1 = (50 + 50 * cos(k.angle * .pi / 180)) / 100, y1 = (50 + 50 * sin(k.angle * .pi / 180)) / 100
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [k.a, k.b]),
                                                       startPoint: CGPoint(x: x1 * sz.width, y: y1 * sz.height),
                                                       endPoint: CGPoint(x: (1 - x1) * sz.width, y: (1 - y1) * sz.height)))
            ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [k.glow.opacity(0.85), k.glow.opacity(0)]),
                                                       center: CGPoint(x: k.cx * sz.width, y: k.cy * sz.height),
                                                       startRadius: 0, endRadius: sz.width * 0.6 * 1.414))
            if scheme == .dark { ctx.fill(Path(rect), with: .color(.black.opacity(0.12))) }
            var y: CGFloat = 9
            let sp: CGFloat = rows.bars.count > 6 ? 2.9 : 3.6
            for r in rows.bars {
                if r == 0 { y += sp * 0.55; continue }
                let bar = CGRect(x: 8 * s, y: y * s, width: 24 * r * s, height: 1.8 * s)
                ctx.fill(Path(roundedRect: bar, cornerRadius: 0.9 * s), with: .color(.white.opacity(rows.empty ? 0.6 : 0.82)))
                y += sp
            }
        }
    }

    /// One bar per lyric line (width by syllables), a gap between sections, at most 9.
    static func rows(_ lyrics: String) -> (bars: [CGFloat], empty: Bool) {
        var rows: [CGFloat] = [], gap = false
        for l in lyrics.components(separatedBy: "\n") {
            let tr = l.trimmingCharacters(in: .whitespaces)
            if tr.isEmpty || tr.hasPrefix("[") {
                if !rows.isEmpty && !gap { rows.append(0); gap = true }
                continue
            }
            gap = false
            rows.append(max(0.18, min(1, CGFloat(Syllables.line(l)) / 12)))
        }
        while rows.last == 0 { rows.removeLast() }
        if rows.isEmpty { return ([0.72, 0.5, 0.62], true) }
        return (Array(rows.prefix(9)), false)
    }

    private static let cache = NSCache<NSString, UIImage>()
    static func image(_ dataURL: String) -> UIImage? {
        if let c = cache.object(forKey: dataURL as NSString) { return c }
        guard let comma = dataURL.firstIndex(of: ","), let d = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])), let img = UIImage(data: d) else { return nil }
        cache.setObject(img, forKey: dataURL as NSString)
        return img
    }
}

/// The web's covPick: FNV-1a over the id's UTF-16 units, then xorshift, picking colours and positions.
struct CoverPick {
    static let palette: [(UInt32, UInt32)] = [(0xFFC9B0, 0xFF8FA3), (0xD7C4FF, 0x9CC8FF), (0xBFF0D4, 0x7FCCDB), (0xFFE9A8, 0xFFAA7F), (0xFFC2DA, 0xB9A6FF), (0xB6E8D8, 0x9AAEF2), (0xF5D7BA, 0xEE8F82), (0xB8DEFF, 0xB5EDC6), (0xF7AFC2, 0xF9CD86), (0xAFBBFF, 0xEFAED6), (0xC9E6A6, 0x86CFB4), (0xFFD6A5, 0xE7A6E0)]
    let a: Color, b: Color, glow: Color
    let angle: Double, cx: Double, cy: Double
    /// covHex: the cover's colours, strongest first (the share card's fallback palette).
    let hexes: [UInt32]

    init(id: String) {
        var h: UInt32 = 2166136261
        for u in id.utf16 { h ^= UInt32(u); h = h &* 16777619 }
        func r() -> Double {
            h ^= h << 13; h ^= h >> 17; h ^= h << 5
            return Double(h) / 4294967296
        }
        _ = r()
        let n = CoverPick.palette.count
        let p = CoverPick.palette[min(n - 1, Int(r() * Double(n)))]
        let q = CoverPick.palette[min(n - 1, Int(r() * Double(n)))]
        angle = r() * 360
        cx = (15 + (r() * 70).rounded()) / 100
        cy = (15 + (r() * 70).rounded()) / 100
        let c = r() < 0.5 ? q.0 : q.1
        a = Color(hex: p.0); b = Color(hex: p.1); glow = Color(hex: c)
        hexes = [p.1, c, p.0]
    }
}

/// Syllable counting. The full rhyme dictionary arrives with the rhyme engine; until then this is
/// the web's fallback rule (hsyl), which is what it uses for any word not in its dictionary.
enum Syllables {
    static func word(_ w: String) -> Int {
        var s = w.lowercased().filter { $0 >= "a" && $0 <= "z" }
        if s.isEmpty { return 0 }
        if s.count <= 3 { return 1 }
        if let r = s.range(of: #"(?:[^laeiouy]es|[^td]ed|[^laeiouy]e)$"#, options: .regularExpression) { s.removeSubrange(r) }
        if s.hasPrefix("y") { s.removeFirst() }
        let groups = s.matches(of: #/[aeiouy]{1,2}/#).count
        return max(1, groups)
    }
    static func line(_ l: String) -> Int {
        if RhymeEngine.shared.loaded { return RhymeEngine.shared.lineSyllables(l) }
        return l.matches(of: #/[A-Za-z']+/#).reduce(0) { $0 + word(String(l[$1.range])) }
    }
}
