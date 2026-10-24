import SwiftUI

/// Liquid Glass where the system has it (iOS 26), the regular material elsewhere.
/// Standard bars, sheets, menus, toolbars and controls get glass from the system on their own;
/// these helpers are only for the app's own floating pieces (the rhyme bar, the search bar).
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
        }
    }

    func glassCapsule(interactive: Bool = false) -> some View { glass(in: Capsule(), interactive: interactive) }

    func glassCircle(interactive: Bool = true) -> some View { glass(in: Circle(), interactive: interactive) }
}

/// Groups glass shapes so nearby ones blend into each other the way iOS 26 toolbars do.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A round glass button with an icon, for floating controls.
struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 52
    var label: String
    let action: () -> Void
    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle()
        .accessibilityLabel(label)
    }
}

extension View {
    /// A tall sheet whose top sits just under the Dynamic Island (or status bar), rather than running up to the
    /// very top of the screen, so the app behind stays visible as a sliver and the flow keeps its rhythm.
    func belowIslandSheet() -> some View {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let top = scene?.windows.first?.safeAreaInsets.top ?? 59
        let h = (scene?.screen.bounds.height ?? UIScreen.main.bounds.height) - top - 10
        return presentationDetents([.height(h)])
    }
}
