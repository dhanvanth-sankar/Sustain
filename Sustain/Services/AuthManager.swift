import AuthenticationServices
import CryptoKit
import Foundation
import GoogleSignIn
import RevenueCat
import UIKit

/// Which login button someone actually used. Tracked (in `UserDefaults`) purely
/// so a second, different provider can be recognized as creating a *separate*
/// account rather than signing back into the existing one — see
/// `duplicateAccountWarning`.
enum SignInProvider: String, CaseIterable {
    case apple
    case google

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .google: return "Google"
        }
    }
}

enum AuthError: LocalizedError {
    case missingConfig
    case missingIdentityToken
    case missingGoogleConfig
    case missingGoogleToken
    case noPresenter
    case requestFailed(String)
    case notSignedIn
    /// Supabase `identity_already_exists` (HTTP 422). Raised when linking a
    /// provider whose identity is already attached to a *different* Supabase
    /// user. Supabase deliberately refuses this rather than merging the two
    /// accounts, since merging would mean silently deciding what happens to
    /// the other account's data. Reported from a real device on 2026-08-01:
    /// signing into a brand-new Google account and then trying to link an
    /// already-existing Apple account. See `identityAlreadyLinkedGuidance`.
    case identityAlreadyLinked
    /// Supabase `single_identity_not_deletable`. Every account must keep at
    /// least one way back in.
    case lastIdentityNotRemovable
    /// Supabase `manual_linking_disabled` — the project-level toggle this
    /// whole feature depends on (see `AuthManager`'s header comment).
    case linkingUnavailable

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Account sync isn't set up yet. Add SUPABASE_PROJECT_URL to Secrets.xcconfig."
        case .missingIdentityToken:
            return "Apple didn't return a sign-in token. Try again."
        case .missingGoogleConfig:
            return "Google sign-in isn't set up yet. Add GOOGLE_CLIENT_ID to Secrets.xcconfig."
        case .missingGoogleToken:
            return "Google didn't return a sign-in token. Try again."
        case .noPresenter:
            return "Couldn't open the Google sign-in screen. Try again."
        case .requestFailed(let message):
            return message
        case .notSignedIn:
            return "You're not signed in."
        case .identityAlreadyLinked:
            return "That sign-in method already belongs to a different Sustain account, and accounts can't be combined."
        case .lastIdentityNotRemovable:
            return "This is the only way to sign in to your account, so it can't be removed. Link another method first."
        case .linkingUnavailable:
            return "Linking sign-in methods isn't available right now. Try again later."
        }
    }

    /// The second half of the `identityAlreadyLinked` message: what to
    /// actually *do* about it. Kept separate from `errorDescription` so the UI
    /// can give it its own, calmer styling rather than one long red block, and
    /// so it isn't repeated in contexts where only the headline matters.
    ///
    /// The advice is deliberately specific, because the situation is a dead
    /// end otherwise: once two accounts exist, neither can link to the other
    /// (each one's identity belongs to the other account), so the *only* way
    /// to end up with both methods on one account is to delete one account
    /// first, freeing its sign-in method up to be linked.
    var identityAlreadyLinkedGuidance: String? {
        guard case .identityAlreadyLinked = self else { return nil }
        return "To use both methods on one account, first delete the account you don't want to keep, from that account's own Settings. Its sign-in method is then free to link to the account you're keeping."
    }
}

/// A signed-in Supabase session. Deliberately holds only what's needed to
/// authenticate future requests and identify the account — no profile data,
/// which stays in SwiftData/Postgres, not here.
struct SupabaseSession: Codable {
    let accessToken: String
    let refreshToken: String
    let userId: UUID
    /// The Apple ID email Supabase resolved from the identity token, if any —
    /// added 2026-08-01 so Settings can show "Signed in as ___" rather than
    /// just "Signed in." Deliberately read from Supabase's own token response
    /// (`user.email`), not `ASAuthorizationAppleIDCredential.email` directly:
    /// Apple only returns `credential.email` on the very first authorization
    /// a person ever grants this app, and is nil on every sign-in after
    /// that, which would make this field disappear after a sign-out/back-in.
    /// Apple's identity token itself always carries the resolved address (a
    /// private relay one if the person chose "Hide My Email"), and Supabase
    /// decodes that into its own user object on every token response, so
    /// reading it from there is available consistently, not just once. Can
    /// still legitimately be `nil` (a malformed/old response, or a Supabase
    /// configuration that doesn't surface it) — the UI falls back to plain
    /// "Signed in" in that case rather than assuming this is always present.
    let email: String?
    /// Absolute expiry, computed once at sign-in/refresh time from Supabase's
    /// `expires_in` (seconds-from-now) rather than storing the relative
    /// duration — storing a duration and forgetting to anchor it to when the
    /// token was actually issued is a classic way to end up with a token that
    /// silently reads as "still valid" long after it has actually expired.
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case userId = "user_id"
        case email
        case expiresAt = "expires_at"
    }
}

