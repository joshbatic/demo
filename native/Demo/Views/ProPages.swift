import SwiftUI

/// The Pro screen's moving pictures (same as the web's pwc*): five pages that move on by themselves every few
/// seconds until you touch them — what Pro is, lyric sync, help when you're stuck, writing together, and the rest.
/// Each page plays its little scene while it's showing. Drawn at 360 × 430 and scaled to fit. Still with Reduce Motion.
struct ProPages: View {
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var page = 0
    @State private var held = false
    @State private var shownAt = Date()
    private let labels = ["What’s in Pro", "Lyric sync", "Help when you’re stuck", "Write together", "And even more"]

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { g in
                let s = min(1, g.size.width / 360)
                TabView(selection: $page) {
                    ForEach(0..<5, id: \.self) { i in
                        TimelineView(.animation(minimumInterval: 1 / 30, paused: still || page != i)) { tl in
                            let t = still ? 30 : (page == i ? max(0, tl.date.timeIntervalSince(shownAt)) : 0)
                            ProPage(index: i, t: t)
                                .frame(width: 360, height: 430)
                                .scaleEffect(s, anchor: .top)
                                .frame(width: g.size.width, height: 430 * s, alignment: .top)
                        }
                        .tag(i)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(labels[i])
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in held = true })
            }
            .frame(height: 430 * min(1, (UIScreen.main.bounds.width) / 360))
            HStack(spacing: 7) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(i == page ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: i == page ? 18 : 7, height: 7)
                        .onTapGesture { held = true; withAnimation(.snappy) { page = i } }
                        .accessibilityLabel(labels[i]).accessibilityAddTraits(i == page ? [.isButton, .isSelected] : .isButton)
                }
            }
            .animation(.snappy, value: page)
        }
        .onChange(of: page) { _, _ in shownAt = Date() }
        .task {
            guard !still else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5.2))
                if held { break }
                withAnimation(.smooth(duration: 0.55)) { page = (page + 1) % 5 }
            }
        }
    }
}

