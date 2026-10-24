import SwiftUI

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
