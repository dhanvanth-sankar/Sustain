import AuthenticationServices
import SwiftData
import SwiftUI

/// The gate `ContentView` shows instead of onboarding or `MainTabView`
/// whenever `AuthManager.shared.isSignedIn` is `false` — as of 2026-07-30,
/// **an account is required to use Sustain at all**, a deliberate reversal
/// of this app's original "local-first, no login required" design (see
/// `PROJECT_HANDOFF.md`'s "Local-first, privacy as a selling point" section
/// and `APP_REVIEW_NOTES.md` §7 for the full history and the App Store
/// review implications of that reversal). This is not an onboarding step —
/// it sits in front of onboarding itself, so a brand-new install sees it
/// before anything else, and it re-appears for an existing installed user
/// who signs out, deletes their account, or updates from a version of the
/// app that predates this requirement and has local data but no account.
///
/// Genuinely blocking, on purpose: no skip button, no "maybe later." If
/// that's ever reconsidered, the two other places that still assume
/// sign-in-is-optional and would need to change together are
/// `AccountSectionView`'s footer copy and `SettingsView`'s "About" privacy
/// paragraph — both already updated to describe sign-in as required, not
/// optional.
///
/// As of 2026-07-31, this view is also embedded verbatim as the last page of
/// `WelcomeCarouselView`'s swipeable feature carousel, which is what a
/// genuinely first-time install actually shows in front of `ContentView`
/// now — see that file's header comment. This view is unchanged for that
/// use; it doesn't know or care whether it's being shown standalone (every
/// later return to the sign-in gate — sign out, delete account, expired
/// session) or as one page of a `TabView`. The only addition is
/// `onSignedIn`, an optional callback `WelcomeCarouselView` uses to mark its
/// own "seen it once" flag the moment sign-in actually succeeds; standalone
/// callers can just omit it.
struct MandatorySignInView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var auth = AuthManager.shared
    @State private var syncManager = CloudSyncManager.shared

    @State private var isSigningIn = false
    @State private var errorMessage: String?

    /// Optional hook fired right after a successful sign-in completes (after
    /// `resolveAfterSignIn`, which by this point has already silently
    /// merged any local data on this device into the signed-in account — see
    /// its doc comment). Defaults to a no-op so every existing call site
    /// (`ContentView`'s standalone use) keeps working unchanged.
    var onSignedIn: () -> Void = {}

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "leaf.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(Theme.primary)

            VStack(spacing: 10) {
                Text("Sign in to Sustain")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("An account keeps your medication, dose, weight, and protein history safe and available if you switch phones.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 14) {
                // Bug fixed here (2026-07-30, caught from a real screenshot):
                // a hardcoded `.black` button style on `Theme.screenBackground`
                // (`systemGroupedBackground`, which renders near-black in dark
                // mode) made the button nearly invisible — button and
                // background were almost the same color. Apple's own guidance
                // is to use the white style on dark backgrounds and black on
                // light ones, so this now adapts to `colorScheme` instead of
                // assuming one fixed appearance; that's the actual contrast
                // fix. Everything below the `.signInWithAppleButtonStyle` line
                // is purely cosmetic on top of that fix — a soft dark drop
                // shadow plus a wider glow tinted with the app's own accent
                // color for a "floating" lifted look, and a subtle top-edge
                // highlight for a glossy bevel, without touching Apple's own
                // required rendering of the button's logo/text/shape (which
                // Sign in with Apple's Human Interface Guidelines don't allow
                // customizing — only the container around it is fair game).
                SignInWithAppleButton(.signIn) { request in
                    auth.prepareAppleSignInRequest(request)
                } onCompletion: { result in
                    handleSignInResult(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 8)
                .shadow(color: Theme.primary.opacity(0.4), radius: 24, x: 0, y: 12)
                .disabled(isSigningIn)
                .padding(.horizontal, 32)

                // Second provider, added 2026-08-01. Kept below Sign in with
                // Apple, and without the lifted shadow treatment above, on
                // purpose: Apple's HIG requires Sign in with Apple to be at
                // least as prominent as other third-party sign-in options
                // shown alongside it. See `GoogleSignInButton`'s doc comment.
                GoogleSignInButton(isDisabled: isSigningIn) {
                    handleGoogleSignIn()
                }
                .padding(.horizontal, 32)

                if isSigningIn {
                    HStack {
                        ProgressView()
                        Text("Setting up your account…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .padding(.top, 8)

            // No login-required app can promise this is optional; being
            // upfront about what account creation involves and why (rather
            // than a bare button with no explanation) is the closest
            // available substitute for the choice that used to exist here.
            // Reworded 2026-08-01. The old version promised "Sustain never
            // sees your Apple ID email unless you choose to share it," which
            // was only ever true of Apple and became actively misleading once
            // Google shipped alongside it. It also now points at Settings for
            // linking both methods, so the "use the same option each time"
            // constraint reads as something the person can resolve rather
            // than just a warning.
            Text("Use the same option each time, since signing in a different way creates a separate account. Once you're in, Settings lets you link both so either one works. You can delete your account and its synced data anytime from Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 4)

            Spacer()
            Spacer()
        }
        .padding()
        .readableContentWidth(500)
        .background(Theme.screenBackground)
    }

    private func handleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            // .canceled fires whenever someone dismisses Apple's own sheet
            // without picking an account — not a real error, just back to
            // this same screen with nothing to say about it.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
        case .success(let authorization):
            isSigningIn = true
            errorMessage = nil
            Task {
                do {
                    try await auth.completeAppleSignIn(authorization: authorization)
                    // Shared with `AccountSectionView` — see
                    // `CloudSyncManager.resolveAfterSignIn`'s doc comment for
                    // both what this decides and, as of 2026-07-31, why its
                    // result now lives on `CloudSyncManager` itself instead
                    // of being handled here: this view can be (and, for the
                    // mandatory sign-in gate, always is) unmounted by
                    // `ContentView` the instant `auth.isSignedIn` flips true,
                    // which happens above, before this `await` even returns.
                    try await syncManager.resolveAfterSignIn(context: modelContext)
                    onSignedIn()
                } catch {
                    errorMessage = error.localizedDescription
                }
                isSigningIn = false
            }
        }
    }

    /// Google's equivalent of `handleSignInResult`. Structurally identical from
    /// `resolveAfterSignIn` onward — only the token source differs (see
    /// `AuthManager.completeGoogleSignIn`), which is exactly why Google was the
    /// cheap second provider to add.
    private func handleGoogleSignIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await auth.completeGoogleSignIn()
                try await syncManager.resolveAfterSignIn(context: modelContext)
                onSignedIn()
            } catch {
                // Google's SDK reports a plain user-dismissal as an error, the
                // same way `ASAuthorizationError.canceled` does — and for the
                // same reason it shouldn't surface as one. `.canceled` here is
                // `GIDSignInError.Code.canceled` (rawValue -5).
                if (error as NSError).code != -5 {
                    errorMessage = error.localizedDescription
                }
            }
            isSigningIn = false
        }
    }
}

#Preview {
    MandatorySignInView()
        .modelContainer(for: [
            MedicationProfile.self, DoseLog.self, WeightEntry.self, ProteinEntry.self, SideEffectLog.self,
        ], inMemory: true)
}
