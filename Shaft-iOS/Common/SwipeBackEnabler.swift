import SwiftUI
import UIKit

/// Restores the left-edge swipe-back (interactive pop) gesture on pushed pages.
///
/// The immersive detail/profile pages hide the system navigation bar
/// (`.toolbar(.hidden, for: .navigationBar)`) — our iOS 26 Liquid Glass
/// glass-band workaround. UIKit ties `interactivePopGestureRecognizer` to the
/// bar, so hiding it kills the edge-swipe-back. This drops an invisible probe
/// view controller into the SwiftUI hierarchy, walks up to the host
/// `UINavigationController`, and re-enables the gesture.
///
/// The delegate is a single shared singleton, NOT a per-page object. A gesture
/// recognizer holds its `delegate` *weakly*, so a per-page delegate dies the
/// moment that page (and its probe) is popped — which silently broke swipe-back
/// on the page you returned to (A→B→C, pop C→B, then B couldn't swipe to A).
/// The singleton never deallocates, so the recognizer's delegate stays valid
/// across every push and pop; it resolves the relevant nav stack from the
/// gesture so the same instance serves all three tab stacks.
///
/// Applied once in `RouteHost` so every pushed destination gets it; it's inert
/// (matches default behaviour) on pages that still show the bar.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Probe() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {
        (vc as? Probe)?.reassert()
    }

    /// Invisible, non-interactive child VC used only to reach the nav controller.
    final class Probe: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            reassert()
        }
        // Re-assert when the page reappears (e.g. after popping a child) so the
        // gesture is live again even though the delegate already persists.
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            reassert()
        }
        func reassert() {
            DispatchQueue.main.async { [weak self] in
                guard let recognizer = self?.navigationController?.interactivePopGestureRecognizer
                else { return }
                recognizer.isEnabled = true
                recognizer.delegate = SwipeBackGestureDelegate.shared
            }
        }
    }
}

/// One persistent delegate for every nav stack's pop recognizer. Resolves the
/// owning `UINavigationController` from the gesture and only lets the pop begin
/// when there's a screen to go back to (so the root can't start a stuck no-op
/// drag).
final class SwipeBackGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = SwipeBackGestureDelegate()

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        var responder: UIResponder? = gesture.view
        while let current = responder {
            if let nav = current as? UINavigationController {
                return nav.viewControllers.count > 1
            }
            responder = current.next
        }
        return false
    }
}
