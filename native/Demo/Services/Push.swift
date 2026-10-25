import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Push notifications (spec §6.3, data spec §7.5). The system prompt shows once, a moment after someone first
/// signs in on this device; later moments (sharing a song, accepting an invite, Account) ask again only if it was never answered.
@MainActor @Observable
final class Push: NSObject {
    static let shared = Push()

    private(set) var status: UNAuthorizationStatus = .notDetermined
    @ObservationIgnored weak var session: AppSession?
    private var token: String? { get { UserDefaults.standard.string(forKey: "songpad:pushtok") } set { UserDefaults.standard.set(newValue, forKey: "songpad:pushtok") } }

    func refreshStatus() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// On sign-in: register quietly if permission was already given.
    func signedIn(session: AppSession) async {
        self.session = session
        if let p = pendingTap { pendingTap = nil; tapped(p) }
        await refreshStatus()
        if status == .authorized || status == .provisional || status == .ephemeral {
            UIApplication.shared.registerForRemoteNotifications()
        } else if status == .notDetermined && UserDefaults.standard.bool(forKey: Onboarding.doneKey) {
            // onboarding asks on its last step; someone who skipped past it gets the prompt once the list settles
            try? await Task.sleep(for: .seconds(1.5))
            await ask()
        }
    }

    /// Asks (system prompt) when not asked yet, with a toast that says why; registers when allowed.
    @discardableResult
    func ask(_ why: String? = nil) async -> Bool {
        await refreshStatus()
        switch status {
        case .notDetermined:
            if let why { session?.toast = why }
            let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await refreshStatus()
            if ok { UIApplication.shared.registerForRemoteNotifications() }
            return ok
        case .denied:
            return false
        default:
            UIApplication.shared.registerForRemoteNotifications()
            return true
        }
    }

    /// The APNs token: kept on the device and registered with the server, with this device's time zone.
    func gotToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        token = hex
        guard session?.userID != nil else { return }
        Task {
            _ = try? await Backend.rpc("push_register", ["p_token": .string(hex), "p_topic": .string(Config.pushTopic), "p_build": .string(Config.appCommit)])
            _ = try? await Backend.rpc("set_notify_prefs", ["p": .object(["tz": .string(TimeZone.current.identifier)])])
        }
    }

    /// On sign-out: this device stops getting this account's notifications.
    func forget() async {
        guard let t = token else { return }
        _ = try? await Backend.rpc("push_forget", ["p_token": .string(t)])
    }

    // MARK: arriving notifications

    /// In the foreground (the table in data spec §7.5).
    func foreground(_ info: [AnyHashable: Any], title: String, body: String) {
        guard let session else { return }
        let kind = info["kind"] as? String ?? ""
        switch kind {
        case "invite":
            Task { await Collab.shared.pullInvites() }
        case "support":
            session.toast = "*[demo] Support replied. See Account › Contact Support."
        case "cowrite":
            if let id = info["song"] as? String { Task { _ = await Collab.shared.pull(id) } }
        case "account":
            Task { await session.refreshPlan() }
            if !title.isEmpty { session.toast = title }
        default:
            let t = [title, body].filter { !$0.isEmpty }.joined(separator: ": ")
            if !t.isEmpty { session.toast = t }
        }
    }

    /// Tapped: open what it's about.
    /// A tap that launched the app can arrive before the session is ready; it's kept and run once it is.
    @ObservationIgnored private var pendingTap: [AnyHashable: Any]?

    func tapped(_ info: [AnyHashable: Any]) {
        guard let session, session.userID != nil else { pendingTap = info; return }
        let kind = info["kind"] as? String ?? ""
        switch kind {
        case "invite":
            Task { await Collab.shared.pullInvites() }
            session.accountFocus = nil; session.accountOpen = true
        case "support":
            session.accountFocus = "support"; session.accountOpen = true
        case "account":
            Task { await session.refreshPlan() }
            session.accountFocus = nil; session.accountOpen = true
        case "cowrite", "plays":
            if let id = info["song"] as? String {
                if kind == "cowrite" { Task { _ = await Collab.shared.pull(id) } }
                session.openSongID = id
            }
        case "nudge":
            session.openSongID = ""      // "" = back to the song list
        default:
            break
        }
    }
}

/// UIKit hooks for push: the device token, and notifications arriving or tapped.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { Push.shared.gotToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    // The completion-handler versions, not the async ones: iOS calls these off the main thread, and the async
    // versions on a main-actor app crash when a notification is tapped (a main-queue assertion). Hop to main
    // ourselves, then call the handler.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let c = notification.request.content
        let info = c.userInfo, title = c.title, body = c.body
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Push.shared.foreground(info, title: title, body: body) }
            completionHandler([])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Push.shared.tapped(info) }
            completionHandler()
        }
    }
}
