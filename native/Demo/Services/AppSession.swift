import Foundation
import SwiftUI
import Observation
import AuthenticationServices
import CryptoKit
import Supabase

/// Who's signed in, their profile, plan and beta access, and the library that goes with them.
@MainActor @Observable
final class AppSession {
    enum Phase: Equatable { case launching, signedOut, waitlist(String), ready }

    var phase: Phase = .launching
    private(set) var userID: String?
    private(set) var email = ""
    private(set) var metaName = ""
    var profile = Profile()
    var plan = Plan()
    /// Where a floating bottom bar starts (global y), so toasts appear above it rather than over it.
    var toastAvoidTop: CGFloat?
    var toast: String?
    var busy = false
    let library = LibraryStore()

    nonisolated struct Profile: Codable, Equatable {
        var username: String? = nil
        var display_name: String? = nil
        var avatar_url: String? = nil
        var link_spotify: String? = nil
        var link_instagram: String? = nil
        var link_tiktok: String? = nil
    }

    struct Plan: Equatable {
        var tier = "free"
        var expiresAt: String?
        var heavyMonth = 0
        var storageLimit: Double?
        var storageUsed: Double = 0
        var isPro: Bool { tier != "free" }       // beta counts as Pro everywhere (spec §6.1)
    }

    /// `myName()`: display name, else username, else the name from the sign-in provider.
    var myName: String {
        for v in [profile.display_name, profile.username, metaName] { if let v, !v.isEmpty { return v } }
        return ""
    }

    private var signedOutFlag: Bool {
        get { UserDefaults.standard.string(forKey: "songpad:signedout") == "1" }
        set { UserDefaults.standard.set(newValue ? "1" : nil, forKey: "songpad:signedout") }
    }

    // MARK: lifecycle

    func start() async {
        for await (event, session) in Backend.client.auth.authStateChanges {
            if let session {
                // a sign-out sticks even if the network call failed (spec §5.1)
                if signedOutFlag && event != .signedIn {
                    try? await Backend.client.auth.signOut(scope: .local)
                    goSignedOut(); continue
                }
                signedOutFlag = false
                await onUser(session.user)
            } else if event == .initialSession || event == .signedOut {
                goSignedOut()
            }
        }
    }

    private func goSignedOut() {
        library.close()
        userID = nil; profile = Profile(); plan = Plan()
        phase = .signedOut
    }

    private func onUser(_ user: User) async {
        let uid = user.id.uuidString.lowercased()
        email = user.email ?? ""
        metaName = (user.userMetadata["full_name"]?.stringValue ?? user.userMetadata["name"]?.stringValue) ?? ""
        let isNew = uid != userID
        userID = uid
        if isNew {
            profile = loadCachedProfile(uid)
            library.open(uid: uid)
            MuseMemory.shared.open(uid: uid, library: library, session: self)
        }
        // the beta gate decides whether the app opens; it fails open if the check itself fails (spec §6.4)
        if UserDefaults.standard.string(forKey: "songpad:beta:\(uid)") == "ok" { phase = .ready }
        let status = (try? await Backend.rpc("beta_status"))?.string ?? "open"
        if ["open", "admin", "approved"].contains(status) {
            UserDefaults.standard.set("ok", forKey: "songpad:beta:\(uid)")
            phase = .ready
        } else {
            phase = .waitlist(status)
        }
        if isNew {
            Task { await loadProfile() }
            Task { await refreshPlan() }
        }
    }

    // MARK: sign in / out

