import SwiftUI

/// Central design tokens. Health apps need to read as calm and trustworthy, not
/// "AI generated" — so this deliberately avoids purple gradients and leans on a
/// single teal accent, generous whitespace, and system typography.
enum Theme {
    static let primary = Color("AccentColor")
    static let primaryLight = Color(red: 0.145, green: 0.588, blue: 0.510).opacity(0.12)

    static let success = Color(red: 0.20, green: 0.62, blue: 0.42)
    static let warning = Color(red: 0.85, green: 0.55, blue: 0.15)
    static let danger = Color(red: 0.80, green: 0.30, blue: 0.30)

    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let screenBackground = Color(uiColor: .systemGroupedBackground)

    static let cornerRadius: CGFloat = 18
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.cardPadding)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// A tappable pill showing a previously-saved value, next to any onboarding
/// field that has one to restore. **Supersedes `SavedValueNote`** (added
/// 2026-07-31, a passive read-only badge with the same purpose) — explicit
/// follow-up request the same week: "rather than saying saved value at the
/// top, there should be a saved value button for each section, where the
/// button also displays the current saved value. If you press the button,
/// the value then becomes the saved value." So this both shows *and acts*:
/// tapping it copies the saved value back into whatever field(s) it's
/// attached to via the `action` closure, making it a real one-tap "restore"
/// shortcut instead of just a status label. Only shown when a saved value
/// actually exists — see each call site's `viewModel.saved*Display`.
struct SavedValueButton: View {
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Saved: \(value)", systemImage: "arrow.uturn.backward.circle.fill")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .tint(Theme.primary)
        .controlSize(.small)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }

    /// Caps the content column at a comfortable reading width and centers it.
    /// Sustain's cards were designed against iPhone widths (~390-430pt); on an
    /// iPad, letting them stretch to the full 800-1300pt screen width makes a
    /// single-line card look like an empty banner. This is a no-op in practice
    /// on iPhone, since no iPhone width comes close to the cap, so it's safe to
    /// apply to every top-level scrollable screen regardless of device.
    func readableContentWidth(_ maxWidth: CGFloat = 700) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