/// Owns Sign in with Apple, Continue with Google, and the resulting Supabase
/// Auth session. Both providers land on the same Supabase `id_token` grant —
/// see `exchangeIDToken(...)`, which is the shared tail of both flows.
///
/// **Guideline 4.8 (Login Services) — the reasoning changed on 2026-08-01 and
/// the old version of this comment is no longer correct.** It used to argue
/// that offering Apple as the *only* login method sidestepped 4.8 entirely,
/// since there was no third-party login to be at parity with. Adding Google
/// makes 4.8 genuinely apply: Google is exactly the kind of third-party/social
/// login the guideline is about. It is satisfied — but by a different
/// mechanism than before. Sign in with Apple *is* the required
/// privacy-preserving equivalent, and it must remain offered, and displayed at
/// least as prominently as Google, for this app to stay compliant. See
/// `GoogleSignInButton`'s doc comment for the placement rule this imposes on
/// every screen showing both.
///
/// Neither provider involves passwords, so the app still has zero
/// email-deliverability failure modes (no password reset, no verification
/// email) — which is precisely why Google was chosen over building
/// email/password when a second option was wanted. Apple's half still needs no
/// third-party SPM dependency (`AuthenticationServices` and `CryptoKit` are
/// first-party); Google's requires `GoogleSignIn-iOS`, a deliberate exception
/// to `PROJECT_HANDOFF.md` Decision 2's zero-third-party-SPM posture, taken
/// because the alternative (email/password) needed a production SMTP provider
/// and deep-link infrastructure instead.
///
/// Talks to Supabase Auth over plain REST (`/auth/v1/token`), the same
/// "no SDK, just URLSession + the anon key" pattern `AIProteinEstimator`
/// already established for the AI proxy — deliberate consistency, not an
/// oversight; a Supabase Swift SDK exists but would be this app's first real
/// SPM dependency beyond RevenueCat, for functionality a ~150-line REST
/// wrapper covers completely.
///
/// Also owns identifying the signed-in account to RevenueCat (see
/// `identifyRevenueCat(userId:)`), so `EntitlementManager`'s subscription
/// status is tied to this Supabase account rather than only to the App
/// Store purchasing Apple ID — added 2026-08-01, see `PROJECT_HANDOFF.md`
/// §17 item 10.
///
/// **Identity linking, added 2026-08-01 in response to the account-
/// fragmentation problem `duplicateAccountWarning` only reacts to after the
/// fact.** Researched how other apps (and Supabase's own docs) handle
/// "someone used Apple with Hide My Email, then later tapped Continue with
/// Google" — the two identities are genuinely uncorrelated, so nothing
/// server-side can safely auto-merge them. The real fix other apps converge
/// on is proactive, in-account linking: while already signed in, offer a
/// button to attach the *other* provider to this same account, so either one
/// signs back into it from then on. Supabase supports exactly this via its
/// native "link identity with ID token" flow — the same
/// `/auth/v1/token?grant_type=id_token` endpoint `exchangeIDToken` already
/// calls, just with the caller's current access token attached as a Bearer
/// header and `link_identity: true` in the body. See
/// `linkGoogleIdentity()`/`linkAppleIdentity(authorization:)`,
/// `fetchLinkedIdentities()`, and `unlinkIdentity(_:)`, surfaced as a
/// "Sign-in methods" list in `AccountSectionView`.
///
/// **This requires "manual linking" to be turned on for the Supabase
/// project** (Authentication → Sign In / Providers, or
/// `GOTRUE_SECURITY_MANUAL_LINKING_ENABLED: true` self-hosted) — without it,
/// the endpoint rejects `link_identity: true` outright, the same kind of
/// dashboard-side prerequisite as the Google provider's "Skip nonce check"
/// toggle. `duplicateAccountWarning` is kept as a fallback for whoever
/// doesn't link proactively (or signed in before this existed) — it isn't
/// made redundant by this, just less often needed.
@Observable
final class AuthManager: NSObject {
    static let shared = AuthManager()

    private(set) var session: SupabaseSession?
    private(set) var isRestoringSession = true

