import SwiftUI

/// "Continue with Google," the second sign-in option added alongside Sign in
/// with Apple on 2026-08-01. See `AuthManager.completeGoogleSignIn` for why
/// Google was chosen over building email/password (it reuses the exact same
/// Supabase `id_token` grant Apple already uses, and needs no SMTP provider,
/// no deep links, and no password-reset flow).
///
/// **Placement rule — do not reorder without checking this first.** Sign in
/// with Apple must stay at least as prominent as this button, and above it.
/// Apple's Human Interface Guidelines require Sign in with Apple to be
/// displayed at least as prominently as other third-party sign-in options
/// wherever both appear. Every call site puts Apple first for that reason.
///
/// **Branding (2026-08-01):** now uses Google's actual four-colour "G" mark,
/// shipped as a vector asset at `Resources/Assets.xcassets/GoogleLogo.imageset`
/// (an SVG with `preserves-vector-representation`, so it stays crisp at any
/// size, and `template-rendering-intent: original` so iOS renders it in full
/// colour instead of tinting it flat). This replaced an earlier typographic "G"
/// placeholder — Google's branding guidelines require their own mark on a
/// "Sign in with Google" button, so the placeholder was a release blocker.
/// **Do not apply `.foregroundStyle`, `.tint`, or `.renderingMode(.template)`
/// to that image**; any of them would collapse the four colours into one and
/// break the guidelines just as badly.
///
/// The light/dark treatment follows Google's own two button variants: a white
/// surface with dark text in light mode, a near-black surface with white text
/// in dark mode. The colour mark is legible on both, so it's unchanged between
/// them.
struct GoogleSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme

    var isDisabled: Bool = false
    var action: () -> Void

    /// Google's dark-variant surface colour. Deliberately not `Color.black`:
    /// the spec uses #131314, and pure black against a near-black system
    /// background would make the button's edge disappear entirely.
    private var surface: Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.075, blue: 0.078)
            : .white
    }

    private var label: Color {
        colorScheme == .dark ? .white : Color(red: 0.235, green: 0.251, blue: 0.263)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("GoogleLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                Text("Continue with Google")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(label)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.22)
                            : Color(red: 0.855, green: 0.859, blue: 0.867),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        // The image is hidden from VoiceOver above, so the button reads as a
        // single element with a meaningful label rather than "G, Continue with
        // Google" or an unlabelled image.
        .accessibilityLabel("Continue with Google")
    }
}

/// Shown when a sign-in has just created a brand-new, empty account on a device
/// that previously used a *different* provider — the account-fragmentation case
/// (see `AuthManager.duplicateAccountWarning`).
///
/// This situation can't be prevented outright by watching for it after the
/// fact — someone who signed in with Apple using Hide My Email has a private
/// relay address; the same person signing in with Google presents a Gmail
/// address, and nothing server-side can safely assume they're one person from
/// the addresses alone. **The real fix is proactive**: `AccountSectionView`'s
/// "Sign-in methods" list lets someone attach the *other* provider to their
/// existing account while already signed in, using Supabase's native identity
/// linking (see `AuthManager.linkGoogleIdentity()` /
/// `linkAppleIdentity(authorization:)`) — anyone who's done that never sees
/// this warning at all, because the second provider was never a separate
/// account to begin with. This view is the fallback for whoever hits the
/// fragmentation before linking (a fresh device, or before this feature
/// existed): it says plainly what happened and points at the immediate fix
/// (sign out, use the original button), with the message below now also
/// naming the linking option for next time.
struct DuplicateAccountWarningView: View {
    let previousProvider: SignInProvider
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("This is a new, empty account")
                    .font(.headline)
            } icon: {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(Theme.warning)
            }

            Text("You previously signed in with \(previousProvider.displayName), and signing in a different way creates a separate account. Your earlier history and any subscription are still on your \(previousProvider.displayName) account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("To get back to it, sign out from Settings and choose \(previousProvider.displayName) again. Once you're back in, Settings also lets you link both sign-in methods to one account so this can't happen again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Got it", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding()
        .cardStyle()
        .padding()
    }
}

#Preview("Google button") {
    VStack(spacing: 16) {
        GoogleSignInButton {}
        GoogleSignInButton(isDisabled: true) {}
    }
    .padding()
}

#Preview("Duplicate account warning") {
    DuplicateAccountWarningView(previousProvider: .apple) {}
}
