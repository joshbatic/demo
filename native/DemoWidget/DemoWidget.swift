import SwiftUI
import WidgetKit

// The widgets follow Apple's own pattern in glass: one small label at the top, the content in system type,
// white words over a quiet tint of the latest song's colour. On a Clear Home Screen iOS swaps the tint for real
// glass over the wallpaper, which is the look these are drawn for.

/// The background: a quiet, smoky tint of the latest song's colour with a thin bright rim, so it reads as a pane
/// of glass. No glows or shading: the content carries the widget. iOS replaces it on Clear and Tinted screens.
struct WidgetTint: View {
    let snap: Snapshot
    var body: some View {
        let t = snap.tint ?? ["8E7FB8", "5E5288"]
        let a = Color(hexString: t[0]), b = Color(hexString: t.count > 1 ? t[1] : t[0])
        ZStack {
            LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom)
            Color.white.opacity(0.1)
            ContainerRelativeShape()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
    }
}

/// Secondary text on glass.
let wSecondary = Color.white.opacity(0.72)

/// The label at the top of a widget, like the coloured title on Apple's Notes widget, with something on the right.
struct WLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1).widgetAccentable()
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.system(size: 13, weight: .medium)).foregroundStyle(wSecondary) }
        }
        .foregroundStyle(.white)
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

/// A capsule button: white for the main action, glass for the rest.
struct WPill: View {
    let title: String?
    let icon: String
    var main = false
    var height: CGFloat = 34
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            if let title { Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1) }
        }
        .foregroundStyle(main ? Color.black.opacity(0.85) : .white)
        .frame(maxWidth: title == nil ? height : .infinity, minHeight: height, maxHeight: height)
        .frame(width: title == nil ? height : nil)
        .background(main ? Color.white.opacity(0.92) : Color.white.opacity(0.2), in: Capsule())
    }
}

/// A round button: white with a dark icon for the main action, glass with a white icon for the rest.
struct WRound: View {
    let icon: String
    var size: CGFloat
    var main = true
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(main ? Color.black.opacity(0.85) : .white)
            .frame(width: size, height: size)
            .background(main ? Color.white.opacity(0.92) : Color.white.opacity(0.22), in: Circle())
            .widgetAccentable(main)
    }
}

func ideasText(_ n: Int) -> String { n == 0 ? "Tap to record" : "\(n) \(n == 1 ? "idea" : "ideas")" }

// MARK: - Record Idea: small is one button, medium is three quick actions

struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "record", provider: SnapProvider()) { e in
            RecordView(snap: e.snap)
                .containerBackground(for: .widget) { WidgetTint(snap: e.snap) }
        }
        .configurationDisplayName("Record Idea")
        .description("One tap and you’re recording, or jot an idea or start a song.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct RecordView: View {
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
                Text(ideasText(snap.ideaCount)).font(.system(size: 13)).foregroundStyle(wSecondary).padding(.top, 1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(Links.url("record"))
        }
    }

    /// Medium: Record (white), Write Idea and New Song as round buttons with their names under them.
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
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
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
                .containerBackground(for: .widget) { WidgetTint(snap: e.snap) }
        }
        .configurationDisplayName("Continue Writing")
        .description("Pick up the song you were writing, right where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SongsView: View {
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
        .foregroundStyle(.white)
    }

    /// The cover and the song's name.
    private func heading(_ s: Snapshot.Item, cover: CGFloat) -> some View {
        HStack(spacing: 12) {
            WCover(item: s, size: cover, radius: cover * 0.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(s.detail).font(.system(size: 13)).foregroundStyle(wSecondary).lineLimit(1)
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
            if let p = s.prev { Text(p).font(.system(size: 15)).foregroundStyle(wSecondary).lineLimit(1) }
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
            Rectangle().fill(.white.opacity(0.25)).frame(height: 0.5).padding(.top, 12).padding(.bottom, 4)
            ForEach(snap.songs.dropFirst().prefix(4)) { r in
                Link(destination: Links.url("song", r.id)) {
                    HStack(spacing: 11) {
                        WCover(item: r, size: 34, radius: 7)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                            Text(r.line ?? r.detail).font(.system(size: 13)).foregroundStyle(wSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(ago(r.updated)).font(.system(size: 12.5)).foregroundStyle(wSecondary)
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
                .containerBackground(for: .widget) { WidgetTint(snap: e.snap) }
        }
        .configurationDisplayName("Rhyme of the Day")
        .description("A new word every day, with its rhymes. Tap to start a song with it.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct RhymeView: View {
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
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    WLabel(text: "Rhyme of the day")
                    Text(d.word).font(.system(size: 34, weight: .bold)).minimumScaleFactor(0.5).lineLimit(1).padding(.top, 6)
                    Spacer(minLength: 0)
                    Text("Tap to start a song").font(.system(size: 13)).foregroundStyle(wSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(d.rhymes.prefix(5)), id: \.self) { r in
                        Text(r).font(.system(size: 15)).foregroundStyle(wSecondary).lineLimit(1)
                    }
                }
                .frame(width: 110, alignment: .leading)
            }
            .foregroundStyle(.white)
            .widgetURL(Links.url("new-song"))
        default:
            VStack(alignment: .leading, spacing: 0) {
                WLabel(text: "Rhyme of the day")
                Text(d.word).font(.system(size: 28, weight: .bold)).minimumScaleFactor(0.5).lineLimit(1).padding(.top, 6)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(d.rhymes.prefix(3)), id: \.self) { r in
                        Text(r).font(.system(size: 15)).foregroundStyle(wSecondary).lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(Links.url("new-song"))
        }
    }
}
