import SwiftUI
import AuthenticationServices

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        ZStack {
            switch session.phase {
            case .launching:
                LaunchView()
            case .signedOut:
                SignInView().transition(.opacity)
            case .waitlist(let status):
                WaitlistView(status: status).transition(.opacity)
            case .ready:
                SongListScreen().transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: session.phase)
        .overlay(alignment: .bottom) { ToastView() }
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
        .onAppear { AppToast.session = session }
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

/// The record-label disc from the app icon.
struct AppMark: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: 0xFFC2DA), Color(hex: 0xB9A6FF)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(RadialGradient(colors: [Color(hex: 0xFFD6A5), .clear], center: UnitPoint(x: 0.72, y: 0.28), startRadius: 0, endRadius: size * 0.6))
            ProMark(size: size * 0.32)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: 0x9678DC).opacity(0.3), radius: 18, y: 8)
    }
}

struct SignInView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppMark(size: 104).padding(.bottom, 28)
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

                Button {
                    Haptics.tap()
                    Task { await session.signInWithGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        Text("G").font(.system(size: 19, weight: .bold)).foregroundStyle(LinearGradient(colors: [.blue, .red, .yellow, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text("Sign in with Google").font(.system(size: 19, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.primary)
                .disabled(session.busy)

                Text("By continuing, you agree to the [Terms](https://hellodemo.app/terms.html) and [Privacy Policy](https://hellodemo.app/privacy.html).")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .overlay { if session.busy { ProgressView().controlSize(.large) } }
    }
}

struct WaitlistView: View {
    @Environment(AppSession.self) private var session
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
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library

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
        .padding(.bottom, 96)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: text)
        .allowsHitTesting(false)
    }
}
