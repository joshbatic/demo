import SwiftUI
import AuthenticationServices

struct RootView: View {
    @Environment(\.appSession) private var session

    var body: some View {
        ZStack {
            switch session.phase {
            case .launching:
                Color(uiColor: .systemBackground).ignoresSafeArea()
            case .signedOut:
                SignInView().transition(.opacity)
            case .waitlist(let status):
                WaitlistView(status: status).transition(.opacity)
            case .ready:
                SongListScreen().transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: session.phase)
        // the launch screen's record label spins up, then lifts away into the app (spec §1.1)
        .overlay { SplashView(ready: session.phase != .launching) }
        // toasts, banners, the AI prompt and the paywall live in a window above everything (sheets too)
        .onAppear { AppToast.session = session; Push.shared.session = session; HUD.install(session: session); RemoteConfig.shared.start(); MacWindow.setUp() }
    }
}

/// The splash: the launch screen's record label in the same place, so the hand-over can't be seen. Once the app
/// is ready (+120 ms, at most 3 s) the label spins up like a record (0→300° easing to 360°, a slight dip in
/// size), a light tap, then it lifts away (scale 1.18, fading) as the background fades. Reduce Motion: a fade.
struct SplashView: View {
    let ready: Bool
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var gone = false
    @State private var started = false
    @State private var angle = 0.0
    @State private var scale = 1.0
    @State private var markOpacity = 1.0
    @State private var bgOpacity = 1.0

    var body: some View {
        if !gone {
            ZStack {
                Color("LaunchBackground").opacity(bgOpacity).ignoresSafeArea()
                Image("LaunchMark")
                    .resizable().frame(width: 132, height: 132)
                    .rotationEffect(.degrees(angle))
                    .scaleEffect(scale)
                    .opacity(markOpacity)
                    .accessibilityHidden(true)
            }
            .allowsHitTesting(bgOpacity > 0.5)
            .task(id: ready) {
                if ready { try? await Task.sleep(for: .milliseconds(120)); await run() }
            }
            .task {
                try? await Task.sleep(for: .seconds(3))
                await run()
            }
        }
    }

    private func run() async {
        guard !started else { return }
        started = true
        if !calm {
            withAnimation(.timingCurve(0.5, 0, 0.25, 1, duration: 0.85)) { angle = 360 }
            withAnimation(.easeInOut(duration: 0.595)) { scale = 0.96 }
            try? await Task.sleep(for: .milliseconds(595))
            withAnimation(.easeOut(duration: 0.255)) { scale = 1 }
            try? await Task.sleep(for: .milliseconds(255))
            Haptics.tap()
        }
        withAnimation(.easeIn(duration: 0.26)) { scale = calm ? 1 : 1.18; markOpacity = 0 }
        withAnimation(.easeOut(duration: 0.32).delay(0.06)) { bgOpacity = 0 }
        try? await Task.sleep(for: .milliseconds(400))
        gone = true
    }
}

/// While the stored session is checked: the app's mark on the system background, like the launch screen.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            AppMark(size: 132)
        }
    }
}

/// On the Mac (Catalyst): a phone-to-tablet-sized window with a clean, title-less top, so the app's own
/// glass bars sit at the top like on iPhone.
@MainActor
enum MacWindow {
    static func setUp() {
        #if targetEnvironment(macCatalyst)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 420, height: 640)
            scene.sizeRestrictions?.maximumSize = CGSize(width: 1100, height: 4000)
            if let bar = scene.titlebar {
                bar.titleVisibility = .hidden
                bar.toolbar = nil
            }
        }
        #endif
    }
}

/// The record label from the app icon (the round part), from the real artwork.
struct AppMark: View {
    var size: CGFloat
    var body: some View {
        Image("LaunchMark").resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The whole app icon, with the iOS icon shape.
struct AppIconView: View {
    var size: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        Image("AppIconImage").resizable().interpolation(.high).scaledToFill()
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: size * 0.08, y: size * 0.04)
            .accessibilityHidden(true)
    }
}

