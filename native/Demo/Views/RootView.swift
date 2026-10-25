import SwiftUI
import AuthenticationServices

struct RootView: View {
    @Environment(\.appSession) private var session
    @AppStorage(Onboarding.doneKey) private var onboarded = false

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
                if onboarded { SongListScreen().transition(.opacity) }
                else { OnboardingView { withAnimation(.smooth(duration: 0.4)) { onboarded = true } }.transition(.opacity) }
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


// MARK: - onboarding

enum Onboarding {
    /// Set once this device has been through onboarding (a fresh install shows it once, after signing in).
    static let doneKey = "songpad:onboarded"
}

/// A short first-run: three things *[demo] does, your name and username (co-writers find you by it), and
/// notifications. Every step can be skipped; it's shown once per install.
struct OnboardingView: View {
    var done: () -> Void
    @Environment(\.appSession) private var session
    @State private var step = 0
    @State private var name = ""
    @State private var username = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var field: Int?

    private let pages = 6

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if step < pages - 1 {
                    Button("Skip") { finish() }.font(.system(size: 17)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 44).padding(.horizontal, 20)

            TabView(selection: $step) {
                feature(art: AnyView(AppMark(size: 120).shadow(color: .black.opacity(0.12), radius: 16, y: 8)),
                        title: "Write it down.",
                        text: "Lyrics, ideas and demos together, one song at a time.").tag(0)
                feature(art: AnyView(RhymeArt()), title: "Rhymes as you type.",
                        text: "Rhymes, synonyms and phrases for the word you’re on, right above the keyboard.").tag(1)
                feature(art: AnyView(MemoArt()), title: "Catch it before it’s gone.",
                        text: "Jot a line or hum a melody in Ideas, then turn it into a song.").tag(2)
                feature(art: AnyView(ShareArt()), title: "Hear it with the words.",
                        text: "Add your demo and the lyrics light up in time. Send it with a link anyone can open. Try it free with Pro.").tag(3)
                profile.tag(4)
                notifications.tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: step)

            HStack(spacing: 7) {
                ForEach(0..<pages, id: \.self) { i in
                    Capsule().fill(i == step ? Color.primary : Color.primary.opacity(0.18))
                        .frame(width: i == step ? 18 : 7, height: 7)
                }
            }
            .animation(.snappy, value: step)
            .padding(.bottom, 22)
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                Button { primary() } label: {
                    Text(primaryTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.onTint)
                        .frame(maxWidth: .infinity, minHeight: 52).background(Theme.tint, in: Capsule())
                }
                .buttonStyle(PressScale())
                .disabled(saving)
                Button(secondaryTitle ?? " ") { secondary() }
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                    .frame(height: 30)
                    .opacity(secondaryTitle == nil ? 0 : 1).disabled(secondaryTitle == nil)
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .onAppear { prefill() }
        .onChange(of: session.profile) { _, _ in prefill() }
        .onChange(of: step) { _, s in field = s == 4 ? 0 : nil; error = nil }
    }

    private var primaryTitle: String {
        switch step {
        case 4: return saving ? "Saving…" : "Continue"
        case 5: return "Turn On Notifications"
        default: return "Continue"
        }
    }
    private var secondaryTitle: String? { step == 4 ? "Later" : step == 5 ? "Not Now" : nil }

    private func primary() {
        Haptics.tap()
        switch step {
        case 4: saveProfile()
        case 5: Task { await Push.shared.ask(); finish() }
        default: withAnimation(.snappy) { step += 1 }
        }
    }
    private func secondary() {
        if step == 4 { field = nil; withAnimation(.snappy) { step = 5 } } else { finish() }
    }
    private func finish() { field = nil; Haptics.success(); done() }

    // MARK: pages

