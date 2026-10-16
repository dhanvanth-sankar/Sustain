import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedWelcomeCarousel") private var hasCompletedWelcomeCarousel = false
    @State private var auth = AuthManager.shared
    @State private var syncManager = CloudSyncManager.shared
    @State private var network = NetworkMonitor.shared

    /// Sign-in is mandatory app-wide as of 2026-07-30 — this is the one
    /// place that gate is actually enforced, ahead of both onboarding and
    /// the main app. See `MandatorySignInView`'s header comment for the
    /// full rationale and history. `isRestoringSession` (true only for the
    /// brief moment `AuthManager` is reading a persisted session out of the
    /// Keychain at launch) avoids a jarring flash of the sign-in screen for
    /// someone who's already signed in — without checking it, every launch
    /// would show the sign-in gate for one frame before `auth.isSignedIn`
    /// finished loading and flipped true.
    ///
    /// As of 2026-07-31: which sign-in gate depends on
    /// `hasCompletedWelcomeCarousel`. A genuinely first-time install (that
    /// flag still `false`) sees `WelcomeCarouselView` — a swipeable feature
    /// tour ending in the sign-in page, per explicit request ("greeted
    /// through slides by swiping right... the last slide should have the
    /// sign in page"). `WelcomeCarouselView` flips the flag itself the
    /// moment sign-in succeeds, so every later return to this gate (sign
    /// out, delete account, an expired session) instead shows
    /// `MandatorySignInView` directly — no need to re-show the marketing
    /// tour to someone who's already used the app. The `.task` at the bottom
    /// of `body` also flips this flag early (2026-08-01) for one more case:
    /// a device upgrading from a version old enough to have real local data
    /// from before an account was required — that's not a first-time
    /// install either, and skipping straight to `MandatorySignInView` gets
    /// them to the actual point faster: `resolveAfterSignIn` silently
    /// merges that data into whichever account they sign into, no separate
    /// screen needed (see `CloudSyncManager.resolveAfterSignIn`'s doc
    /// comment for why that no longer requires asking). Whether onboarding
    /// (medication/dose/goals setup) runs after that is governed separately
    /// by `hasCompletedOnboarding`, a per-device flag `OnboardingFlow` sets
    /// once it's actually been completed on this device — deliberately
    /// still shown even to a returning user signing in on a brand-new
    /// device (rather than auto-skipped once their data syncs down), since
    /// `OnboardingFlow` now pre-fills itself from whatever already exists
    /// and doubles as a quick review-and-confirm step. As of 2026-08-01,
    /// that review step is a single "keep or edit" screen
    /// (`SyncedProfileReviewView`) rather than the full wizard, for anyone
    /// whose synced profile was already a real, started plan — see
    /// `OnboardingFlow`'s header comment for the reasoning.
    ///
    /// Real bug, caught immediately from real usage: `auth.isSignedIn` flips
    /// from inside `AuthManager` (a plain property set, not wrapped in
    /// `withAnimation`), so without the `.transition`/`.animation` pair
    /// below, SwiftUI just swaps the sign-in gate in and out instantly — no
    /// crossfade, no motion, an abrupt cut on every sign-out. Attaching
    /// `.animation(_:value:)` to the `Group` implicitly wraps *any* future
    /// change to that value in the given curve regardless of whether the
    /// code that changed it knew or cared about animation, which is what
    /// actually fixes this (versus, say, wrapping `AuthManager.signOut()`
    /// itself in `withAnimation`, which would only smooth this one call site
    /// and not sign-in/delete-account's other paths back to this same gate).
    var body: some View {
        VStack(spacing: 0) {
            // Explicit request: "when the device is offline, a message at
            // the top of the screen should say it's offline and new
            // additions will be saved but synced... when the app is opened
            // with internet." Shown above everything else (sign-in gate,
            // onboarding, main app alike) since offline is relevant to all
            // of them — signing in specifically requires connectivity, and
            // this is the one place that explains why without needing a
            // separate error state for it.
            if !network.isOnline {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                if auth.isRestoringSession {
                    LaunchLoadingView()
                        .transition(.opacity)
                } else if !auth.isSignedIn {
                    Group {
                        if hasCompletedWelcomeCarousel {
                            MandatorySignInView()
                        } else {
                            WelcomeCarouselView()
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 1.06))
                    ))
                } else if syncManager.isRestoringAfterSignIn {
                    // 2026-08-01: local data no longer survives sign-out/
                    // delete-account (see `AccountSectionView`), so *every*
                    // sign-in now needs a real network round trip to pull
                    // the account's data back down before there's anything
                    // meaningful to show. Without this, `MainTabView` would
                    // render with a genuinely empty Dashboard for however
                    // long that takes — reads exactly like data loss, which
                    // is the opposite of what this whole change was for.
                    // See `CloudSyncManager.isRestoringAfterSignIn`'s doc
                    // comment.
                    LaunchLoadingView()
                        .transition(.opacity)
                } else if hasCompletedOnboarding {
                    MainTabView()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    OnboardingFlow()
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: network.isOnline)
        .animation(.easeInOut(duration: 0.45), value: auth.isSignedIn)
        .animation(.easeInOut(duration: 0.3), value: auth.isRestoringSession)
        .animation(.easeInOut(duration: 0.3), value: syncManager.isRestoringAfterSignIn)
        .animation(.easeInOut(duration: 0.3), value: hasCompletedOnboarding)
        // 2026-08-01, explicit request: give someone upgrading from 1.0.1
        // (a version old enough to have real local data from before an
        // account was ever required) a way to import that data into their
        // new account. That machinery already existed —
        // `resolveAfterSignIn`'s `(local has data, account doesn't)` case
        // silently merges this device's data into whatever account they
        // sign into — but the *first screen* stood in the way: with
        // `hasCompletedWelcomeCarousel` defaulting `false` for every device
        // (it's a brand-new key), an upgrading device with years of real
        // history would see the first-time marketing carousel before ever
        // reaching sign-in, same as a genuinely empty fresh install. Checked
        // once, here, rather than in `WelcomeCarouselView` itself, since
        // only `ContentView` runs before that view is even chosen: local
        // data existing at all, before anyone has ever signed in on this
        // device, can only mean a pre-mandatory-sign-in install — under the
        // current build, no screen that writes local data is reachable
        // without an account first, so this signal can't be confused with
        // someone mid-onboarding on a fresh device.
        .task {
            if !hasCompletedWelcomeCarousel, CloudSyncManager.shared.hasLocalData(context: modelContext) {
                hasCompletedWelcomeCarousel = true
            }
        }
        // Account fragmentation, added 2026-08-01 alongside Google sign-in.
        // Presented here rather than on the sign-in screens themselves because
        // those screens are torn down by this very view the instant
        // `auth.isSignedIn` flips true — the warning has to outlive them to be
        // read at all. See `AuthManager.duplicateAccountWarning` and
        // `DuplicateAccountWarningView` for why this case exists and can't
        // simply be prevented.
        .sheet(
            isPresented: Binding(
                get: { auth.duplicateAccountWarning != nil },
                set: { if !$0 { auth.dismissDuplicateAccountWarning() } }
            )
        ) {
            if let previous = auth.duplicateAccountWarning {
                DuplicateAccountWarningView(previousProvider: previous) {
                    auth.dismissDuplicateAccountWarning()
                }
                .presentationDetents([.medium])
            }
        }
    }
}

