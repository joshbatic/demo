import Foundation
import SwiftUI
import StoreKit
#if canImport(RevenueCat)
import RevenueCat
#endif

/// Plans, Pro gates and upsell copy (spec §7, data spec §6).
enum Pro {
    static let freeMemos = 10
    static let freeMemoSeconds = 60
    static let priceMonth = "A$8.99", priceYear = "A$69.99", trialDays = 7

    /// FEAT: what each upsell key is called.
    static let feat: [String: String] = [
        "lines": "Lines", "rate": "Rate", "perform": "Perform mode", "voice": "Writing voice",
        "listen": "Listening to the whole song", "melody": "Melody", "share": "Inviting co-writers", "muse": "Muse",
        "audio": "Adding music and files", "sync": "Lyric sync", "play": "Play with Lyrics", "release": "Release details",
        "memos": "More voice memos", "ai": "More AI"
    ]

    /// upsellMsg(k)
    static func message(_ k: String) -> String {
        switch k {
        case "memos": return "Free keeps \(freeMemos) voice memos on this device, up to a minute each. Pro syncs them everywhere, with no limit."
        case "ai": return "You’ve used today’s free AI. Pro has plenty more."
        default: return (feat[k] ?? "That") + " is part of *[demo] Pro."
        }
    }

    /// The Pro banner's one line: what it is, plainly. (The paywall keeps the longer `message`.)
    static func short(_ k: String) -> String {
        switch k {
        case "memos": return "Synced voice memos come with Pro."
        case "ai": return "That’s today’s free AI. Pro has more."
        default:
            let f = feat[k] ?? "That"
            return f + (f.hasSuffix("details") ? " come" : " comes") + " with Pro."
        }
    }

    struct Feature: Identifiable { let id: Int; let icon: String; let color: Color; let title: String; let sub: String }

    /// PRO_FEAT: the paywall's list, and the plan page's "Included".
    static let features: [Feature] = [
        Feature(id: 0, icon: "waveform", color: Color(hex: 0xFF2D55), title: "Demos, mixes and stems", sub: "Keep every take with its song. 5 GB of space."),
        Feature(id: 1, icon: "mic.fill", color: Color(hex: 0xFF9500), title: "Voice memos everywhere", sub: "Synced to all your devices, with no limit."),
        Feature(id: 2, icon: "music.note.list", color: Color(hex: 0xAF52DE), title: "Lyric sync", sub: "Play your demo with the words lighting up in time."),
        Feature(id: 3, icon: "person.2.fill", color: Color(hex: 0x007AFF), title: "Co-writing", sub: "Invite co-writers and finish the song together."),
        Feature(id: 4, icon: "link", color: Color(hex: 0x30B0C7), title: "Share links", sub: "Send a song, with its audio, to anyone."),
        Feature(id: 5, icon: "sparkles", color: Color(hex: 0x5856D6), title: "Lines, Rate and your voice", sub: "Suggestions that sound like you, and honest notes on a draft."),
        Feature(id: 6, icon: "music.mic", color: Color(hex: 0x34C759), title: "Perform mode", sub: "Big, clear lyrics for the stage, plus whole-song listening and release details.")
    ]
}

/// In-app subscriptions through RevenueCat (spec §2.9, data spec §6.3). This only buys and restores: the server
/// decides the plan (the `revenuecat` function asks RevenueCat and writes `plans`), so Pro follows the account.
/// Without the RevenueCat package or its key the paywall says subscriptions open soon, like the web build.
@MainActor @Observable
final class Store {
    static let shared = Store()

    var monthPrice: String?
    var yearPrice: String?
    /// Whether this Apple ID can still get the free trial (Apple only gives it once per subscription group).
    var trialEligible = true
    /// What went wrong, shown on the paywall itself (the app's toasts sit underneath it).
    var note: String?
    /// "buy" or "restore" while one is running
    var busy: String?
    @ObservationIgnored private var user: String?
    @ObservationIgnored private var lastServerSync = Date.distantPast