    private func feature(art: AnyView, title: String, text: String) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)
            art.frame(height: 230)
            Spacer(minLength: 24)
            Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.4).multilineTextAlignment(.center)
            Text(text).font(.system(size: 17)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 32)
    }

    private var profile: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)
            Avatar(url: session.profile.avatar_url, name: name.isEmpty ? session.myName : name, size: 88)
            Text("What should co-writers call you?").font(.system(size: 26, weight: .bold)).tracking(-0.3)
                .multilineTextAlignment(.center).padding(.top, 22)
            Text("Your name goes on your songs. Co-writers find you by your username.")
                .font(.system(size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 8)
            VStack(spacing: 0) {
                TextField("Name", text: $name)
                    .textContentType(.name).submitLabel(.next).focused($field, equals: 0)
                    .onSubmit { field = 1 }
                    .padding(.horizontal, 16).frame(height: 50)
                Divider().padding(.leading, 16)
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done).focused($field, equals: 1)
                        .onSubmit { saveProfile() }
                }
                .padding(.horizontal, 16).frame(height: 50)
            }
            .font(.system(size: 17))
            .background(BarFill.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 24)
            Text(error ?? "3–20 letters, numbers or underscores. You can change both in Account.")
                .font(.footnote).foregroundStyle(error == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.center).padding(.top, 10)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 28)
    }

    private var notifications: some View {
        feature(art: AnyView(BellArt()), title: "Know when it matters.",
                text: "We’ll let you know when someone invites you to a song or edits one you share. Nothing else unless you turn it on.")
    }

    private func prefill() {
        if name.isEmpty { name = session.profile.display_name ?? session.metaName }
        if username.isEmpty, let u = session.profile.username { username = u }
    }

    private func saveProfile() {
        field = nil
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), u = username.trimmingCharacters(in: .whitespaces)
        if n.isEmpty && u.isEmpty { withAnimation(.snappy) { step = 5 }; return }
        saving = true
        Task {
            let e = await session.saveNameAndUsername(name: n, username: u)
            saving = false
            if let e { error = e; Haptics.warning(); field = 1 } else { withAnimation(.snappy) { step = 5 } }
        }
    }
}

/// A lyric line with its rhymes on chips, like the rhyme bar.
private struct RhymeArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            (Text("Leave the porch light on ") + Text("tonight").foregroundStyle(Theme.verified))
                .font(.system(size: 21, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(["light", "right", "goodnight", "alright"], id: \.self) { w in
                    Text(w).font(.system(size: 15, weight: .medium)).padding(.horizontal, 12).frame(height: 32)
                        .background(BarFill.color, in: Capsule())
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(20)
        .frame(maxWidth: 330, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// An idea with a voice memo.
private struct MemoArt: View {
    private let bars: [CGFloat] = [8, 14, 22, 30, 18, 26, 36, 24, 16, 28, 34, 20, 12, 24, 30, 18, 10, 20, 26, 14, 8, 16, 22, 12]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("hum this over the bridge?").font(.system(size: 19, weight: .medium))
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.onTint)
                    .frame(width: 34, height: 34).background(Theme.tint, in: Circle())
                HStack(alignment: .center, spacing: 3) {
                    ForEach(bars.indices, id: \.self) { i in
                        Capsule().fill(Color.primary.opacity(i < 9 ? 0.9 : 0.25)).frame(width: 3.5, height: bars[i])
                    }
                }
                Text("0:12").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Today").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: 330, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A notification, as it would arrive.
private struct BellArt: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("*[demo]").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("now").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Text("Sam invited you").font(.system(size: 15, weight: .semibold))
                Text("to write “Porch Light” together").font(.system(size: 15)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: 340)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A share page in miniature: the song's colours, its player, and the sung line lit.
private struct ShareArt: View {
    private let lines = ["I left the porch light on", "in case you found your way", "back down the gravel road", "before the break of day"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xFF9F6E), Color(hex: 0xB07CFF)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Porch Light").font(.system(size: 15, weight: .semibold))
                    Text("0:41 / 2:58").font(.system(size: 12).monospacedDigit()).foregroundStyle(.black.opacity(0.55))
                }
                Spacer()
                Image(systemName: "pause.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Color(hex: 0x2B2140), in: Circle())
            }
            .padding(10)
            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).font(.system(size: i == 1 ? 21 : 19, weight: .bold))
                        .foregroundStyle(Color(hex: 0x2B2140).opacity(i == 1 ? 1 : i == 0 ? 0.45 : 0.3))
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(maxWidth: 330, alignment: .leading)
        .background(LinearGradient(colors: [Color(hex: 0xFFD3BE), Color(hex: 0xE3CCFF), Color(hex: 0xBFDDFF)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }
}
