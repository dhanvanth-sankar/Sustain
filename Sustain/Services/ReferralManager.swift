import Foundation
import Observation

/// The client half of Sustain's referral program — see
/// `Sustain-In-Product-Growth-Loops-Research-2026-08.md` for the reasoning
/// and `supabase/functions/referrals/index.ts` for the server side this
/// talks to. Follows the exact same "no SDK, plain URLSession + the anon
/// key + the caller's own bearer token" pattern `AuthManager` already
/// established for every other Supabase call in this app, deliberately not
/// a new pattern.
///
/// Requires a signed-in account, which every Sustain user has since the 2.0
/// mandatory-account release — a referral code is tied to a Supabase user
/// row (`referral_codes.user_id`), so there's no separate "referral
/// identity" to design for a signed-out state that no longer exists in this
/// app.
///
/// **Requires the `referrals` Edge Function to be deployed and a RevenueCat
/// secret key configured** before this does anything useful — see that
/// function's header comment for the exact deploy/secrets commands. Every
/// call here fails gracefully (an inline error, never a crash) if that
/// hasn't happened yet, the same "feature silently unavailable until
/// configured" posture `WeeklySummaryGenerator` already has for its own
/// missing-proxy-config case.
@Observable
final class ReferralManager {
    static let shared = ReferralManager()
    private init() {}

    private(set) var code: String?
    private(set) var isLoadingCode = false

    private static let hasRedeemedKey = "referralHasRedeemed"

    /// Whether *this* account has ever successfully redeemed someone else's
    /// code — a person can only ever do this once (enforced server-side by
    /// the `referrals.referred_user_id` unique constraint; this local flag
    /// just lets the UI hide the redemption field without a network round
    /// trip on every appearance).
    var hasRedeemed: Bool {
        UserDefaults.standard.bool(forKey: Self.hasRedeemedKey)
    }

    enum ReferralError: LocalizedError {
        case notSignedIn
        case missingConfig
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in to get your referral code."
            case .missingConfig:
                return "Referrals aren't set up yet."
            case .requestFailed(let message):
                return message
            }
        }
    }

    /// Fetches this account's existing code, or has the server generate one
    /// on first use — see `handleGetOrCreateCode` in the Edge Function for
    /// why code creation lives server-side rather than being generated on
    /// the phone and merely reported to the server (a client-generated code
    /// would need the same server-side uniqueness check anyway, so
    /// generating it there in the first place avoids a wasted round trip on
    /// the common case where a collision doesn't happen).
    @MainActor
    func loadCodeIfNeeded() async {
        guard code == nil, !isLoadingCode else { return }
        isLoadingCode = true
        defer { isLoadingCode = false }
        guard let result = try? await callFunction(action: "code", extra: [:]),
              let fetchedCode = result["code"] as? String else {
            return
        }
        code = fetchedCode
    }

    /// The share text handed to `UIActivityViewController` — centralized
    /// here rather than written inline at the one call site so a second
    /// share entry point (if one's ever added) can't drift on wording.
    /// Deliberately states the reward plainly (a free month, not "credits"
    /// or "points") — see the research doc's §1 on why a legible, literal
    /// reward matches Sustain's existing trust-first positioning better
    /// than an abstracted currency would.
    func shareText(for code: String) -> String {
        "I've been using Sustain to track my GLP-1 dose, weight, and protein, it's genuinely useful. Use my code \(code) when you sign up and we both get a free month of Sustain+: https://hearthlyapps.com/sustain?ref=\(code)"
    }

    @MainActor
    func redeem(code enteredCode: String) async throws {
        let trimmed = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = try await callFunction(action: "redeem", extra: ["code": trimmed])
        if (result["rewarded"] as? Bool) == true {
            UserDefaults.standard.set(true, forKey: Self.hasRedeemedKey)
            // Found in a pre-submission audit: the promotional entitlement
            // is granted server-side (RevenueCat), but nothing told the
            // client to go look for it — RevenueCat's SDK doesn't push an
            // update for a grant it didn't initiate itself, so without this
            // call someone could redeem a code, see "success," and still not
            // see Sustain+ unlock until the next time the SDK happened to
            // refresh on its own (typically the next foreground). Reusing
            // `restorePurchases()` rather than adding a second refresh path —
            // it already does exactly what's needed here (fetch fresh
            // `CustomerInfo` and apply it), even though this isn't literally
            // a restore. Only refreshes the redeemer's own device; the
            // referrer's device picks up their half of the reward on its own
            // next natural refresh, same as any other entitlement change
            // that happens while the app isn't open.
            _ = await EntitlementManager.shared.restorePurchases()
        } else {
            let message = result["error"] as? String ?? "Couldn't redeem that code. Try again."
            throw ReferralError.requestFailed(message)
        }
    }

    private func callFunction(action: String, extra: [String: Any]) async throws -> [String: Any] {
        guard AuthManager.shared.session != nil else { throw ReferralError.notSignedIn }
        // Same short-lived-access-token reasoning as every other
        // `AuthManager` call site that isn't itself part of the sign-in
        // flow — Settings (where the redeem field lives) is very often
        // opened long after the hour-long token lifetime.
        try await AuthManager.shared.refreshSessionIfNeeded()
        guard let session = AuthManager.shared.session,
              let config = SupabaseConfig.shared,
              let functionURLString = Bundle.main.object(forInfoDictionaryKey: "SupabaseFunctionURL") as? String,
              let functionsBase = URL(string: functionURLString)?.deletingLastPathComponent() else {
            throw ReferralError.missingConfig
        }

        var request = URLRequest(url: functionsBase.appendingPathComponent("referrals"))
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["action": action]
        for (key, value) in extra { body[key] = value }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let message = json["error"] as? String ?? "Something went wrong. Check your connection and try again."
            throw ReferralError.requestFailed(message)
        }
        return json
    }
}
