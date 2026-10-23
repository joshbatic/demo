import UIKit

/// The song screen draws its own bar like the web app, which hides the system one; this keeps
/// the edge swipe back working anyway, as it does everywhere else in iOS.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === interactivePopGestureRecognizer ? viewControllers.count > 1 : true
    }
}