    /// Whether purchases can happen in this build.
    var available: Bool {
        #if canImport(RevenueCat)
        return !Config.revenueCatKey.isEmpty
        #else
        return false
        #endif
    }

    func price(year: Bool) -> String { (year ? yearPrice : monthPrice) ?? (year ? Pro.priceYear : Pro.priceMonth) }

    /// iapStart: configure (or switch user), load prices, and fix a subscription the server missed.
    func start(session: AppSession) async {
        #if canImport(RevenueCat)
        guard available, let uid = session.userID else { return }
        do {
            #if DEBUG
            Purchases.logLevel = .debug
            #endif
            if !Purchases.isConfigured {
                Purchases.configure(withAPIKey: Config.revenueCatKey, appUserID: uid)
            } else if user != uid {
                _ = try await Purchases.shared.logIn(uid)
            }
            user = uid
            let o = try await Purchases.shared.offerings()
            monthPrice = Self.pkg(o.current, year: false)?.storeProduct.localizedPriceString
            yearPrice = Self.pkg(o.current, year: true)?.storeProduct.localizedPriceString
            let ids = [Self.pkg(o.current, year: false), Self.pkg(o.current, year: true)].compactMap { $0?.storeProduct.productIdentifier }
            if !ids.isEmpty {
                let el = await Purchases.shared.checkTrialOrIntroDiscountEligibility(productIdentifiers: ids)
                trialEligible = el.values.contains { $0.status == .eligible }
            }
            let ci = try await Purchases.shared.customerInfo()
            if ci.entitlements.active[Config.proEntitlement] != nil && !session.plan.isPro { await sync(ci: true, session: session) }
            if o.current == nil { note = "The App Store didn’t send the subscriptions (no current offering in RevenueCat)." }
            else if Self.pkg(o.current, year: false) == nil || Self.pkg(o.current, year: true) == nil {
                let got = o.current?.availablePackages.map { $0.identifier + " (" + $0.storeProduct.productIdentifier + ")" }.joined(separator: ", ") ?? ""
                note = "The offering is missing a " + (Self.pkg(o.current, year: false) == nil ? "monthly" : "yearly") + " plan. It has: " + (got.isEmpty ? "nothing" : got) + "."
            }
        } catch {
            note = "Couldn’t load the subscriptions: " + error.localizedDescription
        }
        #endif
    }

    #if canImport(RevenueCat)
    /// The monthly or yearly package: RevenueCat's standard one, else any package whose product renews monthly or
    /// yearly (a package saved with a custom identifier), else one whose product ID says so.
    static func pkg(_ o: Offering?, year: Bool) -> Package? {
        guard let o else { return nil }
        if let p = year ? o.annual : o.monthly { return p }
        if let p = o.availablePackages.first(where: {
            guard let per = $0.storeProduct.subscriptionPeriod, per.value == 1 else { return false }
            return year ? per.unit == .year : per.unit == .month
        }) { return p }
        return o.availablePackages.first { $0.storeProduct.productIdentifier.hasSuffix(year ? "yearly" : "monthly") }
    }
    #endif

