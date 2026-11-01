import SwiftUI
import UIKit
import WidgetKit

/// Shortcuts into the app: the long-press menu on the app icon, the widgets and the Control Centre button.
/// Each one is a link, demo-native://<action>[/<song id>], so every way in goes through `open(_:)`:
///   new-song     a blank song, ready to type
///   record       Ideas, recording straight away
///   new-idea     Ideas, the keyboard up in the jot box
///   song/<id>    that song
/// (demo-native:// is also the sign-in callback scheme; those links never reach `open`, sign-in catches them.)
@MainActor
enum QuickActions {
    static let scheme = "demo-native"

    static func url(_ action: String, _ id: String? = nil) -> URL {
        URL(string: "\(scheme)://\(action)" + (id.map { "/" + $0 } ?? ""))!
    }

    /// Something asked for one of the actions: remember it until the song list can carry it out
    /// (straight away when the app is open; after launch and sign-in when it isn't).
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard url.scheme == scheme, let host = url.host(), host != "auth-callback" else { return false }
        let session = AppSession.shared
        switch host {
        case "song":
            let id = url.lastPathComponent
            guard !id.isEmpty, id != "/" else { return false }
            session.openSongID = id
        case "new-song", "record", "new-idea":
            session.quickAction = host
        default:
            return false
        }
        return true
    }

    static func perform(_ item: UIApplicationShortcutItem) {
        if item.type == "song", let id = item.userInfo?["id"] as? String { open(url("song", id)) }
        else { open(url(item.type)) }
    }

    /// The long-press menu: three fixed actions, then the song you were last in. Rebuilt whenever the app
    /// goes to the background (the last song changes). iOS shows the first item nearest the icon.
    static func refresh(_ library: LibraryStore) {
        var items: [UIApplicationShortcutItem] = [
            UIApplicationShortcutItem(type: "new-song", localizedTitle: "New Song", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil")),
            UIApplicationShortcutItem(type: "record", localizedTitle: "Record Idea", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "mic")),
            UIApplicationShortcutItem(type: "new-idea", localizedTitle: "New Idea", localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "text.badge.plus")),
        ]
        if AppSession.shared.userID != nil, let s = recent(library, 1).first {
            items.append(UIApplicationShortcutItem(type: "song", localizedTitle: s.displayTitle, localizedSubtitle: "Last song",
                                                   icon: UIApplicationShortcutIcon(systemImageName: "music.note"),
                                                   userInfo: ["id": s.id as NSString]))
        }
        UIApplication.shared.shortcutItems = items
        WidgetShare.write(library)
    }

    static func recent(_ library: LibraryStore, _ n: Int) -> [Song] {
        Array(library.songs.filter { !$0.isPlaceholder }.sorted { $0.updated > $1.updated }.prefix(n))
    }
}

/// What the widgets show, written to the app group they share with the app: titles and dates only, never lyrics.
/// The widget extension has its own copy of `Snapshot` (DemoWidget/WidgetData.swift); keep the two the same.
@MainActor
enum WidgetShare {
    static let group = "group.app.hellodemo.demo"
    static let key = "widget.snapshot"

    nonisolated struct Snapshot: Codable, Equatable {
        struct Item: Codable, Equatable { var id: String; var title: String; var detail: String; var updated: Double }
        var signedIn: Bool
        var songs: [Item]
        var idea: String?
        var ideaCount: Int
    }

    static func write(_ library: LibraryStore) {
        guard let d = UserDefaults(suiteName: group) else { return }
        let signedIn = AppSession.shared.userID != nil
        let songs = signedIn ? QuickActions.recent(library, 4).map { s in
            Snapshot.Item(id: s.id, title: s.displayTitle,
                          detail: [s.status, s.key].filter { !$0.isEmpty }.joined(separator: " · "), updated: s.updated)
        } : []
        let ideas = signedIn ? library.ideas.sorted { $0.updated > $1.updated } : []
        let latest = ideas.first.map { $0.text.isEmpty ? ($0.hasMemo ? "Voice memo" : "") : $0.text }
        let snap = Snapshot(signedIn: signedIn, songs: songs, idea: latest, ideaCount: ideas.count)
        guard let data = try? JSONEncoder().encode(snap), data != d.data(forKey: key) else { return }
        d.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// The app icon's menu arrives here: at launch (the scene's connection options) or while running.
final class QuickSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { QuickActions.perform(item) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        QuickActions.perform(shortcutItem)
        completionHandler(true)
    }
}