private struct ProPage: View {
    let index: Int
    /// seconds since this page came into view
    let t: Double
    private let ink = Color(red: 29/255, green: 29/255, blue: 31/255)

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch index {
            case 0: intro
            case 1: lyricSync
            case 2: help
            case 3: together
            default: more
            }
        }
        .frame(width: 360, height: 430, alignment: .topLeading)
        .clipped()
    }

    // MARK: pieces

    private func caption(_ b: String, _ s: String) -> some View {
        VStack(spacing: 5) {
            Text(b).font(.system(size: 21, weight: .bold)).tracking(-0.3)
            Text(s).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center).frame(width: 308).position(x: 180, y: 380)
    }

    private func glass<C: View>(_ r: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
        c().foregroundStyle(ink)
            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: r, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(.white, lineWidth: 0.6))
            .shadow(color: Color(red: 40/255, green: 60/255, blue: 90/255).opacity(0.13), radius: 15, y: 10)
    }

    private func mono(_ s: String) -> some View { Text(s).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(white: 0.56)) }

    private func thumb(_ id: String, _ size: CGFloat) -> some View {
        let p = CoverPick(id: id)
        return RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(LinearGradient(colors: [p.b, p.a], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(GlassRecord(pick: p, size: size * 0.72))
            .frame(width: size, height: size)
    }

    private func bars(_ n: Int, _ seed: Double, _ h: Double, lit: (Int) -> Color) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<n, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(lit(i))
                    .frame(height: 5 + abs(sin(Double(i) * seed) * h + sin(Double(i) * 0.4) * 5))
            }
        }
    }

    // MARK: 1 · what Pro is

    private var intro: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                floater("pro-a", 130, -40, -60, 0)
                floater("pro-b", 140, 115, -80, 0.8)
                floater("pro-c", 130, 255, -50, 1.6)
                floater("pro-d", 120, 20, 70, 0.4)
                floater("pro-e", 110, 150, 80, 1.2)
                floater("pro-f", 120, 266, 90, 2)
            }
            .frame(width: 360, height: 200, alignment: .topLeading)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.35), .init(color: .clear, location: 0.92)], startPoint: .top, endPoint: .bottom))
            (Text("Turn every ") + Text("[").fontWeight(.light).foregroundColor(.secondary) + Text("demo") + Text("]").fontWeight(.light).foregroundColor(.secondary) + Text(" into a finished song"))
                .font(.system(size: 27, weight: .heavy)).tracking(-0.8).multilineTextAlignment(.center)
                .frame(width: 316).position(x: 180, y: 145)
            VStack(alignment: .leading, spacing: 18) {
                feat("waveform", "Your demos, everywhere", "5 GB for demos, mixes and stems, and voice memos synced to every device.", 0)
                feat("pencil", "Help when you’re stuck", "Lines in your voice, an honest Rate, lyric sync and Perform mode.", 1)
                feat("person.2", "Write together", "Invite co-writers to your songs, and send links people can listen to.", 2)
            }
            .frame(width: 314, alignment: .leading).offset(x: 24, y: 206)
        }
    }

    private func floater(_ id: String, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ d: Double) -> some View {
        GlassRecord(pick: CoverPick(id: id), size: size)
            .rotationEffect(.degrees((t / (10 + d * 3)) * 360))
            .offset(x: x, y: y - 4 * (1 - cos((t + d) * .pi / 3)))
    }

    private func feat(_ icon: String, _ b: String, _ s: String, _ k: Int) -> some View {
        let p = min(1, max(0, (t - Double(k) * 0.12) / 0.5))
        return HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(b).font(.system(size: 15.5, weight: .semibold))
                Text(s).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(p).offset(y: 8 * (1 - p))
    }

    // MARK: 2 · lyric sync

    private var lyricSync: some View {
        let lines = ["and the radio hums", "the part I couldn’t say", "I keep the window open", "in case the weather brings you"]
        let now = Int(t / 1.1) % lines.count
        let b = Int(t / 0.11) % 40
        let cur = 58 + b / 4, left = 228 - cur
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hex: 0xD4E9F1), Color(hex: 0xBCD9E6), Color(hex: 0xE9E1F5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        thumb("pro-song", 42)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Kitchen Light").font(.system(size: 13, weight: .bold))
                            Text("demo v4").font(.system(size: 11)).foregroundStyle(Color(hex: 0x4D6470))
                        }
                    }
                    .padding([.top, .horizontal], 16)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(lines.indices, id: \.self) { k in
                            Text(lines[k]).font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color(hex: 0x14283A).opacity(k == now ? 1 : k < now ? 0.5 : 0.3))
                                .scaleEffect(k == now ? 1.12 : 1, anchor: .leading)
                                .animation(.easeOut(duration: 0.4), value: now)
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 20)
                }
                .foregroundStyle(ink)
                VStack(spacing: 4) {
                    bars(40, 1.3, 14) { $0 <= b ? ink : ink.opacity(0.22) }.frame(height: 26)
                    HStack {
                        Text("\(cur / 60):" + String(format: "%02d", cur % 60))
                        Spacer()
                        Text("−\(left / 60):" + String(format: "%02d", left % 60))
                    }
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: 0x555566))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(12).frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: 236, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: Color(red: 40/255, green: 70/255, blue: 100/255).opacity(0.22), radius: 20, y: 18)
            .offset(x: 62, y: 16)
            caption("Sing along to your demo", "Lyric sync lights up each line as it plays")
        }
    }

    // MARK: 3 · help when you're stuck

    private var help: some View {
        let lines = ["the porch is the only thing awake", "I left it on like a question", "your coat still waiting by the door"]
        // typing: 28 ms a character, 260 ms between lines, after 300 ms
        var typed = [String](repeating: "", count: 3)
        var left = max(0, t - 0.3)
        for k in 0..<3 {
            let full = Double(lines[k].count) * 0.028
            if left >= full { typed[k] = lines[k]; left -= full + 0.26 } else { typed[k] = String(lines[k].prefix(Int(left / 0.028))); break }
        }
        let score = min(8.4, Double(Int(t / 0.04) * 3) / 10)
        let words = ["night", "bright", "alight", "tonight", "white"]
        return ZStack(alignment: .topLeading) {
            glass(22) {
                VStack(alignment: .leading, spacing: 0) {
                    mono("Lines in your voice")
                    ForEach(0..<3, id: \.self) { k in
                        Text(typed[k]).font(.system(size: 13.5)).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        if k < 2 { Divider() }
                    }
                }
                .padding(14)
            }
            .frame(width: 206).rotationEffect(.degrees(-3)).offset(x: 26, y: 20)
            VStack(alignment: .leading, spacing: 2) {
                mono("Rate").foregroundStyle(.white.opacity(0.6))
                Text(String(format: "%.1f", score)).font(.system(size: 46, weight: .heavy)).tracking(-1.5)
                Text("Strong chorus. Verse 2 repeats an image.").font(.system(size: 11.5)).opacity(0.75)
            }
            .foregroundStyle(.white).padding(14).frame(width: 150, height: 140, alignment: .topLeading)
            .background(ink, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 15, y: 14)
            .rotationEffect(.degrees(4)).offset(x: 188, y: 170)
            FlowWords(words: words, shown: { k in t > 0.9 + Double(k) * 0.16 }, ink: ink)
                .frame(width: 160, alignment: .leading).offset(x: 28, y: 238)
            caption("Help when you’re stuck", "Next lines that sound like you, and an honest read of the song")
        }
    }

    // MARK: 4 · write together

    private var together: some View {
        let word = "parade"
        let typed = String(word.prefix(max(0, min(word.count, Int((t - 0.5) / 0.16) + 1))))
        let plays = min(12, 9 + Int(t / 0.9))
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 12) {
                glass(22) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            thumb("pro-north", 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Northbound").font(.system(size: 14, weight: .bold))
                                Text("Mia is editing verse 2").font(.system(size: 11.5)).foregroundStyle(Color(white: 0.43))
                            }
                            Spacer(minLength: 0)
                            HStack(spacing: -8) {
                                ForEach([(0x7A5AF8, "J"), (0xF2709C, "M"), (0x2FB28A, "S")], id: \.1) { c in
                                    Text(c.1).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 30, height: 30).background(Color(hex: UInt32(c.0)), in: Circle())
                                        .overlay(Circle().stroke(.white, lineWidth: 2))
                                }
                            }
                        }
                        (Text("headlights in the rain like a ") + Text(t > 0.5 ? typed : "").foregroundColor(Color(hex: 0xC2185B)))
                            .font(.system(size: 14))
                    }
                    .padding(14)
                }
                glass(18) {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(ink, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text("listen.hellodemo.app/k7Qm2").font(.system(size: 12.5, weight: .semibold))
                            Text("Link with audio · \(plays) plays").font(.system(size: 11)).foregroundStyle(Color(white: 0.43))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .rotationEffect(.degrees(-2))
            }
            .frame(width: 252).offset(x: 54, y: 30)
            caption("Write together", "Invite co-writers, and share links people can actually listen to")
        }
    }

    // MARK: 5 · and even more

    private var more: some View {
        let x = Int(t / 0.06) % (46 + 12)
        let draw = min(1, t / 2.4)
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    mono("Perform").foregroundStyle(Color(hex: 0x4D6470))
                    (Text("the part I couldn’t say\n") + Text("I keep the window open").foregroundColor(Color(hex: 0x14313D).opacity(0.45)))
                        .font(.system(size: 17, weight: .heavy)).foregroundStyle(Color(hex: 0x14313D)).lineSpacing(1)
                        .offset(y: -22 * min(1, t / 3.2)).frame(height: 66, alignment: .top).clipped()
                    Spacer(minLength: 0)
                    Text("92 BPM").font(.system(size: 10, design: .monospaced)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(10).frame(width: 150, height: 144, alignment: .topLeading)
                .background(LinearGradient(colors: [Color(hex: 0xCFE7F0), Color(hex: 0xE9E1F5)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                glass(18) {
                    VStack(alignment: .leading, spacing: 0) {
                        mono("Find Release").padding(.bottom, 4)
                        ForEach([("ISRC", "AUXYZ2512345"), ("UPC", "1984725…"), ("Label", "Self-released")], id: \.0) { r in
                            HStack { Text(r.0).foregroundStyle(Color(white: 0.43)); Spacer(); Text(r.1).fontWeight(.semibold) }
                                .font(.system(size: 11)).padding(.vertical, 6)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10).frame(width: 152, height: 144, alignment: .topLeading)
                }
                .offset(x: 172)
                HStack(spacing: 10) {
                    bars(46, 1.1, 16) { k in k > x - 12 && k <= x ? Color(hex: 0xFFD45E) : .white.opacity(0.35) }.frame(height: 30)
                    Text("Stems").font(.system(size: 10, design: .monospaced)).foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(.white, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(10).frame(width: 324, height: 60)
                .background(ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .offset(y: 156)
                glass(18) {
                    GlassRecord(pick: CoverPick(id: "pro-c"), size: 72).rotationEffect(.degrees(t / 8 * 360))
                        .frame(width: 96, height: 92)
                }
                .offset(y: 228)
                glass(18) {
                    VStack(alignment: .leading, spacing: 0) {
                        mono("Melody")
                        MelodyLine().trim(from: 0, to: draw).stroke(Color(hex: 0x7A5AF8), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(height: 56)
                    }
                    .padding(10).frame(width: 216, height: 92, alignment: .topLeading)
                }
                .offset(x: 108, y: 228)
            }
            .offset(x: 18, y: 16)
            caption("And even more", "Perform mode, Find Release, stems, melody, unlimited albums and more")
        }
    }
}

/// Rhyme chips that pop in one by one.
private struct FlowWords: View {
    let words: [String]
    let shown: (Int) -> Bool
    let ink: Color
    var body: some View {
        let rows = [Array(words.prefix(2)), Array(words.dropFirst(2).prefix(2)), Array(words.dropFirst(4))]
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r], id: \.self) { w in
                        let k = words.firstIndex(of: w) ?? 0
                        Text(w).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.white.opacity(0.85), in: Capsule())
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 4)
                            .opacity(shown(k) ? 1 : 0).scaleEffect(shown(k) ? 1 : 0.8)
                            .animation(.easeOut(duration: 0.3), value: shown(k))
                    }
                }
            }
        }
    }
}

private struct MelodyLine: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 160, sy = r.height / 56
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var path = Path()
        path.move(to: p(4, 40))
        path.addCurve(to: p(46, 30), control1: p(20, 10), control2: p(34, 10))
        path.addCurve(to: p(86, 22), control1: p(58, 50), control2: p(70, 50))
        path.addCurve(to: p(132, 30), control1: p(102, -6), control2: p(118, 8))
        path.addCurve(to: p(156, 34), control1: p(146, 52), control2: p(150, 44))
        return path
    }
}