    /// Sign in with Apple: a hashed nonce goes to Apple, the raw one to Supabase (spec §5.3).
    private var appleNonce = ""
    func prepareApple(_ request: ASAuthorizationAppleIDRequest) {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        appleNonce = bytes.map { String(format: "%02x", $0) }.joined()
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(appleNonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func finishApple(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code != .canceled { toast = "Couldn’t sign in with Apple. \(e.localizedDescription)" }
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                toast = "Apple didn’t return a sign-in token. Try again."; return
            }
            busy = true; defer { busy = false }
            do {
                signedOutFlag = false
                let session = try await Backend.client.auth.signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .apple, idToken: token, nonce: appleNonce))
                // Apple only sends the name the first time
                let nm = [cred.fullName?.givenName, cred.fullName?.familyName].compactMap { $0 }.joined(separator: " ")
                if !nm.isEmpty && (session.user.userMetadata["full_name"]?.stringValue ?? "").isEmpty {
                    _ = try? await Backend.client.auth.update(user: UserAttributes(data: ["full_name": .string(nm), "name": .string(nm)]))
                }
            } catch {
                toast = describe(error)
            }
        }
    }

    func signInWithGoogle() async {
        busy = true; defer { busy = false }
        do {
            signedOutFlag = false
            _ = try await Backend.client.auth.signInWithOAuth(provider: .google, redirectTo: Config.authCallback, queryParams: [(name: "prompt", value: "select_account")])
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            toast = describe(error)
        }
    }

    func signOut() async {
        signedOutFlag = true
        library.flushSave()
        try? await Backend.client.auth.signOut()
        try? await Backend.client.auth.signOut(scope: .local)
        goSignedOut()
    }

    func redeem(code: String) async -> Bool {
        let clean = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard clean.count >= 6 else { toast = "That code doesn’t look right."; return false }
        let r = (try? await Backend.rpc("redeem_beta_code", ["code": .string(clean)]))?.string
        if r == "approved", let uid = userID {
            UserDefaults.standard.set("ok", forKey: "songpad:beta:\(uid)")
            phase = .ready; Haptics.success(); return true
        }
        toast = "That code isn’t valid."; Haptics.warning(); return false
    }

    func recheckBeta() async {
        guard let uid = userID else { return }
        let status = (try? await Backend.rpc("beta_status"))?.string ?? "open"
        if ["open", "admin", "approved"].contains(status) {
            UserDefaults.standard.set("ok", forKey: "songpad:beta:\(uid)"); phase = .ready
        } else { phase = .waitlist(status) }
    }

    // MARK: removing songs (spec §3.9)

    /// Deletes one of my songs (with its uploads), stops sharing it if I own a shared one,
    /// or leaves someone else's shared song (their files stay theirs).
    func removeSong(_ s: Song) async {
        guard let uid = userID else { return }
        let mine = !s.isShared || s.owner.isEmpty || s.owner == uid
        Haptics.warning()
        withAnimation(.snappy) { library.delete(s.id) }
        let client = Backend.client
        if mine {
            let paths = ((s.raw["audio"]?.array ?? []) + (s.raw["files"]?.array ?? []))
                .compactMap { $0["path"]?.string }
                .filter { !$0.hasPrefix("local:") && $0.hasPrefix(uid + "/") }
            if !paths.isEmpty { _ = try? await client.storage.from("song-files").remove(paths: paths) }
            if s.isShared { _ = try? await client.from("shared_songs").delete().eq("id", value: s.id).execute() }
            toast = "Song deleted"
        } else {
            _ = try? await client.from("collab_members").delete().eq("song_id", value: s.id).eq("user_id", value: uid).execute()
            toast = "You left “\(s.displayTitle)”"
        }
    }

    // MARK: profile and plan

    private func loadCachedProfile(_ uid: String) -> Profile {
        guard let d = UserDefaults.standard.data(forKey: "songpad:profile:\(uid)"), let p = try? JSONDecoder().decode(Profile.self, from: d) else { return Profile() }
        return p
    }

    func loadProfile() async {
        guard let uid = userID else { return }
        do {
            let rows: [Profile] = try await Backend.client.from("profiles")
                .select("username,display_name,avatar_url,link_spotify,link_instagram,link_tiktok")
                .eq("user_id", value: uid).order("updated_at", ascending: false, nullsFirst: false).limit(1).execute().value
            if var p = rows.first {
                if (p.display_name ?? "").isEmpty && !metaName.isEmpty {
                    p.display_name = metaName
                    try? await Backend.client.from("profiles").update(["display_name": metaName]).eq("user_id", value: uid).execute()
                }
                profile = p
            } else if profile == Profile() {
                let p = Profile(display_name: metaName.isEmpty ? nil : metaName)
                nonisolated struct Up: Encodable { let user_id: String; let display_name: String?; let updated_at: String }
                try? await Backend.client.from("profiles").upsert(Up(user_id: uid, display_name: p.display_name, updated_at: LibraryStore.iso(Date())), onConflict: "user_id").execute()
                profile = p
            }
            if let d = try? JSONEncoder().encode(profile) { UserDefaults.standard.set(d, forKey: "songpad:profile:\(uid)") }
        } catch {}
    }

    func refreshPlan() async {
        guard let r = try? await Backend.rpc("my_plan") else { return }
        var p = Plan()
        p.tier = r["tier"]?.string ?? "free"
        p.expiresAt = r["expires_at"]?.string
        p.heavyMonth = Int(r["heavy_month"]?.number ?? 0)
        p.storageLimit = r["storage_limit"]?.number
        p.storageUsed = r["storage_used"]?.number ?? 0
        plan = p
    }
}
