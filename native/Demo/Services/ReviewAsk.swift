import Foundation

/// Asks for an App Store rating at a good moment: back on the song list after writing, once the account has three
/// songs with real lyrics (four lines or more), the app has been on this phone for two days, and it hasn't asked
/// in this version. Apple's own prompt (it decides whether to show it, and at most three times a year).
@MainActor
enum ReviewAsk {
    private static let firstKey = "demo:firstOpen", askedKey = "demo:reviewAsked"

    static func noteOpen() {
        if UserDefaults.standard.object(forKey: firstKey) == nil { UserDefaults.standard.set(Date(), forKey: firstKey) }
    }

    static func shouldAsk(_ library: LibraryStore) -> Bool {
        let d = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard d.string(forKey: askedKey) != version,
              let first = d.object(forKey: firstKey) as? Date, Date().timeIntervalSince(first) > 2 * 86_400 else { return false }
        let written = library.songs.filter { !$0.isPlaceholder && $0.id != Guide.id && $0.lyricLines.count >= 4 }.count
        guard written >= 3 else { return false }
        d.set(version, forKey: askedKey)
        return true
    }
}
