import Foundation

/// Backend settings. The Supabase key here is the public "anon" key the web app already ships;
/// row-level security on the server decides what each signed-in account can read and write.
enum Config {
    static let supabaseURL = URL(string: "https://cygfgurzvmbtcegkpnss.supabase.co")!
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN5Z2ZndXJ6dm1idGNlZ2twbnNzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2ODk0MTIsImV4cCI6MjEwNzI2NTQxMn0.kJhE1V8V_W1BIuu0iSVaLqa5GyxeOrUy0lrqylq4_Cs"
    /// Sign-in redirects come back to the app on this scheme (registered in Info).
    static let authScheme = "demo-native"
    static let authCallback = URL(string: "demo-native://auth-callback")!
    /// RevenueCat public iOS key (appl_…), filled in once the App Store subscriptions are live.
    static let revenueCatKey = ""
    static let proEntitlement = "pro"
    static let listenHost = "listen.hellodemo.app"
}
