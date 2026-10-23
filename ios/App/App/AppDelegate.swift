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

extension CapacitorBridge {
    private static let swizzlePresentVCOnce: Void = {
        let origPresent = #selector(CapacitorBridge.presentVC(_:animated:completion:))
        let swizPresent = #selector(CapacitorBridge.songpad_presentVC(_:animated:completion:))
        if let m1 = class_getInstanceMethod(CapacitorBridge.self, origPresent),
           let m2 = class_getInstanceMethod(CapacitorBridge.self, swizPresent) {
            method_exchangeImplementations(m1, m2)
        }

        let origDismiss = #selector(CapacitorBridge.dismissVC(animated:completion:))
        let swizDismiss = #selector(CapacitorBridge.songpad_dismissVC(animated:completion:))
        if let m1 = class_getInstanceMethod(CapacitorBridge.self, origDismiss),
           let m2 = class_getInstanceMethod(CapacitorBridge.self, swizDismiss) {
            method_exchangeImplementations(m1, m2)
        }
    }()

    static func swizzlePresentVC() {
        _ = swizzlePresentVCOnce
    }

    @objc func songpad_presentVC(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        guard let anchor = self.viewController else {
            songpad_presentVC(viewControllerToPresent, animated: flag, completion: completion)
            return
        }
        var top = anchor
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(viewControllerToPresent, animated: flag, completion: completion)
    }

    @objc func songpad_dismissVC(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard let anchor = self.viewController else {
            songpad_dismissVC(animated: flag, completion: completion)
            return
        }
        var top = anchor
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        if top !== anchor {
            top.dismiss(animated: flag, completion: completion)
        } else {
            songpad_dismissVC(animated: flag, completion: completion)
        }
    }
}

class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        CapacitorBridge.swizzlePresentVC()
        // native Liquid Glass bars over the page (see GlassBarPlugin)
        bridge?.registerPluginInstance(GlassBarPlugin())
        guard let webView = bridge?.webView else { return }
        // Match the launch screen's system background (white / black) until the page paints its
        // own, so dark mode doesn't flash white between the splash and the app.
        view.backgroundColor = .systemBackground
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
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

// MARK: - Liquid Glass bars
// The song list's search bar and New button, the Ideas bar, and the editor's top toolbar are drawn
// natively on iOS 26, so they get Apple's real Liquid Glass (refraction, the shimmer under a finger)
// instead of the CSS imitation. The page still lays the bars out: every frame it sends where each one
// sits and whether anything (a sheet, the sidebar, the splash) covers it, and these native views follow.
// Taps and typing go back to the page, which runs the same code as tapping its own buttons.
// On iOS 25 and earlier the page keeps its own CSS bars and none of this is used.

final class GlassPassthroughView: UIView {
    // touches that miss a bar fall through to the web view underneath
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }
}

private func glassNum(_ v: JSValue?) -> CGFloat {
    if let n = v as? NSNumber { return CGFloat(truncating: n) }
    if let d = v as? Double { return CGFloat(d) }
    if let i = v as? Int { return CGFloat(i) }
    return 0
}

final class GlassGroupView: UIView, UITextFieldDelegate {
    let effectView = UIVisualEffectView()
    let kind: String
    weak var plugin: GlassBarPlugin?
    private(set) var isBottom = false
    private(set) var shownTarget = false
    private var itemsKey = ""
    private var buttons: [UIButton] = []
    private var onStates: [Bool] = []
    private var slots: [CGRect?] = []
    private(set) var field: UITextField?
    private let searchIcon = UIImageView()
    private(set) var inputId = ""

