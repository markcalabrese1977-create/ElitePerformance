import SwiftUI
import UIKit

/// The decimal and number pads have no Return key, and a multi-line field's Return adds a line: without this a keypad that covers the
/// tab bar cannot be dismissed. One shared answer for every screen that edits a number or a note: a "Done" bar above the keyboard, and
/// a scrolling screen's drag dismisses the keyboard too (`.scrollDismissesKeyboard(.interactively)`).
///
/// The Done bar is a UIKit input accessory put on the field when it begins editing, not a SwiftUI `ToolbarItemGroup(placement: .keyboard)`:
/// that placement did not render on the iOS 26 simulator in this app (Settings, decimal pad), and an accessory works the same on every
/// iOS version, in sheets and in screens with no navigation bar. The accessory goes on number-pad fields and on multi-line fields only;
/// a field with a Return key is left alone.
///
/// Apply `.keyboardDismissal()` ONCE per screen that hosts such fields, on its root scrolling view (a Form, List or ScrollView) or on a
/// sheet's content. A component with a numeric field (`StoredLoadField`, `IntTextField`, `DoubleTextField`) does not apply it itself:
/// the screen that hosts it does (`KeyboardDismissalTests` lists the screens).
enum KeyboardDismissal {
    static let doneTitle = "Done"
    static let doneIdentifier = "keyboardDone"

    /// Resigns whichever field is first responder.
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// The keyboards with no Return key.
    static func needsDone(_ type: UIKeyboardType) -> Bool {
        [.decimalPad, .numberPad, .numbersAndPunctuation, .phonePad, .asciiCapableNumberPad].contains(type)
    }

    /// A bar with one Done button on the right.
    static func makeAccessory() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        let done = UIBarButtonItem(title: doneTitle, style: .done, target: Responder.shared, action: #selector(Responder.done))
        done.accessibilityIdentifier = doneIdentifier
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        bar.sizeToFit()
        return bar
    }

    /// Puts the Done bar on `field` when it needs one and has no accessory of its own.
    @MainActor static func attachIfNeeded(to field: UIResponder) {
        if let f = field as? UITextField, needsDone(f.keyboardType), f.inputAccessoryView == nil {
            f.inputAccessoryView = makeAccessory(); f.reloadInputViews()
        } else if let v = field as? UITextView, v.isEditable, v.inputAccessoryView == nil {
            v.inputAccessoryView = makeAccessory(); v.reloadInputViews()
        }
    }

    @MainActor private static var installed = false

    /// Listens once for fields beginning to edit (idempotent). Called by `.keyboardDismissal()`.
    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let field = note.object as? UIResponder else { return }
                MainActor.assumeIsolated { attachIfNeeded(to: field) }
            }
        }
    }

    final class Responder: NSObject {
        static let shared = Responder()
        @objc func done() { KeyboardDismissal.dismiss() }
    }
}

extension View {
    /// Done above the number pads and multi-line fields, and drag-to-dismiss on a scrolling screen. See `KeyboardDismissal`.
    func keyboardDismissal() -> some View {
        scrollDismissesKeyboard(.interactively)
            .onAppear { KeyboardDismissal.install() }
    }
}
