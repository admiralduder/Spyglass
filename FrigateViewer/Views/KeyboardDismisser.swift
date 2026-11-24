import UIKit

/// Closes the keyboard when you tap anywhere that isn't a text field, like most iOS apps.
///
/// A single tap recognizer on the window watches every tap without blocking it,
/// so buttons, toggles and lists keep working normally.
@MainActor
final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()
    private var installedWindows = Set<ObjectIdentifier>()

    func install() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where !installedWindows.contains(ObjectIdentifier(window)) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            installedWindows.insert(ObjectIdentifier(window))
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        recognizer.view?.endEditing(true)
    }

    // Ignore taps on text fields, so tapping another field moves the cursor there instead.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            var view = touch.view
            while let v = view {
                if v is UITextField || v is UITextView { return false }
                view = v.superview
            }
            return true
        }
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
