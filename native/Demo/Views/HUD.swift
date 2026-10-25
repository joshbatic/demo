import SwiftUI
import UIKit

/// A see-through window above the app for what must show over everything, sheets included: toasts, the Pro
/// banner, the invite banner, the admin banner, the AI consent prompt, the paywall and "Time to update".
/// Touches pass through to the app except on the banners (and while the paywall, prompt or update screen is up).
@MainActor
enum HUD {
    private static var window: PassthroughWindow?

    static func install(session: AppSession) {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = PassthroughWindow(windowScene: scene)
        let host = UIHostingController(rootView: HUDRoot()
            .environment(session).environment(session.library)
            .tint(Theme.tint)
            .toggleStyle(SwitchToggleStyle(tint: Color(uiColor: .systemGreen))))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.windowLevel = .normal + 1
        w.backgroundColor = .clear
        w.isHidden = false
        window = w
    }
}

/// Where the HUD's tappable things are (window coordinates).
@MainActor @Observable
final class HUDHits {
    static let shared = HUDHits()
    var rects: [String: CGRect] = [:]
    /// a screen that takes every touch (Time to update)
    var blocking = false
}

final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // the paywall or a prompt is up: it's a normal window
        if rootViewController?.presentedViewController != nil { return super.hitTest(point, with: event) }
        let take = MainActor.assumeIsolated { HUDHits.shared.blocking || HUDHits.shared.rects.values.contains { $0.contains(point) } }
        return take ? super.hitTest(point, with: event) : nil
    }
}

extension View {
    /// Marks a HUD view as tappable while it's on screen.
    func hudHit(_ key: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { HUDHits.shared.rects[key] = $0 }
            .onDisappear { HUDHits.shared.rects[key] = nil }
    }
}

struct HUDRoot: View {
    @Environment(\.appSession) private var session
    @State private var config = RemoteConfig.shared

    var body: some View {
        ZStack {
            Color.clear
            if config.mustUpdate { UpdateScreen().transition(.opacity) }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                ProBannerView()
                ToastView()
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                RemoteBannerView()
                InviteBanner()
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: Collab.shared.banner)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: config.banner)
        }
        .onChange(of: config.mustUpdate, initial: true) { _, v in HUDHits.shared.blocking = v }
        // the first AI request asks once (App Store guideline 5.1.2(i)); Account › AI Features changes it later
        .alert("Use AI features?", isPresented: Binding(get: { AIService.shared.askingConsent }, set: { _ in })) {
            Button("Not Now", role: .cancel) {
                AIService.shared.answerConsent(false)
                session.toast = "AI features are off. Turn them on any time in Account › AI Features."
            }
            Button("Allow") { AIService.shared.answerConsent(true) }
        } message: {
            Text(AIService.consentMessage + "\n\nNothing is sent unless you allow it. The Privacy Policy is in Account.")
        }
        .fullScreenCover(isPresented: Binding(get: { session.paywallWhy != nil }, set: { if !$0 { session.paywallWhy = nil } })) {
            PaywallView(why: session.paywallWhy ?? "")
                .environment(session)
                .tint(Theme.tint)
        }
        .onAppear { AppToast.session = session }
    }
}

/// The Pro banner (spec §1.7): "*[demo] Pro" + why, tap for the paywall; ✕ dismisses; gone after 6 s.
struct ProBannerView: View {
    @Environment(\.appSession) private var session

    var body: some View {
        Group {
            if let n = session.proNote {
                HStack(spacing: 12) {
                    AppMark(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("*[demo] Pro").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text(n.msg).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.88)).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    Button { withAnimation(.snappy) { session.proNote = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(.white.opacity(0.22), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.tap()
                    let k = n.key
                    withAnimation(.snappy) { session.proNote = nil }
                    session.openAccount(k)
                }
                // a warm orange card that stands out from the app's glass
                .background {
                    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                    shape.fill(LinearGradient(colors: [Color(hex: 0xFFB340), Color(hex: 0xFF8A00), Color(hex: 0xFF5E1A)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 1))
                        .shadow(color: Color(hex: 0xFF6A00).opacity(0.35), radius: 16, y: 8)
                }
                .environment(\.colorScheme, .light)
                .padding(.horizontal, 12)
                .hudHit("pro")
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: n.id) {
                    try? await Task.sleep(for: .seconds(6))
                    if session.proNote?.id == n.id { withAnimation(.snappy) { session.proNote = nil } }
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: session.proNote)
    }
}

/// The admin banner (spec §1.7): slides away after 9 s (20 s for a warning) and returns next launch;
/// tapping it or ✕ dismisses it for good.
struct RemoteBannerView: View {
    @State private var config = RemoteConfig.shared

    var body: some View {
        if let b = config.banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: b.warn ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.system(size: 17)).foregroundStyle(b.warn ? Color.orange : Color.blue)
                Text(b.text).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).padding(.top, 3)
            }
            .padding(14)
            .background(b.warn ? Color.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { Haptics.tap(); withAnimation(.snappy) { config.dismissBanner() } }
            .padding(.horizontal, 12)
            .hudHit("cfg")
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: b.id) {
                try? await Task.sleep(for: .seconds(b.warn ? 20 : 9))
                if config.banner?.id == b.id { withAnimation(.snappy) { config.banner = nil } }
            }
        }
    }
}

/// "Time to update" (spec §1.7): blocks the app when the server needs a newer build.
struct UpdateScreen: View {
    @State private var config = RemoteConfig.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                AppMark(size: 84).padding(.bottom, 6)
                Text("Time to update").font(.system(size: 28, weight: .bold))
                Text(config.updateNote.isEmpty ? "This version of *[demo] is out of date. Update to keep writing. Your songs are safe and will be right here." : config.updateNote)
                    .font(.system(size: 17)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button {
                    openURL(Config.appStoreURL)
                } label: {
                    Text("Get the Update").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.onTint)
                        .frame(maxWidth: .infinity, minHeight: 52).background(Theme.tint, in: Capsule())
                }
                .buttonStyle(PressScale())
                .padding(.top, 10)
                Text("Version \(Config.appVersion) · build \(Config.appSeq)").font(.footnote).foregroundStyle(.tertiary).padding(.top, 8)
            }
            .padding(.horizontal, 32)
        }
    }
}
