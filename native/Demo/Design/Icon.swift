import SwiftUI

/// One of the app's own icons (the same SVGs as the web and Mac apps, in Assets as template images),
/// so it takes the surrounding colour in light and dark mode.
struct Icon: View {
    let name: String
    var size: CGFloat = 22
    init(_ name: String, _ size: CGFloat = 22) { self.name = name; self.size = size }
    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The checkmark Done button used at the top of every sheet.
struct DoneButton: View {
    let action: () -> Void
    var body: some View {
        Button { Haptics.tap(); action() } label: { Icon("ic-check", 19) }
            .accessibilityLabel("Done")
    }
}
