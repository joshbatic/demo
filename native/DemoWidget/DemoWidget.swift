import SwiftUI
import WidgetKit

// The widgets are glass: white words and buttons over the latest song's colour, which iOS swaps for real
// glass over the wallpaper when the Home Screen is set to Clear. White is always the main action.

/// The background: the latest song's colour, deep at the foot (the app writes it; a soft purple until then).
/// A widget's background: tinted glass in the song's colour. A brighter colour at the top left fading to a deep
/// one, a soft light catching the top corner, a gentle shade at the foot and a thin bright rim, so it reads as a
/// pane of coloured glass rather than flat paint. On a Clear or Tinted Home Screen iOS swaps this for its own glass.
struct WidgetTint: View {
    let snap: Snapshot
    var body: some View {
        let t = snap.tint ?? ["9C7BD8", "3E2F7A"]
        let a = Color(hexString: t[0]), b = Color(hexString: t.count > 1 ? t[1] : t[0])
        GeometryReader { g in
            let r = max(g.size.width, g.size.height)
            ZStack {
                LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.34), .white.opacity(0.08), .clear], center: .topLeading, startRadius: 0, endRadius: r * 0.95)
                RadialGradient(colors: [a.opacity(0.55), .clear], center: UnitPoint(x: 0.95, y: 0.15), startRadius: 0, endRadius: r * 0.6)
                LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .center, endPoint: .bottom)
                ContainerRelativeShape()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08), .white.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
        }
    }
}

/// The small label at the top of a widget: the asterisk, a name, and something on the right.
struct WLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "asterisk").font(.system(size: 10, weight: .bold))
            Text(text).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).fontWeight(.medium) }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.78))
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
                LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
    var height: CGFloat = 36
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            if let title { Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1) }
        }
        .foregroundStyle(main ? Color.black.opacity(0.85) : .white)
        .frame(maxWidth: title == nil ? height : .infinity, minHeight: height, maxHeight: height)
        .frame(width: title == nil ? height : nil)
        .background(main ? Color.white : Color.white.opacity(0.2), in: Capsule())
    }
}

/// The big round record button.
struct WRecordDisc: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(width: size, height: size)
            .background(Color.white, in: Circle())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .widgetAccentable()
    }
}

/// "Kitchen Light · 2h ago"
func stamp(_ s: Snapshot.Item) -> String { s.title + " · " + ago(s.updated) }

// MARK: - Record Idea: small is one big button, medium is three quick actions

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
            VStack(spacing: 0) {
                WLabel(text: "Ideas", trailing: snap.ideaCount > 0 ? "\(snap.ideaCount)" : nil)
                Spacer(minLength: 0)
                WRecordDisc(size: 68)
                Spacer(minLength: 0)
                Text("Record Idea").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
            }
            .widgetURL(Links.url("record"))
        }
    }

    /// Medium: Record (white), Write Idea and New Song, each a tile.
    private var quick: some View {
        VStack(spacing: 10) {
            WLabel(text: "*[demo]", trailing: snap.ideaCount > 0 ? "\(snap.ideaCount) \(snap.ideaCount == 1 ? "idea" : "ideas")" : nil)
            HStack(spacing: 10) {
                tile("Record", "mic.fill", "record", main: true)
                tile("Write Idea", "lightbulb", "new-idea")
                tile("New Song", "square.and.pencil", "new-song")
            }
        }
    }

    private func tile(_ title: String, _ icon: String, _ action: String, main: Bool = false) -> some View {
        Link(destination: Links.url(action)) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 21, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(main ? Color.black.opacity(0.85) : .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(main ? Color.white : Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                VStack(spacing: 10) {
                    WLabel(text: "Continue Writing")
                    Spacer(minLength: 0)
                    Text(snap.signedIn ? "Your songs show here." : "Open *[demo] to sign in.")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                    if family != .systemSmall { Link(destination: Links.url("new-song")) { WPill(title: "New Song", icon: "square.and.pencil", main: true) } }
                }
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

    /// Small: the cover top left, then the song and the line you were on, along the bottom.
    private func small(_ s: Snapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                WCover(item: s, size: 40, radius: 9)
                Spacer()
                Text(ago(s.updated)).font(.system(size: 11.5, weight: .semibold)).opacity(0.75)
            }
            Spacer(minLength: 4)
            Text(s.title).font(.system(size: 12, weight: .semibold)).opacity(0.78).lineLimit(1)
            Text(s.line ?? "No lyrics yet").font(.system(size: 17, weight: .bold)).lineLimit(3).minimumScaleFactor(0.85).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(Links.url("song", s.id))
    }

    /// Medium: the cover large on the left; the line before, the line you were on, then Continue and record.
    private func medium(_ s: Snapshot.Item) -> some View {
        HStack(spacing: 14) {
            WCover(item: s, size: 130, radius: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(stamp(s)).font(.system(size: 12, weight: .semibold)).opacity(0.78).lineLimit(1)
                if let p = s.prev { Text(p).font(.system(size: 13.5)).opacity(0.6).lineLimit(1).padding(.top, 7) }
                Text(s.line ?? "No lyrics yet").font(.system(size: 17, weight: .bold)).lineLimit(2).minimumScaleFactor(0.85)
                    .padding(.top, s.prev == nil ? 7 : 0)
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    Link(destination: Links.url("song", s.id)) { WPill(title: "Continue", icon: "square.and.pencil", main: true) }
                    Link(destination: Links.url("record")) { WPill(title: nil, icon: "mic.fill") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .widgetURL(Links.url("song", s.id))
    }

    /// Large: where you left off at the top, four recent songs, then Record, Idea and Song.
    private var large: some View {
        let s = snap.songs[0]
        return VStack(alignment: .leading, spacing: 0) {
            Link(destination: Links.url("song", s.id)) {
                HStack(spacing: 12) {
                    WCover(item: s, size: 64, radius: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Continue writing · " + ago(s.updated)).font(.system(size: 12, weight: .semibold)).opacity(0.78)
                        Text(s.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                        Text(s.line ?? "No lyrics yet").font(.system(size: 13.5)).opacity(0.8).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            Rectangle().fill(.white.opacity(0.28)).frame(height: 0.5).padding(.top, 12).padding(.bottom, 3)
            ForEach(snap.songs.dropFirst().prefix(4)) { r in
                Link(destination: Links.url("song", r.id)) {
                    HStack(spacing: 11) {
                        WCover(item: r, size: 38, radius: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                            Text(r.line ?? r.detail).font(.system(size: 12.5)).opacity(0.72).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(ago(r.updated)).font(.system(size: 12)).opacity(0.7)
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
