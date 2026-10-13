import UIKit
import WebKit
import Capacitor

// Suppresses the native "Previous / Next / Done" keyboard accessory bar that WKWebView
// shows above the keyboard for contenteditable/text fields. The app has its own toolbar
// that docks right above the keyboard, and this system bar was sitting between the two,
// duplicating the up/down navigation and breaking the illusion of one seamless toolbar.
// WKWebView doesn't expose a public API for this — the accessory view actually belongs
// to its private internal content view ("WKContentView"), so this swizzles that view's
// inputAccessoryView to always return nil. This is a long-standing, widely used technique;
// if a future WebKit version renames/removes that private class, this simply becomes a
// no-op (the bar would reappear) rather than crashing.
private final class NoInputAccessoryView: UIView {
    @objc var noInputAccessoryView: UIView? { nil }
}
extension WKWebView {
    private static let swizzleInputAccessoryOnce: Void = {
        guard let contentViewClass = NSClassFromString("WKContentView") else { return }
        let originalSelector = NSSelectorFromString("inputAccessoryView")
        guard let swizzledMethod = class_getInstanceMethod(NoInputAccessoryView.self, #selector(getter: NoInputAccessoryView.noInputAccessoryView)) else { return }
        if let originalMethod = class_getInstanceMethod(contentViewClass, originalSelector) {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        } else {
            class_addMethod(contentViewClass, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod))
        }
    }()
    func removeInputAccessoryView() {
        WKWebView.swizzleInputAccessoryOnce
    }
}

class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        guard let webView = bridge?.webView else { return }
        webView.scrollView.bounces = false
        webView.scrollView.isDirectionalLockEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.removeInputAccessoryView()
        // Tried disabling the outer scroll view entirely here to stop iOS's automatic "scroll to
        // reveal the focused field" from fighting the page's own keyboard-avoidance math — but that
        // also threw off how WKWebView reports window.innerHeight/visualViewport while the keyboard
        // is up, which made things worse (the page's math was then working from a bad number). Left
        // the scroll view enabled; the fix now lives entirely in the page's own JS, which snaps the
        // outer scroll position back to (0,0) whenever iOS tries to move it.
    }

    // The system Copy/Paste/Cut/Look Up/Share selection menu was suppressed here via buildMenu,
    // and separately via a canPerformAction override on WKWebView that turned out to break plain
    // single-tap cursor placement (it blanket-denied every action query WebKit makes on the view,
    // not just edit-menu ones). Both are gone now — the native edit menu is back.
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        if let rootViewController = storyboard.instantiateInitialViewController() {
            window.rootViewController = rootViewController
        }
        self.window = window
        window.makeKeyAndVisible()
        // Cold launch via a demo:// URL (app wasn't already running when Google's sign-in redirect
        // came back) hands the URL here, in connectionOptions, not to AppDelegate's
        // application(_:open:options:) — see the comment on scene(_:openURLContexts:) below for why.
        if let urlContext = connectionOptions.urlContexts.first {
            ApplicationDelegateProxy.shared.application(UIApplication.shared, open: urlContext.url, options: [:])
        }
    }

    // Once an app declares UIApplicationSceneManifest in Info.plist (this one does), iOS stops
    // calling AppDelegate's application(_:open:options:) for URL-scheme opens and delivers them
    // here instead. That AppDelegate override below still exists but is now dead code — harmless,
    // just never invoked. Without this method, Google sign-in's demo://auth-callback redirect was
    // arriving back at the app and going nowhere: the App plugin's 'appUrlOpen' listener (which
    // index.html's signInGoogle flow waits on to complete the session) never fired, so sign-in
    // silently stalled after the browser closed. Forwarding to the same ApplicationDelegateProxy
    // the AppDelegate used to call fixes it, since that proxy is what actually posts the
    // notification the App plugin listens for — it doesn't matter which delegate calls it.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        ApplicationDelegateProxy.shared.application(UIApplication.shared, open: url, options: [:])
    }

}
