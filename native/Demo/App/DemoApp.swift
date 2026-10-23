import SwiftUI

@main
struct DemoApp: App {
    @State private var session = AppSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(session.library)
                .tint(Theme.tint)
                // switches are iOS green when on, whatever the app tint
                .toggleStyle(SwitchToggleStyle(tint: Color(uiColor: .systemGreen)))
                .task { await session.start() }
                // the rhyme dictionary loads in the background so it's ready when a song opens
                .task(priority: .utility) { await Task.detached(priority: .utility) { RhymeEngine.shared.load() }.value }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                // leaving the app: write everything down and push it now (spec §2.2)
                session.library.flushSave()
                session.library.sync()
            case .active:
                Haptics.warm()
                Task { await session.library.checkRemote() }
            @unknown default: break
            }
        }
    }
}
