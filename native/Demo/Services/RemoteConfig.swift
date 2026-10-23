import Foundation
import SwiftUI

/// app_config_public (data spec §2.7): an admin banner, maintenance switches and the "Time to update" floor.
/// Read at launch (+0.7 s), every 3 minutes while open, and on returning to the app if older than 30 s.
@MainActor @Observable
final class RemoteConfig {
    static let shared = RemoteConfig()

    struct Banner: Equatable { let id: String; let text: String; let warn: Bool }

    private(set) var aiOff = false
    private(set) var syncOff = false
    private(set) var uploadsOff = false
    private(set) var minSeq = 0
    private(set) var updateNote = ""
    /// the banner still to show this launch (not dismissed for good, not timed out)
    var banner: Banner?
    @ObservationIgnored private var at = Date.distantPast
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var shownThisLaunch = Set<String>()

    static let aiOffMessage = "AI features are paused for maintenance. They’ll be back shortly."
    static let syncOffMessage = "Lyric sync is paused for maintenance. It’ll be back shortly."
    static let uploadsOffMessage = "Adding music and files is paused for maintenance. Try again shortly."

    /// Blocks the app until it's updated (never in the dev build).
    var mustUpdate: Bool { !Config.isDevBuild && minSeq > Config.appSeq }

    init() {
        if let d = UserDefaults.standard.data(forKey: "songpad:cfg"), let v = try? JSONDecoder().decode(JSONValue.self, from: d) { apply(v, cached: true) }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(for: .seconds(180))
            }
        }
    }

    func foreground() { if Date().timeIntervalSince(at) > 30 { Task { await load() } } }

    func load() async {
        guard let v = try? await Backend.rpc("app_config_public"), v.object != nil else { return }
        at = Date()
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: "songpad:cfg") }
        apply(v, cached: false)
    }

    private func apply(_ v: JSONValue, cached: Bool) {
        aiOff = v["ai_off"]?.bool ?? false
        syncOff = v["sync_off"]?.bool ?? false
        uploadsOff = v["uploads_off"]?.bool ?? false
        minSeq = Int(v["min_seq"]?.number ?? 0)
        updateNote = v["update_note"]?.string ?? ""
        guard !cached else { return }
        let text = (v["banner"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = v["banner_id"]?.string ?? text
        let gone = UserDefaults.standard.string(forKey: "songpad:banner-x")
        if !text.isEmpty && id != gone && !shownThisLaunch.contains(id) {
            shownThisLaunch.insert(id)
            banner = Banner(id: id, text: text, warn: v["banner_kind"]?.string == "warn")
        } else if text.isEmpty {
            banner = nil
        }
    }

    /// Tapping (or ✕) dismisses that banner for good.
    func dismissBanner() {
        if let b = banner { UserDefaults.standard.set(b.id, forKey: "songpad:banner-x") }
        banner = nil
    }
}
