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

// "rgb(52, 199, 89)" / "rgba(0, 0, 0, 0.08)" from the page's computed styles
private func glassColor(_ v: JSValue?) -> UIColor? {
    guard let str = v as? String, let open = str.firstIndex(of: "("), let close = str.lastIndex(of: ")") else { return nil }
    let parts = str[str.index(after: open)..<close].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
    guard parts.count >= 3 else { return nil }
    return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts.count > 3 ? parts[3] : 1)
}

private func glassRect(_ v: JSValue?) -> CGRect? {
    guard let o = v as? JSObject else { return nil }
    let r = CGRect(x: glassNum(o["x"]), y: glassNum(o["y"]), width: glassNum(o["w"]), height: glassNum(o["h"]))
    return r.width > 0 && r.height > 0 ? r : nil
}

final class GlassGroupView: UIView, UITextFieldDelegate, UITabBarDelegate {
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
    // the Account button: plan tag, photo or person icon, invite dot
    private let tagLabel = UILabel()
    private let avatarView = UIImageView()
    private let iconView = UIImageView()
    private let dotView = UIView()
    private var hitButton: UIButton?
    private var avatarURL = ""
    private var parts: [String: CGRect] = [:]
    static var avatars: [String: UIImage] = [:]
    // pop-up menus on buttons (the editor's •••)
    private var menuKeys: [String] = []
    // mirror: the page's own content (text, chips, icons) redrawn natively on the glass; touches pass through to the page
    private var mirrorViews: [UIView] = []
    private var mirrorKinds: [String] = []
    private var cornerRadiusHint: CGFloat = 0
    // the dev app's tab bar: Apple's own UITabBar
    private var tabBar: UITabBar?
    private var tabIds: [String] = []
    private var tabKey = ""

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
        cornerRadiusHint = glassNum(s["r"])
        if kind == "mirror" {
            configureMirror(s)
            // the page animates these in and out with opacity; follow it exactly, and never take touches
            let show = (s["show"] as? Bool) ?? true
            shownTarget = show
            isUserInteractionEnabled = false
            alpha = show ? (s["op"] != nil ? glassNum(s["op"]) : 1) : 0
            setNeedsLayout()
            return
        }
        if kind == "search" { configureSearch(s) } else if kind == "account" { configureAccount(s) } else if kind == "tabbar" { configureTabBar(s) } else { configureButtons(s) }
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
            menuKeys = []
            for it in items {
                let id = (it["id"] as? String) ?? ""
                let b = UIButton(type: .system)
                b.addAction(UIAction { [weak self] _ in self?.plugin?.tapped(id) }, for: .touchUpInside)
                effectView.contentView.addSubview(b)
                buttons.append(b)
                onStates.append(false)
                slots.append(nil)
                menuKeys.append("")
            }
        }
        for (i, it) in items.enumerated() where i < buttons.count {
            let on = (it["on"] as? Bool) ?? false
            onStates[i] = on
            // where the page put this button inside the group, so spacing matches exactly
            let rw = glassNum(it["rw"])
            slots[i] = rw > 0 ? CGRect(x: glassNum(it["rx"]), y: 0, width: rw, height: 0) : nil
            style(buttons[i], sf: (it["sf"] as? String) ?? "circle", icon: it["ik"] as? String, label: (it["label"] as? String) ?? "", on: on)
            configureMenu(buttons[i], index: i, sections: it["menu"] as? JSArray)
        }
    }

    // a button with a menu shows Apple's pop-up menu on tap instead of acting straight away
    private func configureMenu(_ b: UIButton, index i: Int, sections: JSArray?) {
        guard let sections = sections, !sections.isEmpty else {
            if !menuKeys[i].isEmpty { b.menu = nil; b.showsMenuAsPrimaryAction = false; menuKeys[i] = "" }
            return
        }
        let groups = sections.compactMap { $0 as? JSArray }.map { $0.compactMap { $0 as? JSObject } }
        let key = groups.map { $0.map { "\(($0["id"] as? String) ?? "")|\(($0["title"] as? String) ?? "")|\(($0["sf"] as? String) ?? "")|\(($0["destructive"] as? Bool) == true)" }.joined(separator: ",") }.joined(separator: ";")
        guard key != menuKeys[i] else { return }
        menuKeys[i] = key
        let menus: [UIMenuElement] = groups.map { items in
            UIMenu(title: "", options: .displayInline, children: items.map { m in
                let id = (m["id"] as? String) ?? ""
                let img = (m["sf"] as? String).flatMap { UIImage(systemName: $0) }
                return UIAction(title: (m["title"] as? String) ?? "", image: img, attributes: (m["destructive"] as? Bool) == true ? [.destructive] : []) { [weak self] _ in
                    self?.plugin?.menuPicked(id)
                }
            })
        }
        b.menu = UIMenu(title: "", children: menus)
        b.showsMenuAsPrimaryAction = true
    }

    private func configureTabBar(_ s: JSObject) {
        let tb: UITabBar
        if let existing = tabBar { tb = existing } else {
            tb = UITabBar()
            tb.delegate = self
            tb.tintColor = .label
            effectView.isHidden = true
            addSubview(tb)
            tabBar = tb
        }
        let items = ((s["items"] as? JSArray) ?? []).compactMap { $0 as? JSObject }
        let key = items.map { "\(($0["id"] as? String) ?? ""):\(($0["label"] as? String) ?? ""):\(($0["ik"] as? String) ?? "")" }.joined(separator: ",")
        if key != tabKey {
            tabKey = key
            tabIds = items.map { ($0["id"] as? String) ?? "" }
            tb.items = items.enumerated().map { (i, it) in
                var img: UIImage? = nil
                if let k = it["ik"] as? String { img = GlassBarPlugin.icons[k] }
                if img == nil { img = UIImage(systemName: (it["sf"] as? String) ?? "circle") }
                return UITabBarItem(title: (it["label"] as? String) ?? "", image: img, tag: i)
            }
        }
        for (i, it) in items.enumerated() where i < (tb.items?.count ?? 0) {
            let badge = (it["badge"] as? String) ?? ""
            tb.items?[i].badgeValue = badge.isEmpty ? nil : badge
            if (it["on"] as? Bool) == true, tb.selectedItem !== tb.items?[i] { tb.selectedItem = tb.items?[i] }
        }
        // Apple's tab bar sits along the bottom edge at its own height, whatever size the page's bar was
        if let sv = superview {
            let safe = sv.safeAreaInsets.bottom
            let fit = tb.sizeThatFits(CGSize(width: sv.bounds.width, height: 0)).height
            let h = fit >= 49 + safe ? fit : fit + safe
            bounds = CGRect(x: 0, y: 0, width: sv.bounds.width, height: h)
            center = CGPoint(x: sv.bounds.width / 2, y: sv.bounds.height - h / 2)
        }
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        if item.tag >= 0 && item.tag < tabIds.count { plugin?.tapped(tabIds[item.tag]) }
    }

    private func style(_ b: UIButton, sf: String, icon: String?, label: String, on: Bool) {
        var c = UIButton.Configuration.plain()
        if let k = icon, let img = GlassBarPlugin.icons[k] {
            // the app's own icon (the same SVG the Mac and web use), tinted like a symbol
            c.image = img
        } else {
            let sym = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular, scale: .medium)
            c.image = UIImage(systemName: sf, withConfiguration: sym) ?? UIImage(systemName: "circle", withConfiguration: sym)
        }
        c.baseForegroundColor = .label
        c.cornerStyle = .capsule
        c.contentInsets = .zero
        c.background.backgroundColor = on ? UIColor.label.withAlphaComponent(0.12) : .clear
        b.configuration = c
        b.accessibilityLabel = label
        b.accessibilityTraits = on ? [.button, .selected] : [.button]
    }

    private func configureAccount(_ s: JSObject) {
        if hitButton == nil {
            tagLabel.font = .systemFont(ofSize: 10, weight: .bold)
            tagLabel.textAlignment = .center
            tagLabel.clipsToBounds = true
            avatarView.contentMode = .scaleAspectFill
            avatarView.clipsToBounds = true
            iconView.contentMode = .center
            iconView.tintColor = .label
            dotView.backgroundColor = .systemRed
            dotView.layer.borderColor = UIColor.systemBackground.cgColor
            dotView.layer.borderWidth = 2
            [tagLabel, avatarView, iconView, dotView].forEach {
                $0.isUserInteractionEnabled = false
                effectView.contentView.addSubview($0)
            }
            let b = UIButton(type: .custom)
            let tapId = (s["tap"] as? String) ?? ""
            b.addAction(UIAction { [weak self] _ in self?.plugin?.tapped(tapId) }, for: .touchUpInside)
            effectView.contentView.addSubview(b)
            hitButton = b
        }
        hitButton?.accessibilityLabel = (s["label"] as? String) ?? "Account"
        parts = [:]
        // plan tag ("Beta" / "Pro"), in the page's own colours
        if let t = s["tag"] as? String, !t.isEmpty, let r = glassRect(s["tagRect"]) {
            parts["tag"] = r
            tagLabel.text = t
            tagLabel.textColor = glassColor(s["tagFg"]) ?? .label
            tagLabel.backgroundColor = glassColor(s["tagBg"]) ?? UIColor.label.withAlphaComponent(0.08)
            tagLabel.isHidden = false
        } else { tagLabel.isHidden = true }
        // profile photo, or the person icon when there isn't one
        let url = (s["avatar"] as? String) ?? ""
        if !url.isEmpty, let r = glassRect(s["avatarRect"]) {
            parts["avatar"] = r
            avatarView.isHidden = false
            iconView.isHidden = true
            loadAvatar(url)
        } else {
            avatarView.isHidden = true
            avatarURL = ""
            if let k = s["ik"] as? String, let img = GlassBarPlugin.icons[k], let r = glassRect(s["iconRect"]) {
                parts["icon"] = r
                iconView.image = img
                iconView.isHidden = false
            } else { iconView.isHidden = true }
        }
        if (s["dot"] as? Bool) == true, let r = glassRect(s["dotRect"]) {
            parts["dot"] = r
            dotView.isHidden = false
        } else { dotView.isHidden = true }
    }

    private func configureMirror(_ s: JSObject) {
        let parts = ((s["parts"] as? JSArray) ?? []).compactMap { $0 as? JSObject }
        let kinds = parts.map { ($0["k"] as? String) ?? "t" }
        if kinds != mirrorKinds {
            mirrorViews.forEach { $0.removeFromSuperview() }
            mirrorViews = kinds.map { k in
                let wrap = UIView()
                wrap.clipsToBounds = true
                wrap.isUserInteractionEnabled = false
                let content: UIView
                switch k {
                case "t":
                    let l = UILabel()
                    l.lineBreakMode = .byTruncatingTail
                    content = l
                case "i":
                    let iv = UIImageView()
                    iv.contentMode = .scaleAspectFit
                    content = iv
                case "img":
                    let iv = UIImageView()
                    iv.contentMode = .scaleAspectFill
                    iv.clipsToBounds = true
                    content = iv
                default:
                    content = UIView()
                }
                content.isUserInteractionEnabled = false
                wrap.addSubview(content)
                effectView.contentView.addSubview(wrap)
                return wrap
            }
            mirrorKinds = kinds
        }
        for (i, p) in parts.enumerated() where i < mirrorViews.count {
            let wrap = mirrorViews[i]
            guard let content = wrap.subviews.first else { continue }
            var r = CGRect(x: glassNum(p["x"]), y: glassNum(p["y"]), width: glassNum(p["w"]), height: glassNum(p["h"]))
            let k = kinds[i]
            if k == "t" {
                // the page measures text tightly; give UIKit a little room so it never truncates
                r = r.insetBy(dx: -3, dy: -1)
            }
            let clip = glassRect(p["clip"]) ?? r
            wrap.frame = clip
            content.frame = r.offsetBy(dx: -clip.minX, dy: -clip.minY)
            content.alpha = p["op"] != nil ? glassNum(p["op"]) : 1
            let color = glassColor(p["fc"]) ?? .label
            switch k {
            case "t":
                guard let l = content as? UILabel else { break }
                let fs = max(1, glassNum(p["fs"]))
                let fw = glassNum(p["fw"])
                let weight: UIFont.Weight = fw >= 750 ? .heavy : fw >= 650 ? .bold : fw >= 550 ? .semibold : fw >= 450 ? .medium : .regular
                var font = UIFont.systemFont(ofSize: fs, weight: weight)
                if (p["it"] as? Bool) == true, let d = font.fontDescriptor.withSymbolicTraits(.traitItalic) { font = UIFont(descriptor: d, size: fs) }
                if (p["tab"] as? Bool) == true { font = UIFont.monospacedDigitSystemFont(ofSize: fs, weight: weight) }
                l.font = font
                l.textColor = color
                let multi = (p["ml"] as? Bool) == true
                l.numberOfLines = multi ? 0 : 1
                let al = (p["al"] as? String) ?? ""
                l.textAlignment = !multi ? .center : (al == "center" ? .center : (al == "right" || al == "end") ? .right : .left)
                l.text = (p["tx"] as? String) ?? ""
            case "i":
                guard let iv = content as? UIImageView else { break }
                if let k2 = p["ik"] as? String, let img = GlassBarPlugin.icons[k2] { iv.image = img }
                iv.tintColor = color
            case "img":
                guard let iv = content as? UIImageView else { break }
                iv.layer.cornerRadius = min(glassNum(p["r"]), min(r.width, r.height) / 2)
                GlassGroupView.loadImage((p["src"] as? String) ?? "", into: iv)
            default:
                content.backgroundColor = glassColor(p["bg"]) ?? .clear
                content.layer.cornerRadius = min(glassNum(p["r"]), min(r.width, r.height) / 2)
                content.layer.cornerCurve = .continuous
                content.layer.borderWidth = glassNum(p["bw"])
                content.layer.borderColor = (glassColor(p["bc"]) ?? .clear).cgColor
                // CSS gradients (the Muse button's tint, icon tiles) as a native gradient layer
                let existing = content.layer.sublayers?.first { $0 is CAGradientLayer } as? CAGradientLayer
                if let gr = p["gr"] as? JSObject, let cols = gr["c"] as? JSArray {
                    let gl = existing ?? CAGradientLayer()
                    if existing == nil { content.layer.insertSublayer(gl, at: 0) }
                    gl.frame = content.bounds
                    gl.cornerRadius = content.layer.cornerRadius
                    gl.cornerCurve = .continuous
                    gl.colors = cols.compactMap { glassColor($0)?.cgColor }
                    if (gr["t"] as? String) == "r" {
                        gl.type = .radial
                        gl.startPoint = CGPoint(x: 0.5, y: 0.5)
                        gl.endPoint = CGPoint(x: 1, y: 1)
                    } else {
                        // CSS angles: 0deg points up, 90deg right
                        let a = Double(glassNum(gr["a"])) * .pi / 180
                        let dx = CGFloat(sin(a)) / 2, dy = CGFloat(-cos(a)) / 2
                        gl.type = .axial
                        gl.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
                        gl.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
                    }
                } else {
                    existing?.removeFromSuperlayer()
                }
            }
        }
    }

    static func loadImage(_ url: String, into iv: UIImageView) {
        guard iv.accessibilityIdentifier != url else { return }
        iv.accessibilityIdentifier = url
        if url.isEmpty { iv.image = nil; return }
        if let img = avatars[url] { iv.image = img; return }
        iv.image = nil
        if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
            if let d = Data(base64Encoded: String(url[url.index(after: comma)...])), let img = UIImage(data: d) { avatars[url] = img; iv.image = img }
            return
        }
        guard let u = URL(string: url), u.scheme == "https" else { return }
        URLSession.shared.dataTask(with: u) { [weak iv] data, _, _ in
            guard let data = data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                avatars[url] = img
                if iv?.accessibilityIdentifier == url { iv?.image = img }
            }
        }.resume()
    }

    private func loadAvatar(_ url: String) {
        guard url != avatarURL else { return }
        avatarURL = url
        if let img = GlassGroupView.avatars[url] { avatarView.image = img; return }
        avatarView.image = nil
        if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
            if let d = Data(base64Encoded: String(url[url.index(after: comma)...])), let img = UIImage(data: d) {
                GlassGroupView.avatars[url] = img
                avatarView.image = img
            }
            return
        }
        guard let u = URL(string: url) else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data = data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                GlassGroupView.avatars[url] = img
                if self?.avatarURL == url { self?.avatarView.image = img }
            }
        }.resume()
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
        if #available(iOS 26.0, *) {
            // a capsule, or a rounded rectangle when the page's panel has a smaller radius (the rhyme bar, banners)
            effectView.cornerConfiguration = cornerRadiusHint > 0 && cornerRadiusHint < r ? .capsule(maximumRadius: cornerRadiusHint) : .capsule()
            rounded = true
        }
        #endif
        if !rounded {
            effectView.layer.cornerRadius = cornerRadiusHint > 0 ? min(cornerRadiusHint, r) : r
            effectView.layer.cornerCurve = .continuous
        }
        if layer.shadowOpacity > 0 { layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: r).cgPath }
        if kind == "tabbar" {
            tabBar?.frame = bounds
        } else if kind == "account" {
            hitButton?.frame = bounds
            if let r = parts["tag"] { tagLabel.frame = r; tagLabel.layer.cornerRadius = r.height / 2 }
            if let r = parts["avatar"] { avatarView.frame = r; avatarView.layer.cornerRadius = r.width / 2 }
            if let r = parts["icon"] { iconView.frame = r }
            if let r = parts["dot"] { dotView.frame = r; dotView.layer.cornerRadius = r.width / 2 }
            dotView.layer.borderColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
        } else if kind == "search" {
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
        CAPPluginMethod(name: "blur", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "icon", returnType: CAPPluginReturnPromise)
    ]
    // the page's own button icons, rendered by the page to PNG once and kept here by key
    static var icons: [String: UIImage] = [:]
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

    @objc func icon(_ call: CAPPluginCall) {
        let key = call.getString("key") ?? ""
        let b64 = call.getString("png") ?? ""
        let scale = CGFloat(call.getDouble("scale") ?? 3)
        DispatchQueue.main.async {
            if !key.isEmpty, let data = Data(base64Encoded: b64), let img = UIImage(data: data, scale: scale) {
                GlassBarPlugin.icons[key] = img.withRenderingMode(.alwaysTemplate)
            }
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
    func menuPicked(_ id: String) { notifyListeners("menu", data: ["id": id]) }
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