/// Pro, shown the way people know it: a blue verified tick.
struct VerifiedBadge: View {
    var size: CGFloat = 18
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Theme.verified)
            .accessibilityLabel("Pro")
    }
}

struct SignInView: View {
    @Environment(\.appSession) private var session
    @Environment(\.colorScheme) private var scheme
    @State private var demo = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppIconView(size: 104).padding(.bottom, 28)
            Text("*[demo]").font(.system(size: 40, weight: .bold)).tracking(-0.8)
            Text("Sign in to use *[demo]. Your songs sync to your account and stay backed up.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 36).padding(.top, 10)
            Spacer()
            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { req in
                    session.prepareApple(req)
                } onCompletion: { result in
                    Task { await session.finishApple(result) }
                }
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(Capsule())
                .disabled(session.busy)

                Text("By continuing, you agree to the [Terms](https://hellodemo.app/terms.html) and [Privacy Policy](https://hellodemo.app/privacy.html).")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6)
                // for App Review (and anyone given a demo login)
                Button("Have a demo account?") { demo = true }
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .overlay { if session.busy { ProgressView().controlSize(.large) } }
        .sheet(isPresented: $demo) { DemoSignInSheet() }
    }
}

/// Email and password for a demo account (the App Review login).
struct DemoSignInSheet: View {
    @Environment(\.appSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focus: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: 0).submitLabel(.next).onSubmit { focus = 1 }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: 1).submitLabel(.go).onSubmit { go() }
                } footer: {
                    Text(error ?? "For demo accounts we’ve given you. Everyone else signs in with Apple.")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Demo Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(session.busy ? "Signing In…" : "Sign In") { go() }
                        .fontWeight(.semibold)
                        .disabled(session.busy || email.isEmpty || password.isEmpty)
                }
            }
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = 0 } }
        }
        .presentationDetents([.medium])
    }

    private func go() {
        Task {
            error = await session.signInWithPassword(email: email, password: password)
            if error == nil { dismiss() } else { Haptics.warning() }
        }
    }
}

struct WaitlistView: View {
    @Environment(\.appSession) private var session
    let status: String
    @State private var code = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        AppMark(size: 72)
                        Text(status == "pending" ? "You’re on the list" : status == "declined" ? "Not this round" : "*[demo] is in beta")
                            .font(.title2.bold())
                        Text(status == "pending" ? "We’ll email you when your spot opens. Got an invite code? Enter it below."
                             : "Request access, or enter an invite code if you have one.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }
                Section("Invite code") {
                    TextField("XXXX-XXXX", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button("Redeem Code") { Task { _ = await session.redeem(code: code) } }
                        .disabled(code.filter { $0.isLetter || $0.isNumber }.count < 6)
                }
                if status == "none" {
                    Section {
                        Button("Request Access") {
                            var c = URLComponents(string: "https://hellodemo.app/beta.html")!
                            if !session.email.hasSuffix("privaterelay.appleid.com") { c.queryItems = [URLQueryItem(name: "email", value: session.email)] }
                            if let u = c.url { openURL(u) }
                        }
                    }
                }
                Section {
                    Button("Check Again") { Task { await session.recheckBeta() } }
                    Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
                }
            }
            .navigationTitle("Beta Access")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// A short message at the bottom, like the web's toast.
struct ToastView: View {
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @State private var bottomY: CGFloat = 0

    var body: some View {
        let text = session.toast ?? library.notice
        VStack {
            if let text {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .glassCapsule()
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(3.2))
                        withAnimation(.smooth) { session.toast = nil; library.notice = nil }
                    }
            }
        }
        // above the song screen's rhyme bar (or keyboard + bar) when there is one, else the usual spot
        .padding(.bottom, lift)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottomY = $0 }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: text)
        .animation(.snappy, value: lift)
        .allowsHitTesting(false)
    }

    private var lift: CGFloat {
        guard let top = session.toastAvoidTop, bottomY > 0 else { return 96 }
        return max(96, bottomY - top + 10)
    }
}