    init(kind: String, plugin: GlassBarPlugin) {
        self.kind = kind
        self.plugin = plugin
        super.init(frame: .zero)
        var usedGlass = false
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let g = UIGlassEffect()
            g.isInteractive = true
            effectView.effect = g
            usedGlass = true
        }
        #endif
        if !usedGlass {
            effectView.effect = UIBlurEffect(style: .systemChromeMaterial)
            effectView.clipsToBounds = true
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.12
            layer.shadowRadius = 10
            layer.shadowOffset = CGSize(width: 0, height: 2)
        }
        addSubview(effectView)
        alpha = 0
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ s: JSObject) {
        let x = glassNum(s["x"]), y = glassNum(s["y"]), w = glassNum(s["w"]), h = glassNum(s["h"])
        // bounds + center rather than frame, so the keyboard lift (a transform) can stay applied
        bounds = CGRect(x: 0, y: 0, width: w, height: h)
        center = CGPoint(x: x + w / 2, y: y + h / 2)
        isBottom = (s["bottom"] as? Bool) ?? false
        if kind == "search" { configureSearch(s) } else { configureButtons(s) }
        setShown((s["show"] as? Bool) ?? true)
        setNeedsLayout()
    }

    func setShown(_ on: Bool) {
        guard on != shownTarget else { return }
        shownTarget = on
        isUserInteractionEnabled = on
        if !on, let f = field, f.isFirstResponder { f.resignFirstResponder() }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = on ? 1 : 0
        }
    }

    private func configureButtons(_ s: JSObject) {
        let items = ((s["items"] as? JSArray) ?? []).compactMap { $0 as? JSObject }
        let key = items.map { "\(($0["id"] as? String) ?? ""):\(($0["sf"] as? String) ?? "")" }.joined(separator: ",")
        if key != itemsKey {
            itemsKey = key
            buttons.forEach { $0.removeFromSuperview() }
            buttons = []
            onStates = []
            slots = []
            for it in items {
                let id = (it["id"] as? String) ?? ""
                let b = UIButton(type: .system)
                b.addAction(UIAction { [weak self] _ in self?.plugin?.tapped(id) }, for: .touchUpInside)
                effectView.contentView.addSubview(b)
                buttons.append(b)
                onStates.append(false)
                slots.append(nil)
            }
        }
        for (i, it) in items.enumerated() where i < buttons.count {
            let on = (it["on"] as? Bool) ?? false
            onStates[i] = on
            // where the page put this button inside the group, so spacing matches exactly
            let rw = glassNum(it["rw"])
            slots[i] = rw > 0 ? CGRect(x: glassNum(it["rx"]), y: 0, width: rw, height: 0) : nil
            style(buttons[i], sf: (it["sf"] as? String) ?? "circle", label: (it["label"] as? String) ?? "", on: on)
        }
    }

    private func style(_ b: UIButton, sf: String, label: String, on: Bool) {
        var c = UIButton.Configuration.plain()
        let sym = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular, scale: .medium)
        c.image = UIImage(systemName: sf, withConfiguration: sym) ?? UIImage(systemName: "circle", withConfiguration: sym)
        c.baseForegroundColor = .label
        c.cornerStyle = .capsule
        c.contentInsets = .zero
        c.background.backgroundColor = on ? UIColor.label.withAlphaComponent(0.12) : .clear
        b.configuration = c
        b.accessibilityLabel = label
        b.accessibilityTraits = on ? [.button, .selected] : [.button]
    }

    private func configureSearch(_ s: JSObject) {
        if field == nil {
            searchIcon.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
            searchIcon.tintColor = .secondaryLabel
            searchIcon.contentMode = .center
            effectView.contentView.addSubview(searchIcon)
            let f = UITextField()
            f.font = .systemFont(ofSize: 17)
            f.textColor = .label
            f.tintColor = .label
            f.clearButtonMode = .whileEditing
            f.returnKeyType = .search
            f.autocorrectionType = .no
            f.autocapitalizationType = .none
            f.delegate = self
            f.addAction(UIAction { [weak self, weak f] _ in
                guard let self = self, let f = f else { return }
                self.plugin?.typed(self.inputId, f.text ?? "")
            }, for: .editingChanged)
            f.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                self.plugin?.focusChanged(self.inputId, focused: true)
            }, for: .editingDidBegin)
            f.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                self.plugin?.focusChanged(self.inputId, focused: false)
            }, for: .editingDidEnd)
            effectView.contentView.addSubview(f)
            field = f
        }
        inputId = (s["input"] as? String) ?? ""
        let ph = (s["ph"] as? String) ?? "Search"
        if field?.attributedPlaceholder?.string != ph {
            field?.attributedPlaceholder = NSAttributedString(string: ph, attributes: [.foregroundColor: UIColor.secondaryLabel])
            field?.accessibilityLabel = ph
        }
        // the page can clear the search (opening a song does); never overwrite what's being typed
        if let f = field, !f.isFirstResponder, let t = s["text"] as? String, f.text != t { f.text = t }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
        let r = min(bounds.width, bounds.height) / 2
        // glass ignores layer.cornerRadius on iOS 26; it takes a corner configuration instead
        var rounded = false
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { effectView.cornerConfiguration = .capsule(); rounded = true }
        #endif
        if !rounded {
            effectView.layer.cornerRadius = r
            effectView.layer.cornerCurve = .continuous
        }
        if layer.shadowOpacity > 0 { layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: r).cgPath }
        if kind == "search" {
            searchIcon.frame = CGRect(x: 14, y: 0, width: 22, height: bounds.height)
            field?.frame = CGRect(x: 42, y: 0, width: max(0, bounds.width - 52), height: bounds.height)
        } else if !buttons.isEmpty {
            let w = bounds.width / CGFloat(buttons.count)
            for (i, b) in buttons.enumerated() {
                var slot = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
                if let s = slots[i] { slot = CGRect(x: s.minX, y: 0, width: s.width, height: bounds.height) }
                b.frame = slot
                // a toggled-on button gets a soft circle centred behind its icon; the button itself never moves
                if var c = b.configuration {
                    let d = max(0, min(slot.width, slot.height) - 6)
                    let ix = (slot.width - d) / 2, iy = (slot.height - d) / 2
                    c.background.backgroundInsets = NSDirectionalEdgeInsets(top: iy, leading: ix, bottom: iy, trailing: ix)
                    b.configuration = c
                }
            }
        }
    }
}

