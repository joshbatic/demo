import SwiftUI
import WidgetKit

// MARK: - Record Idea: tap to start recording in Ideas

struct RecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "record", provider: SnapProvider()) { e in
            RecordView(snap: e.snap)
                .widgetURL(Links.url("record"))
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Record Idea")
        .description("One tap and you’re recording. Write it down before it’s gone.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
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
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.title3).widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Record Idea").font(.headline)
                    Text("*[demo]").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label("Record Idea", systemImage: "mic.fill")
        default:
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Mark(size: 30)
                    Spacer()
                    if snap.ideaCount > 0 {
                        Text("\(snap.ideaCount)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if let idea = snap.idea, !idea.isEmpty {
                    Text(idea).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 6)
                }
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").font(.system(size: 13, weight: .bold))
                    Text("Record Idea").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color(.systemBackground))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Color.primary, in: Capsule())
            }
        }
    }
}

// MARK: - Recent Songs: your latest songs, tap one to open it

struct SongsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "songs", provider: SnapProvider()) { e in
            SongsView(snap: e.snap)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Recent Songs")
        .description("Jump back into what you were writing.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct SongsView: View {
    @Environment(\.widgetFamily) private var family
    let snap: Snapshot

    var body: some View {
        let n = family == .systemLarge ? 4 : 2
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Mark(size: 24)
                Text("*[demo]").font(.system(size: 15, weight: .bold))
                Spacer()
                Link(destination: Links.url("new-song")) {
                    Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30).background(Color(.secondarySystemFill), in: Circle())
                }
                Link(destination: Links.url("record")) {
                    Image(systemName: "mic.fill").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 30, height: 30).background(Color.primary, in: Circle())
                }
            }
            .padding(.bottom, 8)
            if !snap.signedIn || snap.songs.isEmpty {
                Spacer()
                Text(snap.signedIn ? "Your songs show here." : "Open *[demo] to sign in.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(Array(snap.songs.prefix(n).enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider().padding(.leading, 2) }
                    Link(destination: Links.url("song", s.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            Text(ago(s.updated)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, family == .systemLarge ? 9 : 6)
                    }
                }
                if family == .systemLarge, let idea = snap.idea, !idea.isEmpty {
                    Spacer(minLength: 8)
                    Link(destination: Links.url("new-idea")) {
                        HStack(spacing: 8) {
                            Image(systemName: "lightbulb").foregroundStyle(.secondary)
                            Text(idea).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(10).background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

#Preview(as: .systemMedium) { SongsWidget() } timeline: { SnapEntry(date: .now, snap: .sample) }
#Preview(as: .systemSmall) { RecordWidget() } timeline: { SnapEntry(date: .now, snap: .sample) }
