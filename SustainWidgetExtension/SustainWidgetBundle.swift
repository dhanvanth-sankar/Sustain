import SwiftUI
import WidgetKit

/// Entry point for the widget extension process. This process is entirely
/// separate from the main app — it never imports RevenueCat or touches
/// SwiftData, only `Sustain/Shared/WidgetSnapshot.swift` (read-only) and
/// `Sustain/Shared/DoseActivityAttributes.swift`. See
/// `Services/LiveActivityManager.swift` in the main app target for why that
/// separation matters (RevenueCat's `Purchases.shared` force-crashes if
/// touched outside the main app's own launch sequence).
@main
struct SustainWidgetBundle: WidgetBundle {
    var body: some Widget {
        DoseWidget()
        DoseLiveActivity()
    }
}