    /// Set to the *previous* provider when a sign-in has just created a brand-new,
    /// empty account on a device that had previously signed in with a different
    /// provider — i.e. the account-fragmentation case. Sustain can't prevent this
    /// (Apple's Hide My Email relay address and a Gmail address are genuinely
    /// different identities, and Supabase has no way to know they're the same
    /// person), but silently dropping someone into an empty account with no
    /// history and no subscription is the worst possible handling. The UI reads
    /// this and explains what happened, offering a way back. See
    /// `DuplicateAccountWarningView`.
    private(set) var duplicateAccountWarning: SignInProvider?

    private var currentNonce: String?

    // Added 2026-08-06 capturing iPad marketing screenshots: `MandatorySignInView`
    // is a genuine, no-skip gate (see its own header comment) that blocks a
    // brand-new Simulator instance before it ever reaches `ScreenshotModeSeeder`
    // or `MainTabView` — real Sign in with Apple/Google credentials aren't
    // something a screenshot session should ever enter. Same posture as
    // `EntitlementManager.isPremium`'s override: entirely inert unless
    // `SCREENSHOT_MODE` is manually set in Debug, never defined for Release, so
    // this can never let a real archived build skip sign-in.
    #if SCREENSHOT_MODE
    var isSignedIn: Bool { true }
    #else
    var isSignedIn: Bool { session != nil }
    #endif

    private static let sessionKey = "supabaseSession"
    /// Plain `UserDefaults`, not the Keychain, deliberately: this is a UX hint,
    /// not a credential, and it *should* be forgotten by a real uninstall along
    /// with everything else (see `restoreSession()` on why that distinction
    /// matters here).
    private static let lastProviderKey = "authManagerLastSignInProvider"
    /// A plain `UserDefaults` marker, deliberately not stored in the Keychain
    /// — see `restoreSession()` below for why the difference between where
    /// these two things live is exactly the point.
    private static let hasLaunchedBeforeKey = "authManagerHasLaunchedBefore"

    private override init() {
        super.init()
        restoreSession()
    }

    /// Real bug, reported directly: "right after I install the app and open
    /// it, it doesn't ask for sign in — it goes right to the dashboard."
    /// Root cause: Keychain items are tied to the *device*, not an app's
    /// install lifecycle — deleting the app and reinstalling it does not
    /// clear the Keychain (this is deliberate, standard iOS behavior, not a
    /// bug in this app's own Keychain usage), so a session persisted from an
    /// earlier install/build silently comes back on the very next launch,
    /// even though `UserDefaults` (`hasCompletedOnboarding`, etc.) and the
    /// SwiftData store both *did* get wiped by the reinstall. The mandatory
    /// sign-in gate's entire point is "you can't use this app without a
    /// real, current sign-in" — silently honoring a session left over from
    /// before a reinstall defeats that.
    ///
    /// Fixed using `hasLaunchedBeforeKey`, a plain `UserDefaults` flag —
    /// UserDefaults, unlike the Keychain, genuinely does get cleared by a
    /// real uninstall. Its absence at launch means either a genuinely
    /// first-ever launch, or a fresh reinstall after a full delete; either
    /// way, any session sitting in the Keychain from before that point is
    /// stale and gets discarded before it's ever read, rather than silently
    /// signing someone back in. Ordinary launches (the app was never
    /// deleted) leave this flag set, so a real, still-current session keeps
    /// restoring normally across restarts, exactly as before.
    private func restoreSession() {
        defer { isRestoringSession = false }

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.hasLaunchedBeforeKey) {
            KeychainHelper.removeValue(forKey: Self.sessionKey)
            defaults.set(true, forKey: Self.hasLaunchedBeforeKey)
        }