struct MainTabView: View {
    // Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §4a: the
    // paywall itself was already reachable everywhere a gated feature lives
    // (Settings, Dashboard, Trends, the AI cards), but never shown
    // proactively — someone could use Sustain for weeks and never see it
    // unless they happened to tap something gated. Immediately after
    // `OnboardingProjectionView`'s personalized "plan" reveal is the moment
    // the report's research says conversion is highest (investment is at
    // its peak, right before the ask), so this shows the paywall exactly
    // once, the first time `MainTabView` appears for a non-premium member —
    // deliberately a one-shot `@AppStorage` flag rather than tied to
    // `hasCompletedOnboarding` directly, so it fires the same way for a
    // returning user completing the "kept synced profile" review path too
    // (which skips the wizard, but never got a proactive paywall moment
    // either). Still fully dismissible — this doesn't change Sustain's
    // existing soft-paywall model (see `PROJECT_HANDOFF.md`'s "local-first,
    // privacy as a selling point" history), it just makes sure the pitch is
    // actually seen once, at the best-researched moment, instead of only on
    // request.
    @AppStorage("hasShownPostOnboardingPaywall") private var hasShownPostOnboardingPaywall = false
    @State private var entitlements = EntitlementManager.shared
    @State private var showingPostOnboardingPaywall = false

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Today", systemImage: "sun.max.fill") }

            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.primary)
        .task {
            guard !hasShownPostOnboardingPaywall, !entitlements.isPremium else { return }
            // A brief pause so this doesn't collide with the tab bar's own
            // appearance animation — the paywall sheet should feel like the
            // next deliberate beat after onboarding, not an interruption of
            // the app still settling onto the Dashboard.
            //
            // `do/catch` with an explicit return, not `try?`. Caught in
            // pre-test audit: `try?` swallows the cancellation error but
            // execution continues, so if this view is torn down during those
            // 0.6s (sign-out, a SwiftUI rebuild of this branch) the one-shot
            // flag would be burned and the paywall never actually shown.
            do {
                try await Task.sleep(for: .seconds(0.6))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            hasShownPostOnboardingPaywall = true
            showingPostOnboardingPaywall = true
        }
        .sheet(isPresented: $showingPostOnboardingPaywall) {
            PaywallView(trigger: .postOnboarding)
        }
        // Same "stuck in light mode" fix as `ChatCoachView` — see that
        // file's comment for the full explanation.
        .preferredColorScheme(nil)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            MedicationProfile.self, DoseLog.self, WeightEntry.self, ProteinEntry.self, SideEffectLog.self,
        ], inMemory: true)
}
