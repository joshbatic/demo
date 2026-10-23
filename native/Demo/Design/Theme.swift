import SwiftUI
import UIKit

/// The app's look, matching the web app: monochrome tint (black in light, white in dark),
/// iOS system greys, and the pastel gradient used for Pro, Ideas and covers.
enum Theme {
    /// The app's accent: near-black in light mode, near-white in dark (the web's --tint).
    static let tint = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1) : UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1) })
    static let onTint = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    static let proGreen = Color(red: 0.204, green: 0.780, blue: 0.349)

    /// The pastel wash: peach glow over pink-to-lavender.
    static var pastel: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xFFC2DA), Color(hex: 0xD9C6FF), Color(hex: 0xB9A6FF)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: 0xFFD6A5), Color(hex: 0xFFD6A5).opacity(0)], center: UnitPoint(x: 0.85, y: 0.0), startRadius: 0, endRadius: 260)
        }
    }

    /// The Pro logo tile background.
    static var proTile: some ShapeStyle {
        LinearGradient(colors: [Color(hex: 0xFFC2DA), Color(hex: 0xB9A6FF)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Solid iOS system colours used for icon tiles (Account, Settings), like the Settings app.
    enum Tile {
        static let blue = Color(hex: 0x007AFF), green = Color(hex: 0x34C759), teal = Color(hex: 0x30B0C7)
        static let orange = Color(hex: 0xFF9500), red = Color(hex: 0xFF3B30), purple = Color(hex: 0xAF52DE)
        static let indigo = Color(hex: 0x5856D6), gray = Color(hex: 0x8E8E93), pink = Color(hex: 0xFF2D55), mint = Color(hex: 0x00C7BE)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// The asterisk mark used for the app and Pro.
struct ProMark: View {
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
    }
}
