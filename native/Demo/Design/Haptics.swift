import UIKit

/// Haptics, with the generators kept warm so a tap is felt the instant it lands.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let select = UISelectionFeedbackGenerator()
    private static let notify = UINotificationFeedbackGenerator()

    static func tap() { light.impactOccurred(intensity: 0.7); light.prepare() }
    static func thud() { medium.impactOccurred(); medium.prepare() }
    static func selection() { select.selectionChanged(); select.prepare() }
    static func success() { notify.notificationOccurred(.success); notify.prepare() }
    static func warning() { notify.notificationOccurred(.warning); notify.prepare() }
    static func warm() { light.prepare(); select.prepare() }
}
