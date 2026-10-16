import AuthenticationServices
import StoreKit
import SwiftData
import SwiftUI

/// Account settings content: sync status / sync now / sign out / delete
/// account. Deliberately its own view rather than inlined into
/// `SettingsView`'s `body` — that file is already long, and this piece owns
/// enough local state (in-flight sign-out/deletion, error alerts) to be
/// worth isolating.
///
/// **2026-08-01**: no longer shown inline in the middle of the main Settings
/// list — real feedback flagged that account settings, arguably the most
/// consequential section in the app (it's where "delete account" lives),
/// were easy to miss mixed in among weight units and reminders. Moved to its
/// own screen, `AccountSettingsView`, reached via a single row pinned to the
/// very top of `SettingsView`. This view's own logic didn't need to change
/// for that, only where it's hosted.
///
/// **Sign-in is mandatory app-wide as of 2026-07-30** — `MandatorySignInView`
/// gates `ContentView` itself, so by the time anyone reaches Settings at
/// all, they're already signed in. `signedOutContent` below is kept as a
/// brief defensive fallback for the transitional instant between tapping
/// "Sign out"/deleting the account and `ContentView` swapping back to the
/// mandatory gate (see `AuthManager.isSignedIn`'s consumers), not because
/// Settings is ever meant to be a real, lasting "browse the app signed out"
/// state — that state no longer exists.
///
/// See `AuthManager.swift`'s header comment for how Sign in with Apple and
/// Continue with Google relate under Guideline 4.8 (as of 2026-08-01 the
/// guideline genuinely applies, and Apple is the privacy-preserving
/// equivalent that satisfies it — so it must stay offered and at least as
/// prominent as Google), and
/// `CloudSyncManager.resolveAfterSignIn`'s doc comment for how a device's
/// local data gets folded into whatever account signs in — merged silently,
/// with no confirmation screen, since 2026-08-01 (there used to be one; see
/// that doc comment for why it was removed rather than kept).
struct AccountSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var auth = AuthManager.shared
    @State private var syncManager = CloudSyncManager.shared
    /// Needed only to warn about an active subscription before account
    /// deletion — see `activeSubscriptionDeletionWarning`.
    @State private var entitlements = EntitlementManager.shared

    @State private var showingManageSubscriptions = false
    @State private var isLinkingAccount = false
    @State private var showingSignOutConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var isSigningOut = false
    @State private var isDeletingAccount = false
    @State private var errorMessage: String?

    /// Backing state for the "Sign-in methods" list — see
    /// `linkedIdentitiesSection`. Loaded on appearance of `signedInContent`
    /// rather than kept on `AuthManager` itself, since it can change from
    /// linking/unlinking right here and Supabase's own state is the only
    /// thing worth trusting as current.
    @State private var linkedIdentities: [AuthManager.LinkedIdentity] = []
    @State private var isLoadingIdentities = false
    @State private var isManagingIdentity = false
    @State private var identityErrorMessage: String?
    /// The follow-up explanation for the one linking failure that has a real
    /// resolution path rather than a "try again" — see
    /// `AuthError.identityAlreadyLinkedGuidance`.
    @State private var identityErrorGuidance: String?

    var body: some View {
        Section {
            if auth.isRestoringSession {
                HStack {
                    ProgressView()
                    Text("Checking account status…")
                        .foregroundStyle(.secondary)
                }
            } else if auth.isSignedIn {
                signedInContent
            } else {
                signedOutContent
            }
        } footer: {
            // No section header here (just "Account & sync" repeated) —
            // 2026-08-01: this view now always lives inside
            // `AccountSettingsView`'s own screen, already titled "Account &
            // Sync," so a matching Section header directly under it would
            // just be the same words twice in a row.
            // Reworded 2026-08-01: the old copy said sign-in "uses Apple's
            // account system," which stopped being the whole truth the moment
            // Continue with Google shipped. It now describes what's actually
            // true of both, and Apple's Hide My Email is described as the
            // option it is rather than as a blanket promise.
            //
            // Reworded again 2026-08-09 per Sustain-User-Feedback-Triage-2026-08.md
            // item 5: an Indie Hackers commenter engaged seriously with the
            // local-storage-vs-sync tradeoff and specifically responded to
            // framing it as "trust in different directions" — local-only asks
            // for less trust in Sustain but more risk to the person (a real
            // user in that same thread lost everything on a phone switch,
            // back when 1.0 had no accounts at all), while syncing asks for
            // more trust in Sustain in exchange for that risk going away. The
            // concrete "someone actually lost their data" story landed better
            // than an abstract privacy pitch, so this keeps that shape rather
            // than defaulting back to generic reassurance.
            Text(auth.isSignedIn
                ? "This is the other side of that tradeoff: keeping everything local-only would ask less trust of Sustain, but it's what let earlier users lose their whole history on a phone switch, back before accounts existed at all. Syncing asks you to trust that this won't happen to you — your data is backed up to your account precisely so switching phones, or losing one, doesn't mean losing your history. Sustain only ever sees the email your sign-in provider shares with it, and with Apple you can choose to hide that behind a private relay address."
                : "Sustain requires an account so your data is always backed up and available if you switch phones — the alternative is local-only storage, which is what let earlier users lose their entire history when they got a new phone, before accounts existed.")
                .font(.caption2)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            presenting: errorMessage
        ) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
        // **2026-08-01, a deliberate simplification, superseding the
        // two-option delete-account dialog below it in this file's history**
        // (and, before that, "Sign out" leaving local data alone entirely).
        // Explicit reasoning, put directly to the user and confirmed: nearly
        // every real bug chased earlier this same day — the silent
        // auto-attach, the missing setup screen, the merge-choice sheet
        // never appearing — traced back to local data being allowed to
        // outlive the session that created it. If sign-out and delete-
        // account both *always* leave this device clean, that whole class of
        // "whose data is this, actually" ambiguity stops being possible, and
        // `resolveAfterSignIn`'s local-data-merge path (silent since
        // 2026-08-01 — see its doc comment) becomes a rare fallback (a
        // pre-mandatory-sign-in legacy install) instead of something that
        // has to work right on every sign-in. Local storage isn't going away — it's
        // still the full offline-capable cache for as long as you're signed
        // in (see `OfflineBanner`/`NetworkMonitor`, added the same day) —
        // it's just no longer allowed to persist past the boundary of
        // actually being signed in.
        //
        // The one real risk this introduces: wiping local data immediately
        // on sign-out could permanently lose anything logged while offline
        // and never successfully synced. Fixed by `performSignOut()` doing a
        // final `syncNow` push *first* and refusing to sign out at all if
        // that fails — the confirmation below can't promise "nothing is
        // lost" unless sign-out actually enforces it.
        .confirmationDialog("Sign out?", isPresented: $showingSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { performSignOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your data is backed up to your account and this device's copy is then cleared. Sign back in anytime to get it back. Since an account is required to use Sustain, you'll be asked to sign in again right away.")
        }
        // The subscription warning below is required, not a nicety: Apple's
        // own "Offering account deletion in your app" guidance says that if
        // the user has an auto-renewable subscription you must "notify them
        // that their billing will continue through Apple and request that
        // they cancel their subscription before continuing." Sustain
        // previously said nothing about it here, which was both a review risk
        // and a real way for someone to keep paying for an account they
        // believed they had fully closed — deleting a Sustain account has
        // never had any effect on Apple-side billing, since Sustain doesn't
        // process payments at all.
        //
        // Deliberately *not* implemented as a "Manage subscription" button
        // inside this dialog: presenting a sheet directly from a
        // `confirmationDialog` button means presenting while the dialog is
        // still dismissing, which is exactly the view-lifecycle race that
        // produced the merge-choice sheet bug documented in `CHANGELOG.md`
        // (2026-07-31). The warning is surfaced inline in `signedInContent`
        // instead, above the delete button, where it's visible *before* the
        // dialog opens and its button can present the sheet cleanly.
        .confirmationDialog("Delete your account?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { performDeleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage)
        }
        .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
    }

    /// Account deletion never touches Apple-side billing, so an active
    /// subscriber gets an extra sentence saying so explicitly — see the
    /// dialog's own comment for the Apple guidance requiring this.
    private var deleteConfirmationMessage: String {
        let base = "This permanently deletes your account and everything synced to it from the cloud, and clears this device's copy too; that can't be undone. Since an account is required to use Sustain, you'll be asked to sign in again (creating a new account) right away."
        guard entitlements.isPremium else { return base }
        return base + "\n\nDeleting your account does NOT cancel your Sustain+ subscription. Billing continues through Apple until you cancel it in the App Store."
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignInWithAppleButton(.signIn) { request in
                auth.prepareAppleSignInRequest(request)
            } onCompletion: { result in
                handleSignInResult(result)
            }
            // Same contrast fix as `MandatorySignInView` (2026-07-30) — a
            // hardcoded `.black` style risks blending into a dark-mode Form
            // row background, so this adapts to `colorScheme` instead,
            // matching Apple's own light-background/dark-background
            // guidance for the button.
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 44)
            .disabled(isLinkingAccount)

            // Kept below Sign in with Apple, per the HIG prominence rule
            // documented on `GoogleSignInButton`.
            GoogleSignInButton(isDisabled: isLinkingAccount) {
                handleGoogleSignIn()
            }
            .frame(height: 44)

            if isLinkingAccount {
                HStack {
                    ProgressView()
                    Text("Setting up your account…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var signedInContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.primary)
                // Explicit request: show who's actually signed in, not just
                // that someone is. Falls back to plain "Signed in" when
                // `session.email` is nil — see `SupabaseSession.email`'s doc
                // comment for the (rare) cases that can still happen.
                Text(auth.session?.email.map { "Signed in as \($0)" } ?? "Signed in")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if syncManager.isSyncing {
                    ProgressView()
                }
            }

            if let lastSyncError = syncManager.lastSyncError {
                Text("Last sync failed: \(lastSyncError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // "Sync now" and "Sign out" are both routine, safe, reversible
            // actions — styled as equal-weight bordered buttons so they read
            // as ordinary controls someone might tap without a second
            // thought. "Delete account" below is deliberately NOT given the
            // same treatment: it used to sit directly underneath as a
            // full-width red button with identical visual weight to "Sign
            // out," which made an irreversible action just as easy to tap as
            // a routine one — flagged directly by real usage, not a
            // hypothetical concern. It's now small caption-sized text,
            // pushed down with extra top padding, matching the common "bury
            // the destructive account action" pattern most apps use for
            // exactly this reason. `role: .destructive` stays on the button
            // itself (VoiceOver still announces it correctly as a
            // destructive action), only its visual size/prominence changed.
            HStack(spacing: 8) {
                Button("Sync now") { syncNow() }
                    .buttonStyle(.bordered)
                    .tint(Theme.primary)
                    .disabled(syncManager.isSyncing || isSigningOut)

                // Real usability report, with a screenshot: `.tint(.secondary)`
                // rendered this button's border and text in a low-contrast
                // gray that read as *disabled*, not just "less emphasized
                // than Sync now" (the actual intent — see the comment above).
                // `.tint(.primary)` keeps it visually secondary to "Sync
                // now"'s brand-colored tint while still rendering with real,
                // clearly-tappable contrast (adaptive black/white) in both
                // color schemes.
                Button("Sign out") { showingSignOutConfirmation = true }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                    .disabled(isSigningOut)
            }
            .padding(.top, 4)

            if isSigningOut {
                HStack {
                    ProgressView()
                    Text("Backing up your data before signing out…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }

            linkedIdentitiesSection

            if isDeletingAccount {
                HStack {
                    ProgressView()
                    Text("Deleting account…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 14)
            } else {
                activeSubscriptionDeletionWarning

                Button("Delete account", role: .destructive) { showingDeleteConfirmation = true }
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.75))
                    .padding(.top, 14)
            }
        }
        .padding(.vertical, 4)
        .task { await loadLinkedIdentities() }
    }

    /// A list of both providers with their current link status, so someone
    /// can proactively attach whichever one they're *not* currently signed in
    /// with — the fix for the account-fragmentation problem described on
    /// `AuthManager`'s header comment (Apple's Hide My Email relay address and
    /// a Gmail address otherwise look like two different people to Supabase).
    /// Linking here means either provider gets back into this same account
    /// from now on, instead of only reacting to a duplicate account after
    /// it's already been created (`DuplicateAccountWarningView`).
    @ViewBuilder
    private var linkedIdentitiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign-in methods")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 14)

            if isLoadingIdentities {
                ProgressView()
                    .controlSize(.small)
            } else if linkedIdentities.isEmpty {
                // A signed-in account always has at least one identity, so an
                // empty list here can only mean the fetch failed (offline, or
                // a server hiccup). Rendering the normal rows in that case
                // would state something false, showing *both* providers as
                // "Not linked" and offering to link the one already in use, so
                // this says what actually happened instead.
                HStack(spacing: 6) {
                    Text("Couldn't check your sign-in methods.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button("Retry") {
                        Task { await loadLinkedIdentities() }
                    }
                    .font(.caption2)
                }
            } else {
                ForEach(SignInProvider.allCases, id: \.self) { provider in
                    identityRow(for: provider)
                }
            }

            if let identityErrorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(identityErrorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)

                    // Styled as ordinary secondary text rather than more red:
                    // this half is instructions, not the failure, and a single
                    // long red block reads as "everything is broken" when the
                    // situation is actually recoverable.
                    if let identityErrorGuidance {
                        Text(identityErrorGuidance)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !linkedIdentities.isEmpty {
                // Second sentence added 2026-08-01 after a real device report:
                // someone signed into a new Google account, tried to link an
                // Apple account that already existed, and got a bare failure.
                // Supabase refuses to link an identity that belongs to another
                // user rather than merging the two accounts, so the constraint
                // is better stated before the attempt than only after it.
                Text("Linking both means either one signs you back into this same account. You can only link a method that isn't already the sign-in for another Sustain account, since accounts can't be combined. Otherwise, Apple's Hide My Email and a Google address look like two different people, and you'd end up in a new, empty account.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One provider's status, plus its link control when it isn't linked yet.
    ///
    /// The link control deliberately sits on its own full-width line below the
    /// status row rather than inline on the trailing edge. An inline version
    /// was tried first and had to be ~32pt tall to fit the row, which is under
    /// the 44pt minimum touch target Apple's HIG specifies, and cramped the
    /// Sign in with Apple button below the size Apple's own button guidelines
    /// expect. Full width also means both providers' buttons keep their
    /// official branded chrome at a normal size, which both companies'
    /// branding guidelines require.
    @ViewBuilder
    private func identityRow(for provider: SignInProvider) -> some View {
        let isLinked = linkedIdentities.contains { $0.provider == provider }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                providerIcon(for: provider)

                Text(provider.displayName)
                    .font(.subheadline)

                Spacer()

                if isLinked {
                    if linkedIdentities.count > 1 {
                        Button("Remove") { removeIdentity(provider) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .tint(.primary)
                            .disabled(isManagingIdentity)
                    } else {
                        // Supabase itself refuses to unlink an account's last
                        // remaining identity, so this shows status only rather
                        // than a "Remove" button that could only ever fail.
                        Text("Linked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not linked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !isLinked {
                switch provider {
                case .apple:
                    SignInWithAppleButton(.continue) { request in
                        auth.prepareAppleSignInRequest(request)
                    } onCompletion: { result in
                        handleLinkAppleResult(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 44)
                    .disabled(isManagingIdentity)
                case .google:
                    // The same branded component both sign-in surfaces use, so
                    // Google's mark and button chrome stay consistent (and
                    // compliant) everywhere they appear.
                    GoogleSignInButton(isDisabled: isManagingIdentity) {
                        linkGoogleIdentity()
                    }
                    .frame(height: 44)
                }
            }
        }
        .padding(.bottom, 2)
    }

    /// Apple gets its SF Symbol; Google gets the real four-colour mark from the
    /// asset catalog rather than the generic `g.circle.fill` glyph an earlier
    /// version used, matching `GoogleSignInButton`.
    @ViewBuilder
    private func providerIcon(for provider: SignInProvider) -> some View {
        switch provider {
        case .apple:
            Image(systemName: "apple.logo")
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
        case .google:
            Image("GoogleLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        }
    }

    /// Shown directly above "Delete account" whenever there's an active
    /// subscription, so the person sees it *before* opening the destructive
    /// dialog rather than only inside it. Carries its own "Manage
    /// subscription" button, which is the actionable half of Apple's guidance
    /// ("request that they cancel their subscription before continuing") —
    /// and, being an ordinary button rather than one inside a dismissing
    /// dialog, it can present StoreKit's sheet without the presentation race
    /// described on the dialog itself.
    @ViewBuilder
    private var activeSubscriptionDeletionWarning: some View {
        if entitlements.isPremium {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Deleting your account won't cancel Sustain+. Billing continues through Apple until you cancel it there.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "creditcard.trianglebadge.exclamationmark")
                        .foregroundStyle(Theme.warning)
                }

                Button("Manage subscription") { showingManageSubscriptions = true }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .tint(Theme.primary)
            }
            .padding(.top, 14)
        }
    }

    private func handleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            // ASAuthorizationError.canceled fires every time the user simply
            // dismisses Apple's sheet without choosing an account — that's
            // not a failure worth surfacing as an error alert, just a no-op.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
        case .success(let authorization):
            isLinkingAccount = true
            Task {
                do {
                    try await auth.completeAppleSignIn(authorization: authorization)
                    // Shared with `MandatorySignInView` — see
                    // `CloudSyncManager.resolveAfterSignIn`'s doc comment.
                    // Silently merges any local data on this device into
                    // whichever account just signed in; nothing further to
                    // handle here.
                    try await syncManager.resolveAfterSignIn(context: modelContext)
                } catch {
                    errorMessage = error.localizedDescription
                }
                isLinkingAccount = false
            }
        }
    }

    /// See `MandatorySignInView.handleGoogleSignIn` — same flow, and the same
    /// reason `-5` (Google's user-cancelled code) is swallowed rather than
    /// shown as an error.
    private func handleGoogleSignIn() {
        isLinkingAccount = true
        Task {
            do {
                try await auth.completeGoogleSignIn()
                try await syncManager.resolveAfterSignIn(context: modelContext)
            } catch {
                if (error as NSError).code != -5 {
                    errorMessage = error.localizedDescription
                }
            }
            isLinkingAccount = false
        }
    }

    private func loadLinkedIdentities() async {
        isLoadingIdentities = true
        defer { isLoadingIdentities = false }
        do {
            linkedIdentities = try await auth.fetchLinkedIdentities()
        } catch {
            // Quiet failure on load — the list just stays empty/stale and
            // the buttons still work on next attempt; a red "sign-in methods"
            // banner on every Settings visit for a transient network blip
            // would be worse than just not showing the list yet.
        }
    }

    private func linkGoogleIdentity() {
        isManagingIdentity = true
        clearIdentityError()
        Task {
            do {
                try await auth.linkGoogleIdentity()
                await loadLinkedIdentities()
            } catch {
                // Same cancel code as `handleGoogleSignIn` — dismissing
                // Google's sheet isn't an error worth surfacing.
                if (error as NSError).code != -5 {
                    showIdentityError(error)
                }
            }
            isManagingIdentity = false
        }
    }

    private func clearIdentityError() {
        identityErrorMessage = nil
        identityErrorGuidance = nil
    }

    /// Splits an `AuthError` into its headline and its follow-up instructions,
    /// so the one recoverable failure (`identityAlreadyLinked`) can explain the
    /// way out instead of dead-ending.
    private func showIdentityError(_ error: Error) {
        identityErrorMessage = error.localizedDescription
        identityErrorGuidance = (error as? AuthError)?.identityAlreadyLinkedGuidance
    }

    private func handleLinkAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            showIdentityError(error)
        case .success(let authorization):
            isManagingIdentity = true
            // Cleared here as well as in the other two identity actions, so a
            // previous failure's red text doesn't linger under a link that has
            // since succeeded.
            clearIdentityError()
            Task {
                do {
                    try await auth.linkAppleIdentity(authorization: authorization)
                    await loadLinkedIdentities()
                } catch {
                    showIdentityError(error)
                }
                isManagingIdentity = false
            }
        }
    }

    private func removeIdentity(_ provider: SignInProvider) {
        guard let identity = linkedIdentities.first(where: { $0.provider == provider }) else { return }
        isManagingIdentity = true
        clearIdentityError()
        Task {
            do {
                try await auth.unlinkIdentity(identity)
                await loadLinkedIdentities()
            } catch {
                showIdentityError(error)
            }
            isManagingIdentity = false
        }
    }

    private func syncNow() {
        Task {
            do {
                try await syncManager.syncNow(context: modelContext)
            } catch {
                // syncManager.lastSyncError already surfaces this inline;
                // avoid a redundant alert for a background-style action the
                // user can just retry with another tap of "Sync now."
            }
        }
    }

    /// Pushes any unsynced local changes to the cloud first, and only then
    /// clears this device's copy and actually signs out — in that specific
    /// order, so a failed push (offline, server error) leaves the person
    /// still signed in with their local data intact rather than losing
    /// whatever hadn't made it to the cloud yet. See the confirmation
    /// dialog's header comment for the full reasoning behind always wiping
    /// local data on sign-out in the first place.
    private func performSignOut() {
        isSigningOut = true
        Task {
            do {
                try await syncManager.syncNow(context: modelContext)
                try syncManager.eraseLocalData(context: modelContext)
                auth.signOut()
            } catch {
                errorMessage = "Couldn't back up your latest data before signing out: \(error.localizedDescription). Check your connection and try again."
            }
            isSigningOut = false
        }
    }

    /// Deletes the account from the cloud, then unconditionally erases this
    /// device's copy too — no separate "keep local data" option anymore
    /// (see this file's `.confirmationDialog` header comment for why that
    /// changed). Erasing local data only after the cloud deletion succeeds
    /// means a failed cloud deletion never leaves someone with neither copy.
    /// Unlike sign-out, there's no "sync first" step needed here: deleting
    /// the account is already a deliberate, consented destruction of the
    /// cloud copy, so there's nothing to protect by pushing local changes up
    /// to an account that's about to be deleted anyway.
    private func performDeleteAccount() {
        isDeletingAccount = true
        Task {
            do {
                try await auth.deleteAccount()
                try syncManager.eraseLocalData(context: modelContext)
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeletingAccount = false
        }
    }
}

#Preview {
    Form {
        AccountSectionView()
    }
    .modelContainer(for: [
        MedicationProfile.self, DoseLog.self, WeightEntry.self, ProteinEntry.self, SideEffectLog.self,
    ], inMemory: true)
}
