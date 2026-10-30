import Foundation

/// Backend settings. The Supabase key here is the public "anon" key the web app already ships;
/// row-level security on the server decides what each signed-in account can read and write.
nonisolated enum Config {
    static let supabaseURL = URL(string: "https://cygfgurzvmbtcegkpnss.supabase.co")!
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN5Z2ZndXJ6dm1idGNlZ2twbnNzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2ODk0MTIsImV4cCI6MjEwNzI2NTQxMn0.kJhE1V8V_W1BIuu0iSVaLqa5GyxeOrUy0lrqylq4_Cs"
    /// Sign-in redirects come back to the app on this scheme (registered in Info).
    static let authScheme = "demo-native"
    static let authCallback = URL(string: "demo-native://auth-callback")!
    /// RevenueCat public iOS key (appl_…), filled in once the App Store subscriptions are live.
    static let revenueCatKey = "appl_XNKRNsIsXDlJzSerQvGGVffIHWd"
    static let proEntitlement = "demo_pro"
    /// The App Store app's Apple ID (App Store Connect › App Information › Apple ID), for "Time to update".
    static let appStoreID = ""
    static var appStoreURL: URL {
        appStoreID.isEmpty ? URL(string: "https://hellodemo.app")! : URL(string: "itms-apps://apps.apple.com/app/id\(appStoreID)")!
    }
    static let listenHost = "listen.hellodemo.app"
    /// The build number, shared with the web and Mac apps' APP_SEQ (the repo's commit count, written by
    /// scripts/stamp-version.sh), so Admin › Minimum Build ("Time to update") covers every app on one scale.
    static let appSeq = 649
    /// The commit that build was made from (also written by scripts/stamp-version.sh), shown with it in Account.
    static let appHash = "4ec0317"
    /// The version people see (Account › Version), the same number as the Mac app: 1.0.0.
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    /// Sent with diagnostics and push registration: the version and build number.
    static var appCommit: String {
        let i = Bundle.main.infoDictionary
        return "native " + (i?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (i?["CFBundleVersion"] as? String ?? "?") + ")"
    }
    /// The [developer] build: its bundle id ends in ".dev" (it turns on dev features, and never shows "Time to update").
    static var isDevBuild: Bool { (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev") }
    /// Push topic = the bundle id.
    static var pushTopic: String { Bundle.main.bundleIdentifier ?? "app.hellodemo.demo" }
}
