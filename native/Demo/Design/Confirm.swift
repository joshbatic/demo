import SwiftUI
import UIKit

/// The original's natDestroy: a full-width action sheet up from the bottom, with the red action and Cancel,
/// after a warning tap. (SwiftUI's own confirmation pops out of the button with an arrow on iOS 26.)
@MainActor
enum Confirm {
    static func destroy(_ title: String, message: String?, action: String, perform: @escaping () -> Void, cancelled: @escaping () -> Void = {}) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: action, style: .destructive) { _ in perform() })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cancelled() })
        // one at a time (a modifier on a list section runs once per row)
        guard let top = topController(), !(top is UIAlertController) else { return }
        // an iPad needs somewhere to point; mid-screen with no arrow keeps it a plain card
        if let pop = a.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        Haptics.warning()
        top.present(a, animated: true)
    }

    /// A plain action sheet of choices (red ones destructive) with Cancel.
    static func options(_ title: String?, message: String? = nil, _ items: [(title: String, red: Bool, run: () -> Void)], done: @escaping () -> Void = {}) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        for i in items { a.addAction(UIAlertAction(title: i.title, style: i.red ? .destructive : .default) { _ in done(); i.run() }) }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done() })
        guard let top = topController(), !(top is UIAlertController) else { done(); return }
        if let pop = a.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        Haptics.tap()
        top.present(a, animated: true)
    }

    /// Presents a SwiftUI screen as a sheet from wherever the app is (a sheet hung on a list row closes when the row goes).
    static func sheet<V: View>(_ make: (_ close: @escaping () -> Void) -> V) {
        guard let top = topController() else { return }
        weak var host: UIViewController?
        let vc = UIHostingController(rootView: make({ host?.dismiss(animated: true) }).tint(Theme.tint).toggleStyle(.green))
        host = vc
        top.present(vc, animated: true)
    }

    /// The front-most screen in the app's own window (not the toast layer).
    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let win = scenes.flatMap(\.windows).first { !($0 is PassthroughWindow) && $0.isKeyWindow }
            ?? scenes.flatMap(\.windows).first { !($0 is PassthroughWindow) }
        var vc = win?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
}

extension View {
    /// Shows `Confirm.destroy` while `isPresented` is true, and sets it back to false when answered.
    func confirmDestroy(_ title: String, isPresented: Binding<Bool>, message: String? = nil, action: String, perform: @escaping () -> Void) -> some View {
        onChange(of: isPresented.wrappedValue) { _, on in
            guard on else { return }
            Confirm.destroy(title, message: message, action: action,
                            perform: { isPresented.wrappedValue = false; perform() },
                            cancelled: { isPresented.wrappedValue = false })
        }
    }
}