@objc(GlassBarPlugin)
public class GlassBarPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "GlassBarPlugin"
    public let jsName = "GlassBar"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "available", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sync", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "focus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "blur", returnType: CAPPluginReturnPromise)
    ]
    private var overlay: GlassPassthroughView?
    private var groups: [String: GlassGroupView] = [:]
    private var kbTop = CGFloat.greatestFiniteMagnitude
    private var kbDuration = 0.25

    override public func load() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc func available(_ call: CAPPluginCall) {
        var glass = false
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { glass = true }
        #endif
        call.resolve(["glass": glass])
    }

    private func ensureOverlay() -> GlassPassthroughView? {
        if let o = overlay, o.superview != nil { return o }
        guard let web = bridge?.webView else { return nil }
        // a sibling of the web view's scroll view, so it sits above the page and never scrolls with it
        let o = GlassPassthroughView(frame: web.bounds)
        o.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        o.backgroundColor = .clear
        web.addSubview(o)
        overlay = o
        return o
    }

    @objc func sync(_ call: CAPPluginCall) {
        let specs = (call.getArray("groups") ?? []).compactMap { $0 as? JSObject }
        let theme = call.getString("theme") ?? ""
        DispatchQueue.main.async {
            guard let o = self.ensureOverlay() else { call.resolve(); return }
            o.overrideUserInterfaceStyle = theme == "dark" ? .dark : (theme == "light" ? .light : .unspecified)
            var seen = Set<String>()
            for s in specs {
                guard let id = s["id"] as? String else { continue }
                seen.insert(id)
                let g: GlassGroupView
                if let existing = self.groups[id] {
                    g = existing
                } else {
                    g = GlassGroupView(kind: (s["kind"] as? String) ?? "buttons", plugin: self)
                    o.addSubview(g)
                    self.groups[id] = g
                }
                g.apply(s)
            }
            for (id, g) in self.groups where !seen.contains(id) { g.setShown(false) }
            self.applyKeyboardLift(animated: false)
            call.resolve()
        }
    }

    @objc func focus(_ call: CAPPluginCall) {
        let id = call.getString("id") ?? ""
        DispatchQueue.main.async {
            self.groups.values.first { $0.inputId == id && $0.shownTarget }?.field?.becomeFirstResponder()
            call.resolve()
        }
    }

    @objc func blur(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.overlay?.endEditing(true)
            call.resolve()
        }
    }

    func tapped(_ id: String) { notifyListeners("tap", data: ["id": id]) }
    func typed(_ id: String, _ text: String) { notifyListeners("input", data: ["id": id, "text": text]) }
    func focusChanged(_ id: String, focused: Bool) {
        notifyListeners(focused ? "focus" : "blur", data: ["id": id])
        applyKeyboardLift(animated: true)
    }

    // while a native search field is typing, the bottom bar rides up on top of the keyboard
    @objc private func keyboardChange(_ n: Notification) {
        guard let o = overlay, let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let r = o.convert(end, from: nil)
        kbTop = r.minY >= o.bounds.height - 1 ? .greatestFiniteMagnitude : r.minY
        kbDuration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        applyKeyboardLift(animated: true)
    }

    @objc private func keyboardHide(_ n: Notification) {
        kbTop = .greatestFiniteMagnitude
        kbDuration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        applyKeyboardLift(animated: true)
    }

    private func applyKeyboardLift(animated: Bool) {
        let typing = groups.values.contains { $0.field?.isFirstResponder == true }
        let bottoms = groups.values.filter { $0.isBottom }
        var dy: CGFloat = 0
        if typing && kbTop < .greatestFiniteMagnitude {
            let maxY = bottoms.filter { $0.shownTarget }.map { $0.center.y + $0.bounds.height / 2 }.max() ?? 0
            dy = min(0, kbTop - 10 - maxY)
        }
        let t = CGAffineTransform(translationX: 0, y: dy)
        let work = { bottoms.forEach { $0.transform = t } }
        if animated {
            UIView.animate(withDuration: kbDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: work)
        } else {
            work()
        }
    }
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

    // push notifications (@capacitor/push-notifications): hand Apple's device token, or the reason there isn't one, to the app
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
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
            _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, open: urlContext.url, options: [:])
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
        _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, open: url, options: [:])
    }

}