    func buy(year: Bool, session: AppSession) async {
        note = nil
        guard session.userID != nil else { note = "Sign in first, so Pro is saved to your account."; return }
        #if canImport(RevenueCat)
        guard available else { note = "Subscriptions open soon. You’ll start your \(Pro.trialDays)-day free trial right here."; return }
        busy = "buy"; defer { busy = nil }
        if !Purchases.isConfigured { await start(session: session) }
        guard Purchases.isConfigured else { note = note ?? "Subscriptions couldn’t start. Try again in a moment."; return }
        do {
            let o = try await Purchases.shared.offerings()
            guard let pkg = Self.pkg(o.current, year: year) else {
                note = o.current == nil
                    ? "The App Store didn’t send the subscriptions yet. Check the products in App Store Connect and the current offering in RevenueCat."
                    : "No \(year ? "yearly" : "monthly") plan in the current offering. It has: " + (o.current?.availablePackages.map { $0.identifier + " (" + $0.storeProduct.productIdentifier + ")" }.joined(separator: ", ") ?? "nothing") + "."
                return
            }
            let r = try await Purchases.shared.purchase(package: pkg)
            if r.userCancelled { return }
            if r.customerInfo.entitlements.active[Config.proEntitlement] != nil {
                await sync(ci: true, session: session)
                Haptics.success()
                session.toast = session.plan.isPro ? "Welcome to *[demo] Pro" : "Purchase received. Pro switches on in a moment."
            }
        } catch {
            if let e = error as? ErrorCode, e == .purchaseCancelledError { return }
            note = "The purchase didn’t go through. " + error.localizedDescription
        }
        #else
        session.toast = "Subscriptions open soon. You’ll start your \(Pro.trialDays)-day free trial right here."
        #endif
    }

    func restore(session: AppSession) async {
        guard session.userID != nil else { session.toast = "Sign in first, so Pro is saved to your account."; return }
        #if canImport(RevenueCat)
        guard available else { session.toast = "Subscriptions open soon. You’ll start your \(Pro.trialDays)-day free trial right here."; return }
        busy = "restore"; defer { busy = nil }
        note = nil
        if !Purchases.isConfigured { await start(session: session) }
        guard Purchases.isConfigured else { note = note ?? "Subscriptions couldn’t start. Try again in a moment."; return }
        do {
            let ci = try await Purchases.shared.restorePurchases()
            if ci.entitlements.active[Config.proEntitlement] != nil {
                await sync(ci: true, session: session)
                Haptics.success(); session.toast = "Pro restored"
            } else {
                note = "No *[demo] Pro subscription found for this Apple ID."
            }
        } catch {
            note = "Couldn’t restore: " + error.localizedDescription
        }
        #else
        session.toast = "Subscriptions open soon. You’ll start your \(Pro.trialDays)-day free trial right here."
        #endif
    }

    /// iapSync: Pro on this device straight away, then the server re-checks (retried once) and the plan refreshes.
    func sync(ci pro: Bool, session: AppSession) async {
        if pro {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "songpad:iap:pro-at")
            if !session.plan.isPro { session.plan.tier = "pro" }
        }
        lastServerSync = Date()
        var ok = (try? await Backend.function("revenuecat", body: ["action": "sync"]))?["ok"]?.bool ?? false
        if !ok {
            try? await Task.sleep(for: .seconds(2.5))
            ok = (try? await Backend.function("revenuecat", body: ["action": "sync"]))?["ok"]?.bool ?? false
        }
        await session.refreshPlan(fromStore: true)
        // the server lags Apple: stay Pro here
        if pro && !session.plan.isPro { session.plan.tier = "pro" }
    }

    /// The server says Free but Apple said Pro on this device in the last day: ask the server again (once a minute at most).
    func recheckIfLagging(session: AppSession) async {
        let at = UserDefaults.standard.double(forKey: "songpad:iap:pro-at")
        guard at > 0, Date().timeIntervalSince1970 - at < 86_400, Date().timeIntervalSince(lastServerSync) > 60 else { return }
        await sync(ci: false, session: session)
    }

    /// Manage Subscription: the system sheet, else the App Store page.
    func manage() async {
        #if !targetEnvironment(macCatalyst)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
           (try? await AppStore.showManageSubscriptions(in: scene)) != nil { return }
        #endif
        if let u = URL(string: "https://apps.apple.com/account/subscriptions") { await UIApplication.shared.open(u) }
    }

    func logOut() {
        #if canImport(RevenueCat)
        if Purchases.isConfigured { Task { _ = try? await Purchases.shared.logOut() } }
        #endif
        user = nil
    }
}