        guard let data = KeychainHelper.data(forKey: Self.sessionKey),
              let restored = try? SupabaseConfig.decoder.decode(SupabaseSession.self, from: data) else {
            return
        }
        session = restored
        // Re-identify with RevenueCat on every cold launch, not just at the
        // moment of sign-in — see `identifyRevenueCat(userId:)`'s doc comment.
        // This matters most right after a reinstall: the Keychain session
        // survives (see this method's header comment on Keychain/device
        // lifetime), but RevenueCat's own on-device cache of "who is the
        // current App User ID" does not, so without this call a reinstalled
        // app would silently fall back to an anonymous RevenueCat identity
        // even though Sustain still considers the person signed in.
        Self.identifyRevenueCat(userId: restored.userId)
    }

    private func persist(_ session: SupabaseSession?) {
        self.session = session
        guard let session, let data = try? SupabaseConfig.encoder.encode(session) else {
            KeychainHelper.removeValue(forKey: Self.sessionKey)
            return
        }
        KeychainHelper.set(data, forKey: Self.sessionKey)
    }

    // MARK: - Sign in with Apple

    /// Call this to configure the `ASAuthorizationAppleIDRequest` before
    /// presenting it — the raw nonce generated here must be hashed into the
    /// request and the *raw* (unhashed) version sent to Supabase afterward,
    /// so Supabase can verify Apple's signed token was actually issued for
    /// this specific sign-in attempt and not replayed from another one.
    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Completes the flow after `ASAuthorizationController` hands back a
    /// credential: exchanges Apple's identity token (plus the raw nonce) for
    /// a Supabase session via the `id_token` grant.
    func completeAppleSignIn(authorization: ASAuthorization) async throws {
        guard let config = SupabaseConfig.shared else { throw AuthError.missingConfig }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.missingIdentityToken
        }
        let nonce = currentNonce
        currentNonce = nil

        // `credential.email` is passed as a fallback, not the primary source
        // (see `SupabaseSession.email`'s doc comment) — belt-and-suspenders
        // for the one case it's actually the more reliable of the two: a
        // Supabase project whose Apple provider config doesn't surface email
        // into the returned user object at all.
        try await exchangeIDToken(
            provider: .apple,
            idToken: identityToken,
            accessToken: nil,
            nonce: nonce,
            fallbackEmail: credential.email,
            config: config
        )
    }

    /// The Google equivalent of `completeAppleSignIn`, added 2026-08-01.
    ///
    /// Deliberately lands on the *same* `/auth/v1/token?grant_type=id_token`
    /// endpoint as Apple: Google's SDK hands back an OIDC ID token, which is
    /// exactly what that grant consumes, so adding a second provider needed a
    /// second token *source* rather than a second auth stack. This is the
    /// reason Google was chosen over building email/password, which would have
    /// required a production SMTP provider, deep links for verification and
    /// password-reset links, and four new screens.
    ///
    /// **No nonce is sent here, unlike Apple — this is required, not an
    /// oversight.** `GoogleSignIn-iOS` does not attach a nonce the way
    /// `ASAuthorizationAppleIDRequest` does, and Supabase rejects the token if
    /// it expects a nonce and finds none. Supabase's own Swift guidance is to
    /// turn ON "Skip nonce check" for the Google provider in the dashboard;
    /// that setting and this omission go together. If Google sign-in ever
    /// starts failing with a 400 from the token endpoint while Apple keeps
    /// working, that dashboard toggle is the first thing to check.
    @MainActor
    func completeGoogleSignIn() async throws {
        guard let config = SupabaseConfig.shared else { throw AuthError.missingConfig }
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String,
              !clientID.isEmpty,
              !clientID.hasPrefix("your-") else {
            throw AuthError.missingGoogleConfig
        }
        guard let presenter = Self.topViewController() else { throw AuthError.noPresenter }

        // The *web* client ID, passed as the server client ID, so the ID token
        // Google mints carries an audience Supabase will accept. Optional here
        // only because a project can be configured with just the iOS client in
        // simple setups; Supabase's docs recommend registering both.
        let serverClientID = (Bundle.main.object(forInfoDictionaryKey: "GoogleServerClientID") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("your-") ? nil : $0 }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: clientID,
            serverClientID: serverClientID
        )

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.missingGoogleToken
        }

        try await exchangeIDToken(
            provider: .google,
            idToken: idToken,
            accessToken: result.user.accessToken.tokenString,
            nonce: nil,
            fallbackEmail: result.user.profile?.email,
            config: config
        )
    }

    /// Shared tail of both sign-in flows: trade a provider ID token for a
    /// Supabase session, persist it, tell RevenueCat who this is, and work out
    /// whether this just created a duplicate account.
    ///
    /// `linkToCurrentSession` is the one thing that turns this from "sign in
    /// (possibly creating a new account)" into "attach this provider to the
    /// account I'm *already* signed into" — see `linkGoogleIdentity()` /
    /// `linkAppleIdentity(authorization:)`. It changes exactly two things
    /// about the request/response handling, both required by Supabase's
    /// native ID-token linking flow: the caller's current access token rides
    /// along as a Bearer header (without it, GoTrue has no way to know which
    /// existing account to attach the new identity to), and the response is
    /// never treated as a fresh sign-in — no duplicate-account bookkeeping,
    /// and `lastProviderKey` is left alone so a later ordinary sign-in with
    /// the *other* now-linked provider still isn't mistaken for a switch.
    private func exchangeIDToken(
        provider: SignInProvider,
        idToken: String,
        accessToken: String?,
        nonce: String?,
        fallbackEmail: String?,
        // Deliberately the tuple type, not `SupabaseConfig`: that type is an
        // `enum` used purely as a namespace, and `SupabaseConfig.shared` is an
        // optional *tuple* of `(projectURL:anonKey:)` rather than an instance
        // of the enum. Writing `config: SupabaseConfig` here compiles nowhere —
        // it was a real build error on first compile.
        config: (projectURL: URL, anonKey: String),
        linkToCurrentSession: Bool = false
    ) async throws {
        var body: [String: Any] = ["provider": provider.rawValue, "id_token": idToken]
        if let nonce { body["nonce"] = nonce }
        // Supabase's Swift guidance passes Google's access token alongside the
        // ID token; Apple's flow has no equivalent and omits it.
        if let accessToken { body["access_token"] = accessToken }
        if linkToCurrentSession {
            // The exact field Supabase's native-linking flow looks for on
            // this same grant — see the class header comment.
            body["link_identity"] = true
        }

        let url = config.projectURL.appendingPathComponent("auth/v1/token").appendingQueryItem("grant_type", "id_token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if linkToCurrentSession {
            // Refresh *before* reading the access token, not after: Supabase's
            // access tokens are short-lived (1 hour by default), and Settings
            // is very often opened long after sign-in. Without this, linking
            // would fail with a 401 for anyone who'd been signed in more than
            // an hour, which is the common case rather than an edge case.
            try await refreshSessionIfNeeded()
            guard let current = session else { throw AuthError.notSignedIn }
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertSuccess(response, data: data)
        let parsed = try Self.parseTokenResponse(data, fallbackEmail: fallbackEmail)
        persist(parsed.session)

        if !linkToCurrentSession {
            // Only warn when this sign-in genuinely *created* an account AND
            // the device has previously used a different provider. Signing
            // back into an existing account with either provider is silent,
            // as it should be. Linking never reaches this branch at all —
            // attaching a second provider to an already-signed-in account is
            // never "new," by definition.
            let defaults = UserDefaults.standard
            let previous = (defaults.string(forKey: Self.lastProviderKey)).flatMap(SignInProvider.init(rawValue:))
            duplicateAccountWarning = (parsed.isNewAccount && previous != nil && previous != provider) ? previous : nil
            defaults.set(provider.rawValue, forKey: Self.lastProviderKey)
        }

        // Link this Supabase account to RevenueCat's subscriber identity, so
        // a subscription bought on one device is recognized on any other
        // device where this same Sustain account signs in, instead of only
        // following the App Store purchasing Apple ID. See
        // `identifyRevenueCat(userId:)`'s doc comment and `PROJECT_HANDOFF.md`
        // §17 item 10 for the full rationale. Covers both a first-ever
        // sign-in (anonymous → this ID) and someone switching to a
        // *different* Sustain account on a device that was previously signed
        // into another one — RevenueCat's `logIn()` handles both cases
        // without needing `logOut()` first. Harmless to repeat when linking:
        // `parsed.session.userId` is unchanged from before the link.
        Self.identifyRevenueCat(userId: parsed.session.userId)
    }

    func dismissDuplicateAccountWarning() {
        duplicateAccountWarning = nil
    }

    // MARK: - Identity linking

    /// A single sign-in method currently attached to the signed-in account,
    /// as returned by `/auth/v1/user`. `identityId` (Supabase's
    /// `identity_id`, distinct from the account's own `userId`) is what
    /// `unlinkIdentity(_:)` needs to remove it again.
    struct LinkedIdentity: Identifiable, Equatable {
        let identityId: String
        let provider: SignInProvider

        var id: String { identityId }
    }

    /// Attaches Google as an additional sign-in method for the *currently
    /// signed-in* account, rather than creating or switching to a different
    /// one. This is the proactive fix for the fragmentation problem —
    /// someone who links from Settings never hits `duplicateAccountWarning`
    /// at all, because Supabase attaches the Google identity to their
    /// existing user row instead of minting a new one. See the class header
    /// comment for the required Supabase dashboard prerequisite.
    @MainActor
    func linkGoogleIdentity() async throws {
        guard session != nil else { throw AuthError.notSignedIn }
        guard let config = SupabaseConfig.shared else { throw AuthError.missingConfig }
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String,
              !clientID.isEmpty,
              !clientID.hasPrefix("your-") else {
            throw AuthError.missingGoogleConfig
        }
        guard let presenter = Self.topViewController() else { throw AuthError.noPresenter }

        let serverClientID = (Bundle.main.object(forInfoDictionaryKey: "GoogleServerClientID") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("your-") ? nil : $0 }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: clientID,
            serverClientID: serverClientID
        )

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.missingGoogleToken
        }

        try await exchangeIDToken(
            provider: .google,
            idToken: idToken,
            accessToken: result.user.accessToken.tokenString,
            nonce: nil,
            fallbackEmail: result.user.profile?.email,
            config: config,
            linkToCurrentSession: true
        )
    }

    /// The Apple equivalent of `linkGoogleIdentity()`. Called from the same
    /// `ASAuthorizationController` completion path as `completeAppleSignIn` —
    /// the call site (`AccountSectionView`) decides which of the two a given
    /// button press means, since the credential itself looks identical either
    /// way.
    func linkAppleIdentity(authorization: ASAuthorization) async throws {
        guard session != nil else { throw AuthError.notSignedIn }
        guard let config = SupabaseConfig.shared else { throw AuthError.missingConfig }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.missingIdentityToken
        }
        let nonce = currentNonce
        currentNonce = nil

        try await exchangeIDToken(
            provider: .apple,
            idToken: identityToken,
            accessToken: nil,
            nonce: nonce,
            fallbackEmail: credential.email,
            config: config,
            linkToCurrentSession: true
        )
    }

    /// Which providers are currently linked to the signed-in account, for the
    /// "Sign-in methods" list in Settings. A fresh `GET /auth/v1/user` rather
    /// than anything cached on `SupabaseSession` — linking/unlinking can
    /// happen from that same screen, so Supabase's own current state is the
    /// only source of truth worth trusting.
    func fetchLinkedIdentities() async throws -> [LinkedIdentity] {
        // Same short-lived-token reasoning as the linking path in
        // `exchangeIDToken` — without this, opening Settings more than an hour
        // after signing in would 401 and silently render an empty list, which
        // reads as "nothing is linked" and offers to link a provider that
        // already is.
        try await refreshSessionIfNeeded()
        guard let session else { throw AuthError.notSignedIn }
        guard let config = SupabaseConfig.shared else { throw AuthError.missingConfig }

        let url = config.projectURL.appendingPathComponent("auth/v1/user")
        var request = URLRequest(url: url)
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertSuccess(response, data: data)

        struct UserPayload: Decodable {
            struct Identity: Decodable {
                let identityId: String
                let provider: String

                enum CodingKeys: String, CodingKey {
                    case identityId = "identity_id"
                    case provider
                }
            }
            let identities: [Identity]?
        }
        let decoded = try JSONDecoder().decode(UserPayload.self, from: data)
        return (decoded.identities ?? []).compactMap { identity in
            SignInProvider(rawValue: identity.provider).map {
                LinkedIdentity(identityId: identity.identityId, provider: $0)
            }
        }
    }

    /// Removes a linked sign-in method. Supabase itself refuses to unlink the
    /// last remaining identity on an account — every account must always keep
    /// at least one way back in — and returns an error in that case; this
    /// method doesn't duplicate that guard client-side, so whatever error
    /// surfaces here is Supabase's own, not a guess at its rules.
    func unlinkIdentity(_ identity: LinkedIdentity) async throws {
        try await refreshSessionIfNeeded()
        guard let session else { throw AuthError.notSignedIn }
        guard let config = SupabaseConfig.shared else { throw AuthError.missingConfig }

        let url = config.projectURL.appendingPathComponent("auth/v1/user/identities/\(identity.identityId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertSuccess(response, data: data)
    }

    /// Google's SDK needs a `UIViewController` to present from. Walks down from
    /// the key window's root through whatever is currently presented, so this
    /// still works when sign-in is triggered from inside a sheet (the Settings
    /// path) rather than the root gate.
    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }

        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - Session maintenance

    /// Refreshes the access token if it's expired or about to be (a 60s
    /// buffer, so a sync operation that takes a few seconds doesn't start
    /// with a token that expires mid-request). Every sync call in
    /// `CloudSyncManager` calls this first rather than assuming the stored
    /// token is still good — access tokens are short-lived by design
    /// (Supabase defaults to 1 hour), so this isn't an edge case, it's the
    /// normal path for anyone who opens the app more than an hour after
    /// their last sync.
    func refreshSessionIfNeeded() async throws {
        guard let session else { throw AuthError.notSignedIn }
        guard session.expiresAt.timeIntervalSinceNow < 60 else { return }
        guard let config = SupabaseConfig.shared else { throw AuthError.missingConfig }

        let url = config.projectURL.appendingPathComponent("auth/v1/token").appendingQueryItem("grant_type", "refresh_token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertSuccess(response, data: data)
        // Carry the previous session's email forward as a fallback if this
        // refresh response's `user` object doesn't happen to include one —
        // a refresh should never make a previously-known email vanish from
        // "Signed in as ___" just because that field wasn't repeated on this
        // particular response. The `isNewAccount` half of the result is
        // ignored here by design: a token refresh never creates an account,
        // and `created_at` on this response is the original signup date.
        persist(try Self.parseTokenResponse(data, fallbackEmail: session.email).session)
    }

    /// Local sign-out only (clears the stored session) — deliberately does
    /// NOT also call Supabase's `/auth/v1/logout` to revoke the refresh
    /// token server-side, since a network failure mid-signout would leave
    /// the user in a confusing half-signed-out state on the one device while
    /// still fully signed in on Supabase's side. This app has no concept of
    /// "signed in on this device but I want other devices logged out," so
    /// there's no real cost to leaving the refresh token technically valid
    /// server-side after a local sign-out — the next sign-in on this device
    /// gets a fresh token anyway.
    ///
    /// Deliberately does NOT call `Purchases.shared.logOut()` either, per
    /// RevenueCat's own guidance for apps using custom App User IDs: calling
    /// `logOut()` resets RevenueCat back to a fresh anonymous identity, which
    /// is only useful if you want a clean slate. Sustain doesn't — sign-out
    /// here always leads back to the mandatory sign-in screen, and whoever
    /// signs in next (the same person again, or someone else on a shared
    /// device) gets correctly identified by the next `identifyRevenueCat`
    /// call in `completeAppleSignIn`, which RevenueCat's docs confirm works
    /// fine as a direct account switch without an intervening `logOut()`.
    func signOut() {
        persist(nil)
    }

    /// Permanently deletes the account and all of its cloud data — required
    /// by Guideline 5.1.1(v): any app that offers account creation must also
    /// let the user initiate deletion of that account from within the app,
    /// not just direct them to a website or support email. Calls the
    /// `delete-account` Edge Function (see `supabase/functions/
    /// delete-account/index.ts`) rather than a direct Admin API call, since
    /// deleting an `auth.users` row requires Supabase's service-role key,
    /// which — like the Anthropic key `anthropic-proxy` already keeps
    /// server-side — must never ship inside the app binary.
    func deleteAccount() async throws {
        guard let session else { throw AuthError.notSignedIn }
        guard let config = SupabaseConfig.shared,
              let functionURLString = Bundle.main.object(forInfoDictionaryKey: "SupabaseFunctionURL") as? String,
              let functionsBase = URL(string: functionURLString)?.deletingLastPathComponent() else {
            throw AuthError.missingConfig
        }
        let url = functionsBase.appendingPathComponent("delete-account")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertSuccess(response, data: data)
        persist(nil)
    }

    // MARK: - Parsing / shared helpers

    private static func parseTokenResponse(
        _ data: Data,
        fallbackEmail: String? = nil
    ) throws -> (session: SupabaseSession, isNewAccount: Bool) {
        struct TokenResponse: Decodable {
            struct UserPayload: Decodable {
                let id: String
                let email: String?
                /// Supabase returns this on the user object for both sign-up and
                /// sign-in; comparing it to "now" is the only signal available
                /// client-side for "did this call just create the account?"
                let createdAt: String?

                enum CodingKeys: String, CodingKey {
                    case id, email
                    case createdAt = "created_at"
                }
            }
            let accessToken: String
            let refreshToken: String
            let expiresIn: Double
            let user: UserPayload

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case user
            }
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
              let userId = UUID(uuidString: decoded.user.id) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown response"
            throw AuthError.requestFailed("Couldn't read the sign-in response: \(bodyText)")
        }

        let session = SupabaseSession(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            userId: userId,
            email: decoded.user.email ?? fallbackEmail,
            expiresAt: Date().addingTimeInterval(decoded.expiresIn)
        )

        // A generous window (2 minutes) rather than a tight one: this only
        // drives an explanatory message, so a false negative (staying quiet)
        // is far preferable to a false positive (telling a long-standing user
        // their account is brand new). Anything unparseable reads as "not new."
        let isNewAccount = decoded.user.createdAt
            .flatMap(Self.parseTimestamp)
            .map { abs($0.timeIntervalSinceNow) < 120 } ?? false

        return (session, isNewAccount)
    }

    /// Supabase timestamps sometimes carry fractional seconds and sometimes
    /// don't, and `ISO8601DateFormatter` will not parse both with one
    /// configuration — so try each rather than guessing.
    private static func parseTimestamp(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// Links this Supabase account to RevenueCat's subscriber identity, using
    /// the Supabase user's UUID as RevenueCat's "App User ID" — a stable,
    /// non-guessable, non-email identifier, exactly what RevenueCat's own
    /// "Tips for Setting Custom App User IDs" guidance recommends. Without
    /// this call, `EntitlementManager`/`Purchases.shared` falls back to
    /// RevenueCat's default anonymous identity, which is derived from the
    /// on-device App Store purchase receipt rather than the signed-in
    /// Sustain account — meaning a subscription wouldn't reliably follow a
    /// user across devices/reinstalls the way the rest of their data
    /// (dose/weight/protein logs, via `CloudSyncManager`) now does since the
    /// 2.0 mandatory-account release. Added 2026-08-01; see
    /// `PROJECT_HANDOFF.md` §17 item 10 for the researched rationale
    /// (RevenueCat's docs, and the real-world MyFitnessPal confusion this
    /// avoids).
    ///
    /// Fire-and-forget on purpose: this only needs to succeed *eventually*
    /// (RevenueCat retries/caches internally, and the SDK will pick the
    /// right identity up on its next network call regardless), so a
    /// transient failure here (e.g. offline at the exact moment of sign-in)
    /// isn't treated as a sign-in error — the person is still correctly
    /// signed into Sustain either way, and `EntitlementManager`'s existing
    /// `restorePurchases()` remains available from Settings as a manual
    /// fallback if this silently didn't take effect.
    private static func identifyRevenueCat(userId: UUID) {
        // `Purchases.shared` traps (fatalError) if the SDK was never
        // configured, so this guard is load-bearing, not defensive noise.
        // `SustainApp.init()` skips `Purchases.configure` entirely when
        // `RevenueCatAPIKey` is missing from Info.plist, and the
        // `assertionFailure` it uses to flag that is compiled out of Release
        // builds — so in a misconfigured Release build execution really does
        // continue with the SDK unconfigured. Without this check, that
        // formerly-survivable misconfiguration would become a hard crash on
        // launch for every signed-in user, since `restoreSession()` runs
        // this during `AuthManager.shared`'s initialization. Skipping the
        // call is the right failure mode: billing is already non-functional
        // in that build, and crashing the app on top of it helps no one.
        guard Purchases.isConfigured else { return }

        Purchases.shared.logIn(userId.uuidString) { _, _, error in
            if let error {
                // Non-fatal by design — see doc comment above. Debug-only,
                // matching `SustainApp.init()`'s `Purchases.logLevel` gate;
                // never surfaced to the user, and never logged in Release.
                #if DEBUG
                print("AuthManager: RevenueCat logIn failed - \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// **Rewritten 2026-08-01 after a real device report.** This used to throw
    /// `requestFailed("Request failed: \(rawBody)")`, which meant Supabase's
    /// raw JSON was rendered verbatim in the UI — an actual screenshot showed
    /// a user being told
    /// `{"code":422,"error_code":"identity_already_exists","msg":"Identity is
    /// already linked to another user"}`. Every Supabase call in this file
    /// funnels through here, so that was true of every auth failure in the
    /// app, not just linking.
    ///
    /// Now decodes Supabase's error envelope, maps the codes worth handling
    /// specifically to real `AuthError` cases, and falls back to the server's
    /// own human-readable `msg` before ever falling back to something generic.
    /// The raw body is still available in Debug builds for diagnosis.
    private static func assertSuccess(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            #if DEBUG
            print("AuthManager: request failed - \(String(data: data, encoding: .utf8) ?? "no body")")
            #endif
            throw Self.parseError(data: data)
        }
    }

    private static func parseError(data: Data) -> AuthError {
        struct ErrorPayload: Decodable {
            let errorCode: String?
            let msg: String?
            let message: String?
            let error: String?
            let errorDescription: String?

            enum CodingKeys: String, CodingKey {
                case errorCode = "error_code"
                case msg, message, error
                case errorDescription = "error_description"
            }
        }

        let generic = "Something went wrong reaching your account. Check your connection and try again."
        guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) else {
            return .requestFailed(generic)
        }

        switch payload.errorCode {
        case "identity_already_exists":
            return .identityAlreadyLinked
        case "single_identity_not_deletable":
            return .lastIdentityNotRemovable
        case "manual_linking_disabled":
            return .linkingUnavailable
        default:
            break
        }

        // Supabase's own wording is usually already plain English ("Identity is
        // already linked to another user"), so it beats a generic fallback for
        // anything not mapped above.
        let serverMessage = payload.msg ?? payload.message ?? payload.errorDescription ?? payload.error
        return .requestFailed(serverMessage ?? generic)
    }

    /// Cryptographically random nonce for the Sign in with Apple replay-
    /// protection handshake described above. `SecRandomCopyBytes` (not
    /// `Int.random`) because this needs to be unguessable by an attacker
    /// racing to reuse a captured identity token, not just statistically
    /// varied.
    private static func randomNonceString(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            var randomBytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            precondition(status == errSecSuccess, "Unable to generate secure nonce")
            for byte in randomBytes where remainingLength > 0 {
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

private extension URL {
    func appendingQueryItem(_ name: String, _ value: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        components?.queryItems = items
        return components?.url ?? self
    }
}
