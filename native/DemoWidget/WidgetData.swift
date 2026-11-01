import Foundation
import SwiftUI
import WidgetKit

/// What the app shares with the widgets (Demo/Services/QuickActions.swift writes it): titles and dates, never lyrics.
/// Keep `Snapshot` the same as the app's copy.
struct Snapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable { var id: String; var title: String; var detail: String; var updated: Double }
    var signedIn: Bool
    var songs: [Item]
    var idea: String?
    var ideaCount: Int

    static let group = "group.app.hellodemo.demo"
    static let key = "widget.snapshot"

    static func load() -> Snapshot {
        guard let d = UserDefaults(suiteName: group)?.data(forKey: key),
              let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return .empty }
        return s
    }
    static let empty = Snapshot(signedIn: false, songs: [], idea: nil, ideaCount: 0)
    static let sample = Snapshot(signedIn: true, songs: [
        Item(id: "1", title: "Kitchen Light", detail: "Demo · G", updated: Date().timeIntervalSince1970 * 1000 - 3_600_000),
        Item(id: "2", title: "Salt in the Screen Door", detail: "Draft · D", updated: Date().timeIntervalSince1970 * 1000 - 86_400_000),
        Item(id: "3", title: "Ninety Days", detail: "Finished · Em", updated: Date().timeIntervalSince1970 * 1000 - 3 * 86_400_000),
    ], idea: "the sea doesn’t care who you came with", ideaCount: 5)
}

/// Links back into the app (QuickActions.open handles them).
enum Links {
    static func url(_ action: String, _ id: String? = nil) -> URL {
        URL(string: "demo-native://\(action)" + (id.map { "/" + $0 } ?? ""))!
    }
}

struct SnapEntry: TimelineEntry {
    let date: Date
    let snap: Snapshot
}

/// The app reloads the widgets whenever what they show changes, so one entry is enough.
struct SnapProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapEntry { SnapEntry(date: .now, snap: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (SnapEntry) -> Void) {
        let s = Snapshot.load()
        completion(SnapEntry(date: .now, snap: context.isPreview && s.songs.isEmpty ? .sample : s))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapEntry>) -> Void) {
        completion(Timeline(entries: [SnapEntry(date: .now, snap: Snapshot.load())], policy: .after(.now.addingTimeInterval(3600))))
    }
}

/// "3h ago" from the app's millisecond timestamps.
func ago(_ ms: Double) -> String {
    let d = Date(timeIntervalSince1970: ms / 1000)
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: d, relativeTo: .now)
}

/// The brand mark: the *[demo] asterisk, on the app's song-cover gradient.
struct Mark: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.84, green: 0.77, blue: 1), Color(red: 0.61, green: 0.78, blue: 1)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}
