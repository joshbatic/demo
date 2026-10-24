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

extension View {
    /// An iOS 26 Liquid Glass button (tinted when `prominent`); the bordered style before that.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent).tint(Theme.tint) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent).tint(Theme.tint) } else { buttonStyle(.bordered) }
        }
    }
}


/// A Settings-style icon, drawn the way iOS 26's own are: a softly lit gradient tile (lighter at the top),
/// a fine glassy rim catching the light along the top edge, and a crisp white symbol with a whisper of shadow.
struct TileIcon: View {
    let name: String
    let color: Color
    var size: CGFloat = 30
    init(_ name: String, _ color: Color, size: CGFloat = 30) { self.name = name; self.color = color; self.size = size }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size * 0.5, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.16), radius: 0.6, y: 0.6)
            .frame(width: size, height: size)
            .background { TileBackground(colors: [color], size: size) }
            .accessibilityHidden(true)
    }
}

/// The tile itself: one colour lit from above (or a two-colour blend), a glassy top rim and a fine edge.
struct TileBackground: View {
    var colors: [Color]
    var size: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        let fill: LinearGradient = colors.count > 1
            ? LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [colors[0].mix(with: .white, by: 0.22), colors[0], colors[0].mix(with: .black, by: 0.08)],
                             startPoint: .top, endPoint: .bottom)
        shape.fill(fill)
            // light across the top half, like glass
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .top, endPoint: .center))
            }
            // a fine rim, brighter along the top edge
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08), .black.opacity(0.08)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
            }
            .shadow(color: (colors.last ?? .black).opacity(0.25), radius: 1.5, y: 0.8)
    }
}

/// Puts a Label's icon on the same tile (for rows built from a plain Label).
struct TileLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title.foregroundStyle(.primary)
        } icon: {
            configuration.icon.font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.16), radius: 0.6, y: 0.6)
                .frame(width: 30, height: 30)
                .background { TileBackground(colors: [color]) }
        }
    }
}
