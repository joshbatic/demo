import SwiftUI
import UIKit

/// Perform (spec §2.10): a full-screen teleprompter with the lyrics' own formatting, text size, speed and
/// auto-scroll (28 pt a second × speed). Tapping the words plays or pauses. The screen stays awake.
struct PerformView: View {
    let songID: String
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("perf.size") private var size = 34.0
    @AppStorage("perf.speed") private var speedIndex = 2
    @State private var playing = false
    @State private var pos = ScrollPosition(edge: .top)
    @State private var y: CGFloat = 0
    @State private var maxY: CGFloat = 0
    @State private var dragging = false

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    private var speed: Double { Self.speeds[min(max(speedIndex, 0), Self.speeds.count - 1)] }
    private var song: Song? { library.song(songID) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(lyrics)
                        .lineSpacing(size * 0.18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                    // room to scroll the last line up to the middle
                    Color.clear.frame(height: UIScreen.main.bounds.height * 0.45)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
            }
            .scrollPosition($pos)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, v in if !playing || dragging { y = v } }
            .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.height - $0.containerSize.height) } action: { _, v in maxY = v }
            .onScrollPhaseChange { _, phase in
                dragging = phase == .interacting
                if dragging && playing { playing = false }
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            controls
        }
        .task(id: playing) { await roll() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .statusBarHidden()
    }

    private var lyrics: AttributedString {
        guard let s = song else { return AttributedString() }
        let ns = RichText.attributed(html: s.rich, plain: s.lyrics, font: .systemFont(ofSize: size, weight: .semibold), color: .label)
        return (try? AttributedString(ns, including: \.uiKit)) ?? AttributedString(s.lyrics)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(song?.displayTitle ?? "").font(.system(size: 22, weight: .bold)).lineLimit(1)
                let sub = [song?.artist ?? "", (song?.key ?? "").isEmpty ? "" : "Key of " + (song?.key ?? ""), (song?.bpm ?? "").isEmpty ? "" : (song?.bpm ?? "") + " BPM"].filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty { Text(sub).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.tint)
                    .frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(PressScale())
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 10)
        .background(.bar)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            ctl("textformat.size.smaller", "Smaller text") { size = max(20, size - 4) }
            ctl("textformat.size.larger", "Larger text") { size = min(72, size + 4) }
            Divider().frame(height: 24).padding(.horizontal, 4)
            ctl("minus", "Slower") { speedIndex = max(0, speedIndex - 1) }
            Text(speedLabel).font(.system(size: 15, weight: .semibold).monospacedDigit()).frame(minWidth: 44)
            ctl("plus", "Faster") { speedIndex = min(Self.speeds.count - 1, speedIndex + 1) }
            Divider().frame(height: 24).padding(.horizontal, 4)
            Button { toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.onTint)
                    .frame(width: 48, height: 48).background(Theme.tint, in: Circle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(playing ? "Pause" : "Play")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .glassCapsule()
        .padding(.bottom, 12)
    }

    private var speedLabel: String {
        let s = speed
        return (s == s.rounded() ? String(Int(s)) : String(s)) + "×"
    }

    private func ctl(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.tint)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }

    private func toggle() {
        Haptics.tap()
        if !playing && y >= maxY - 1 { y = 0; pos.scrollTo(y: 0) }   // at the end: start again from the top
        playing.toggle()
    }

    /// 28 pt a second × speed, about 60 times a second; stops at the end.
    private func roll() async {
        guard playing else { return }
        var last = Date()
        while playing && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            let now = Date(), dt = now.timeIntervalSince(last); last = now
            guard !dragging else { continue }
            y = min(maxY, y + CGFloat(28 * speed * dt))
            pos.scrollTo(y: y)
            if y >= maxY { playing = false }
        }
    }
}
