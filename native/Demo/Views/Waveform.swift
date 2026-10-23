import SwiftUI

/// A scrubbable waveform (spec §4.10): rounded bars, the played part in ink and the rest muted, with
/// Dock-style magnification under the finger. Haptics: light on grab, a tick every `tickEvery` seconds
/// of song, medium at either end, light on release. The seek happens on release.
struct Waveform: View {
    let peaks: [Double]
    /// 0…1 of the way through.
    let progress: Double
    let duration: Double
    var tickEvery: Double = 5
    var height: CGFloat = 44
    var onSeek: (Double) -> Void

    @State private var dragX: CGFloat?
    @State private var lastTick = -1
    @State private var atEnd = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { ctx, size in
                draw(ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let x = min(max(0, v.location.x), w)
                    if dragX == nil { Haptics.tap(); lastTick = -1; atEnd = 0 }
                    dragX = x
                    let f = w > 0 ? Double(x / w) : 0
                    let t = f * duration
                    let tick = tickEvery > 0 ? Int(t / tickEvery) : 0
                    if tick != lastTick { if lastTick >= 0 { Haptics.selection() }; lastTick = tick }
                    let end = f <= 0.001 ? -1 : (f >= 0.999 ? 1 : 0)
                    if end != 0 && end != atEnd { Haptics.thud() }
                    atEnd = end
                }
                .onEnded { v in
                    let x = min(max(0, v.location.x), w)
                    Haptics.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = nil }
                    onSeek(w > 0 ? Double(x / w) : 0)
                })
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Position in the song")
        .accessibilityValue(SongFiles.time(progress * duration))
        .accessibilityAdjustableAction { dir in
            let step = duration > 0 ? 5 / duration : 0.05
            onSeek(min(1, max(0, progress + (dir == .increment ? step : -step))))
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let bars = peaks.isEmpty ? Array(repeating: 12.0, count: 60) : peaks
        let n = bars.count
        guard n > 0, size.width > 0 else { return }
        let unit = size.width / CGFloat(n)
        let baseW = max(1, unit * 0.533)
        // magnification: a Gaussian (σ = 20 pt) around the finger
        let sigma: CGFloat = 20
        var gains = [CGFloat](repeating: 0, count: n)
        if let fx = dragX {
            for i in 0..<n {
                let cx = (CGFloat(i) + 0.5) * unit
                let d = cx - fx
                gains[i] = exp(-(d * d) / (2 * sigma * sigma))
            }
        }
        // widths re-flow around the magnified bars, keeping the bar under the finger in place
        let widths = gains.map { unit * (1 + 1.1 * $0) }
        var xs = [CGFloat](repeating: 0, count: n)
        var acc: CGFloat = 0
        for i in 0..<n { xs[i] = acc; acc += widths[i] }
        var shift: CGFloat = 0
        if let fx = dragX {
            let i = min(n - 1, max(0, Int(fx / unit)))
            let within = (fx - CGFloat(i) * unit) / unit
            shift = fx - (xs[i] + within * widths[i])
        } else {
            shift = (size.width - acc) / 2
        }
        let played = dragX.map { Double($0 / size.width) } ?? progress
        let ink = GraphicsContext.Shading.color(.primary)
        let muted = GraphicsContext.Shading.color(.primary.opacity(0.42))
        for i in 0..<n {
            let g = gains[i]
            let bw = baseW * (1 + 1.1 * g)
            let v = max(0.06, min(1, bars[i] / 100))
            let h = min(size.height, (size.height * 0.8 * v) * (1 + 0.62 * g) + 6 * g)
            let x = xs[i] + shift + (widths[i] - bw) / 2
            let r = CGRect(x: x, y: (size.height - h) / 2, width: bw, height: max(bw, h))
            let isPlayed = (Double(i) + 0.5) / Double(n) <= played
            ctx.fill(Path(roundedRect: r, cornerRadius: bw / 2), with: isPlayed ? ink : muted)
        }
    }
}
