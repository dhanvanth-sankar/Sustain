import SwiftUI
import UIKit

/// `.decimalPad` (used everywhere a weight/dose/protein-gram amount is entered:
/// `LogWeightView`, `LogDoseView`, `LogProteinView`, `MedicationProfileEditView`,
/// `OnboardingGoalsView`) has no Return key and no built-in way to dismiss itself —
/// unlike the default keyboard, there is genuinely no gesture or button Apple gives
/// you for free here. Real-device feedback flagged this as a real, repeated
/// annoyance (logged in `Documentation/PROJECT_HANDOFF.md` §17, item 15): every
/// numeric-entry screen in the app was affected, not just one.
///
/// This adds a small "Done" button in the keyboard's own accessory toolbar that
/// resigns first responder app-wide, rather than wiring a `@FocusState` binding
/// through every individual text field (there are 8 call sites across 6 files;
/// a per-field FocusState would mean 8 near-identical bindings for one button).
/// Apply once per screen, on the outermost `Form`/`ScrollView`/`VStack` — every
/// text field on that screen gets the same "Done" button for free.
extension View {
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            }
        }
    }
}
