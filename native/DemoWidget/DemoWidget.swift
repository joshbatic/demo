import SwiftUI
import WidgetKit

// The widgets follow Apple's own pattern: one small label at the top, the content in system type, on the latest
// song's own pastel gradient (the colours its share page and album page use), in a deep shade of the same colour.
// On a Clear or Tinted Home Screen iOS swaps the colours for its glass and draws the words in white.

/// The latest song's colours, as the app writes them (Snapshot.tint): top, bottom, glow and ink.
struct WTheme {
    let top: Color, bot: Color, glow: Color, ink: Color
    init(_ snap: Snapshot) {
        let t = (snap.tint?.count ?? 0) >= 4 ? snap.tint! : ["E3D4FF", "BFDDFF", "FFD3BE", "3B2E5A"]
        top = Color(hexString: t[0]); bot = Color(hexString: t[1]); glow = Color(hexString: t[2]); ink = Color(hexString: t[3])
    }
}

extension EnvironmentValues {
    /// The words' colour: a deep shade of the song's colour.
    @Entry var wInk: Color = Color(red: 0.23, green: 0.18, blue: 0.35)
}

extension View {
    /// The song's colours behind the widget and its ink for the words.
    func wThemed(_ snap: Snapshot) -> some View {
        let t = WTheme(snap)
        return self.environment(\.wInk, t.ink)
            .containerBackground(for: .widget) { WidgetTint(theme: t) }
    }
}

/// The background, like the share page's: the colour washing diagonally into the next, a soft glow in the top
/// corner, and a thin bright rim.
struct WidgetTint: View {
    let theme: WTheme
    var body: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [theme.top, theme.bot], startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1))
                RadialGradient(colors: [theme.glow, theme.glow.opacity(0)], center: UnitPoint(x: 0.88, y: 0.04),
                               startRadius: 0, endRadius: max(g.size.width, g.size.height) * 0.75)
                ContainerRelativeShape()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
    }
}

/// The label at the top of a widget, like the coloured title on Apple's Notes widget, with something on the right.
struct WLabel: View {
    @Environment(\.wInk) private var ink
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1).widgetAccentable()
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.62)) }
        }
        .foregroundStyle(ink)
    }
}

/// A song's cover from the app, or a soft square while there isn't one yet.
struct WCover: View {
    let item: Snapshot.Item?
    var size: CGFloat
    var radius: CGFloat
    var body: some View {
        Group {
            if let img = coverImage(item?.cover) {
                Image(uiImage: img).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.72, green: 0.64, blue: 0.96), Color(red: 0.55, green: 0.74, blue: 0.96)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A capsule button: filled in the ink colour for the main action, frosted white for the rest.
struct WPill: View {
    @Environment(\.wInk) private var ink
    let title: String?
    let icon: String
    var main = false
    var height: CGFloat = 34
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            if let title { Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1) }
        }
        .foregroundStyle(main ? Color.white : ink)
        .frame(maxWidth: title == nil ? height : .infinity, minHeight: height, maxHeight: height)
        .frame(width: title == nil ? height : nil)
        .background(main ? ink : Color.white.opacity(0.5), in: Capsule())
    }
}

/// A round button: filled in the ink colour for the main action, frosted white for the rest.
struct WRound: View {
    @Environment(\.wInk) private var ink
    let icon: String
    var size: CGFloat
    var main = true
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(main ? Color.white : ink)
            .frame(width: size, height: size)
            .background(main ? ink : Color.white.opacity(0.5), in: Circle())
            .widgetAccentable(main)
    }
}

func ideasText(_ n: Int) -> String { n == 0 ? "Tap to record" : "\(n) \(n == 1 ? "idea" : "ideas")" }

// MARK: - Record Idea: small is one button, medium is three quick actions

struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "record", provider: SnapProvider()) { e in
            RecordView(snap: e.snap)
                .wThemed(e.snap)
        }
        .configurationDisplayName("Record Idea")
        .description("One tap and you’re recording, or jot an idea or start a song.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct RecordView: View {
    @Environment(\.wInk) private var ink
    @Environment(\.widgetFamily) private var family
    let snap: Snapshot

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.system(size: 20, weight: .semibold))
            }
            .widgetAccentable()
            .widgetURL(Links.url("record"))
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.title3).widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Record Idea").font(.headline)
                    Text("*[demo]").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(Links.url("record"))
        case .accessoryInline:
            Label("Record Idea", systemImage: "mic.fill").widgetURL(Links.url("record"))
        case .systemMedium:
            quick
        default:
            // the button top left, the words along the bottom
            VStack(alignment: .leading, spacing: 0) {
                WRound(icon: "mic.fill", size: 52)
                Spacer(minLength: 0)
                Text("Record idea").font(.system(size: 15, weight: .semibold))
                Text(ideasText(snap.ideaCount)).font(.system(size: 13)).foregroundStyle(ink.opacity(0.62)).padding(.top, 1)
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(Links.url("record"))
        }
    }

    /// Medium: Record (filled), Write Idea and New Song as round buttons with their names under them.
    private var quick: some View {
        VStack(spacing: 0) {
            WLabel(text: "*[demo]", trailing: snap.ideaCount > 0 ? ideasText(snap.ideaCount) : nil)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                button("Record", "mic.fill", "record", main: true)
                button("Write Idea", "lightbulb", "new-idea")
                button("New Song", "square.and.pencil", "new-song")
            }
            Spacer(minLength: 0)
        }
    }

    private func button(_ title: String, _ icon: String, _ action: String, main: Bool = false) -> some View {
        Link(destination: Links.url(action)) {
            VStack(spacing: 7) {
                WRound(icon: icon, size: 56, main: main)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Continue Writing: the song you were last in, and your other recent songs

struct SongsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "songs", provider: SnapProvider()) { e in
            SongsView(snap: e.snap)
                .wThemed(e.snap)
        }
        .configurationDisplayName("Continue Writing")
        .description("Pick up the song you were writing, right where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SongsView: View {
    @Environment(\.wInk) private var ink
    @Environment(\.widgetFamily) private var family
    let snap: Snapshot

    var body: some View {
        Group {
            if !snap.signedIn || snap.songs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    WLabel(text: "Continue writing")
                    Spacer(minLength: 0)
                    Text(snap.signedIn ? "Your songs show here." : "Open *[demo] to sign in.")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    if family != .systemSmall { Link(destination: Links.url("new-song")) { WPill(title: "New Song", icon: "square.and.pencil", main: true) } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(Links.url("new-song"))
            } else {
                switch family {
                case .systemSmall: small(snap.songs[0])
                case .systemLarge: large
                default: medium(snap.songs[0])
                }
            }
        }
        .foregroundStyle(ink)
    }

    /// The cover and the song's name.
    private func heading(_ s: Snapshot.Item, cover: CGFloat) -> some View {
        HStack(spacing: 12) {
            WCover(item: s, size: cover, radius: cover * 0.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(s.detail).font(.system(size: 13)).foregroundStyle(ink.opacity(0.62)).lineLimit(1)
            }
        }
    }

    /// Small: label, the cover, and the line you were on.
    private func small(_ s: Snapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WLabel(text: "Continue", trailing: ago(s.updated))
            HStack(spacing: 10) {
                WCover(item: s, size: 36, radius: 8)
                Text(s.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            }
            .padding(.top, 9)
            Spacer(minLength: 4)
            Text(s.line ?? "No lyrics yet").font(.system(size: 15)).lineLimit(2).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(Links.url("song", s.id))
    }

    /// Medium: like Apple's Notes widget. Label and time, the song, then the line before and the line you were on.
    private func medium(_ s: Snapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WLabel(text: "Continue writing", trailing: ago(s.updated))
            heading(s, cover: 48).padding(.top, 10)
            Spacer(minLength: 6)
            if let p = s.prev { Text(p).font(.system(size: 15)).foregroundStyle(ink.opacity(0.62)).lineLimit(1) }
            Text(s.line ?? "No lyrics yet").font(.system(size: 15, weight: .medium)).lineLimit(s.prev == nil ? 2 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(Links.url("song", s.id))
    }

    /// Large: where you left off at the top, four recent songs, then Record, Idea and Song.
    private var large: some View {
        let s = snap.songs[0]
        return VStack(alignment: .leading, spacing: 0) {
            WLabel(text: "Continue writing", trailing: ago(s.updated))
            Link(destination: Links.url("song", s.id)) {
                VStack(alignment: .leading, spacing: 8) {
                    heading(s, cover: 48)
                    Text(s.line ?? "No lyrics yet").font(.system(size: 15, weight: .medium)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 10)
            Rectangle().fill(ink.opacity(0.15)).frame(height: 0.5).padding(.top, 12).padding(.bottom, 4)
            ForEach(snap.songs.dropFirst().prefix(4)) { r in
                Link(destination: Links.url("song", r.id)) {
                    HStack(spacing: 11) {
                        WCover(item: r, size: 34, radius: 7)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                            Text(r.line ?? r.detail).font(.system(size: 13)).foregroundStyle(ink.opacity(0.62)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(ago(r.updated)).font(.system(size: 12.5)).foregroundStyle(ink.opacity(0.62))
                    }
                    .padding(.vertical, 5)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Link(destination: Links.url("record")) { WPill(title: "Record", icon: "mic.fill", main: true) }
                Link(destination: Links.url("new-idea")) { WPill(title: "Idea", icon: "lightbulb") }
                Link(destination: Links.url("new-song")) { WPill(title: "Song", icon: "square.and.pencil") }
            }
        }
    }
}

#Preview(as: .systemSmall) { RecordWidget() } timeline: { SnapEntry(date: .now, snap: .sample) }
#Preview(as: .systemMedium) { RecordWidget() } timeline: { SnapEntry(date: .now, snap: .sample) }
#Preview(as: .systemSmall) { SongsWidget() } timeline: { SnapEntry(date: .now, snap: .sample) }
#Preview(as: .systemMedium) { SongsWidget() } timeline: { SnapEntry(date: .now, snap: .sample) }
#Preview(as: .systemLarge) { SongsWidget() } timeline: { SnapEntry(date: .now, snap: .sample) }

// MARK: - Rhyme of the Day

struct RhymeEntry: TimelineEntry {
    let date: Date
    let day: RhymeOfTheDay.Day
    let snap: Snapshot
}

/// A new word at midnight; the colour still follows your latest song.
struct RhymeProvider: TimelineProvider {
    func placeholder(in context: Context) -> RhymeEntry { RhymeEntry(date: .now, day: RhymeOfTheDay.day(), snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (RhymeEntry) -> Void) {
        completion(RhymeEntry(date: .now, day: RhymeOfTheDay.day(), snap: Snapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RhymeEntry>) -> Void) {
        let snap = Snapshot.load()
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: .now) ?? .now)
        let entries = [RhymeEntry(date: .now, day: RhymeOfTheDay.day(), snap: snap),
                       RhymeEntry(date: midnight, day: RhymeOfTheDay.day(midnight), snap: snap)]
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }
}

struct RhymeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "rhyme", provider: RhymeProvider()) { e in
            RhymeView(e: e)
                .wThemed(e.snap)
        }
        .configurationDisplayName("Rhyme of the Day")
        .description("A new word every day, with its rhymes. Tap to start a song with it.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct RhymeView: View {
    @Environment(\.wInk) private var ink
    @Environment(\.widgetFamily) private var family
    let e: RhymeEntry

    var body: some View {
        let d = e.day
        switch family {
        case .accessoryInline:
            Text("\(d.word): \(d.rhymes.prefix(3).joined(separator: ", "))")
                .widgetURL(Links.url("new-song"))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Text("Rhyme of the day").font(.caption2).foregroundStyle(.secondary)
                Text(d.word).font(.headline).widgetAccentable()
                Text(d.rhymes.prefix(4).joined(separator: " · ")).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(Links.url("new-song"))
        case .systemMedium:
            VStack(alignment: .leading, spacing: 0) {
                WLabel(text: "Rhyme of the day", trailing: "Tap to start a song")
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 14) {
                    Text(d.word).font(.system(size: 40, weight: .bold)).tracking(-0.8)
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .frame(width: 118, alignment: .leading)
                    RhymeChips(words: RhymeChips.fit(d.rhymes, width: 176, rows: 3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink)
            .widgetURL(Links.url("new-song"))
        default:
            VStack(alignment: .leading, spacing: 0) {
                WLabel(text: "Rhyme of the day")
                Text(d.word).font(.system(size: 32, weight: .bold)).tracking(-0.6)
                    .minimumScaleFactor(0.5).lineLimit(1).padding(.top, 4)
                Spacer(minLength: 0)
                RhymeChips(words: RhymeChips.fit(d.rhymes, width: 140, rows: 2))
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(Links.url("new-song"))
        }
    }
}

/// The rhymes as glass chips, like the rhyme bar in the app, wrapping onto as many rows as `fit` chose.
struct RhymeChips: View {
    @Environment(\.wInk) private var ink
    let words: [String]
    var body: some View {
        ChipFlow(spacing: 5, rowSpacing: 6) {
            ForEach(words, id: \.self) { w in
                Text(w).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Color.white.opacity(0.5), in: Capsule())
                    .widgetAccentable()
            }
        }
    }

    /// The rhymes that fit in `rows` rows of `width` points, in order (a widget can't scroll or hide what spills over).
    static func fit(_ words: [String], width: CGFloat, rows: Int) -> [String] {
        let font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        var out: [String] = [], row = 1, x: CGFloat = 0
        for w in words {
            let cw = ceil((w as NSString).size(withAttributes: [.font: font]).width) + 20
            if cw > width { continue }
            if x > 0 && x + 5 + cw > width { row += 1; x = 0 }
            if row > rows { break }
            x += (x > 0 ? 5 : 0) + cw
            out.append(w)
        }
        return out
    }
}

/// Lays its views out left to right, wrapping onto new rows.
struct ChipFlow: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + rowSpacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + rowSpacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

