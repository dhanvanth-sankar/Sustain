import Foundation
import RevenueCat
import TelemetryDeck

/// Central analytics wrapper — see `PROJECT_HANDOFF.md` §2 "Trust-first, not
/// growth-hacked" for the constraint this was built under, and
/// `marketing/Sustain-Growth-Strategy-2026-08.md` for why this exists at
/// all: nothing downstream of install was measurable before this
/// (`PROJECT_HANDOFF.md`'s own "Not started" list flagged "TelemetryDeck or
/// any analytics — still not started" explicitly), so none of that plan's
/// 30/60/90-day checkpoints could ever be evaluated against reality.
///
/// **Vendor choice**: TelemetryDeck, not Firebase/Mixpanel/Amplitude — the
/// same reasoning `AIFeatureEngagementTracker`'s header comment already gives
/// for reusing RevenueCat instead of a new SDK for AI-retention data applies
/// here, just for the one new vendor this app genuinely didn't have yet.
/// TelemetryDeck is built specifically not to use IDFA/ad identifiers (no App
/// Tracking Transparency prompt needed), and hashes the one identifier it
/// does use (`customUserID`) client-side before it ever leaves the device,
/// then salts and hashes it *again* server-side — see
/// https://telemetrydeck.com/docs/articles/anonymization-how-it-works/. This
/// was the option already discussed for this app specifically, chosen for
/// matching the "trust-first" posture rather than fighting it — not
/// re-evaluated against other vendors here.
///
/// **What identifies a user, and why it's the account ID, not a fresh UUID**:
/// `currentUserID` below passes the signed-in account's Supabase user ID
/// (never an email, name, or anything else identifying) as `customUserID`.
/// This is deliberately the *account* ID, not a random per-install ID,
/// specifically so D1/D7/D30 retention cohorts correctly across a reinstall
/// or a second device signed into the same account — a per-install ID would
/// silently undercount retention for anyone who ever switches phones, which
/// this app's own mandatory account-sync makes a real, common scenario, not
/// an edge case. Before sign-in completes (the handful of onboarding/
/// marketing screens that exist pre-account), a random anonymous ID
/// persisted in `UserDefaults` covers those events instead — losing it on
/// reinstall is fine, since it was already anonymous and short-lived by
/// construction.
///
/// **What is never sent**: no message content, no photo, no health value, no
/// medication name, no weight, no dose amount, no lab value — every event
/// below is "something happened" (a screen was reached, a feature was
/// attempted or completed, a paywall was shown, which one) plus which named
/// step/feature/trigger, never the substance of what the user typed, ate,
/// weighs, or takes. This mirrors `AIFeatureEngagementTracker`'s own "did
/// this happen, not what it contained" boundary — see that file's header
/// comment for the same reasoning applied to RevenueCat subscriber
/// attributes instead of TelemetryDeck signals.
///
/// **Disclosure**: see `Documentation/privacy-policy.md`'s "Analytics"
/// paragraph (added alongside this file) and `PrivacyInfo.xcprivacy`'s
/// `NSPrivacyCollectedDataTypeProductInteraction` entry — this is a second,
/// separate data flow from the existing `AIFeatureEngagementTracker`/
/// RevenueCat one (different vendor, broader event set), disclosed
/// separately rather than folded into that entry's existing language.
enum AnalyticsManager {

    // MARK: - Events

    /// Every event this app sends, named once here rather than as loose
    /// string literals scattered across call sites — see
    /// `marketing/Sustain-Growth-Strategy-2026-08.md`'s measurement
    /// requirements for why each of these specifically exists:
    /// - `.appOpened` → D1/D7/D30 retention (item 2).
    /// - `.onboardingStepReached`/`.onboardingCompleted` → install →
    ///   activation rate, with step-level drop-off (item 1).
    /// - `.paywallViewed` → both the AI-feature-paywall half of item 3
    ///   ("free-tier attempts that hit the paywall") and the paywall-funnel
    ///   split by gate (item 4) — one event covers both, since a paywall
    ///   view *is* the blocked-attempt moment for every AI-feature trigger.
    /// - `.aiScanBlockedTrialLimit` → the other half of item 3: a trialing
    ///   subscriber who already has `isPremium == true` but hit the trial's
    ///   metered AI-call cap never sees `PaywallView` at all (see
    ///   `EntitlementManager.canUseAIFeature`), so that block needs its own
    ///   signal rather than piggybacking on `.paywallViewed`.
    /// - `.aiScanCompleted` → the "actual completed scans" half of item 3.
    /// - `.trialStarted` → the top of item 4's funnel; trial-to-paid
    ///   *conversion* itself is deliberately NOT a TelemetryDeck event — see
    ///   `recordPaywallTriggerForConversionAttribution(_:)` below for why
    ///   that half already lives in RevenueCat instead.
    enum Event {
        case appOpened
        case onboardingStepReached(OnboardingStep)
        case onboardingCompleted
        case paywallViewed(trigger: PaywallTrigger)
        case trialStarted(trigger: PaywallTrigger, plan: EntitlementManager.Plan)
        case aiScanCompleted(feature: AIFeatureEngagementTracker.Feature)
        case aiScanBlockedTrialLimit(feature: AIFeatureEngagementTracker.Feature)
        /// Added 2026-09 for `Sustain-Subscription-Conversion-Research-2026-09.md`'s
        /// #1 recommendation ("Pip Notices") — the funnel for this feature specifically
        /// needs its own signals because, unlike every other AI feature, the user never
        /// initiates it: `.patternDetected` fires the moment a new, unseen pattern is
        /// computed (whether or not the person is premium — see `PatternNoticeCard`'s
        /// own doc comment for why free users still get a teaser, never a push), and
        /// `.patternDismissed`/`.patternMuted` close the loop on whether the proactive
        /// surfacing is actually landing as useful or just being dismissed.
        case patternDetected(kind: PatternDetectionEngine.DetectedPattern.Kind, isPremium: Bool)
        case patternDismissed(kind: PatternDetectionEngine.DetectedPattern.Kind)
        case patternMuted(kind: PatternDetectionEngine.DetectedPattern.Kind)
        /// Added 2026-09-27 for the "Life After GLP-1" feature
        /// (`Sustain-GLP1-Market-PESTLE-FeatureGap-Report-2026-09.md` §15). Records only
        /// that a discontinuation was marked, never the reason — see
        /// `DiscontinuationReason`'s own doc comment for why that stays on-device only,
        /// the same "never send health values" boundary this file's header already
        /// documents.
        case medicationDiscontinuationMarked
        case medicationResumedAfterDiscontinuation
        case lifeAfterGLP1Viewed
        /// The quick-traction content card (insurance-appeal odds) — tracked
        /// separately from every other analytics event in this file because, unlike
        /// them, its purpose is measuring organic reach/word-of-mouth, not funnel
        /// health. See `LifeAfterGLP1View`'s header comment.
        case insuranceInfoCardShared

        fileprivate var signalName: String {
            switch self {
            case .appOpened: return "appOpened"
            case .onboardingStepReached: return "onboardingStepReached"
            case .onboardingCompleted: return "onboardingCompleted"
            case .paywallViewed: return "paywallViewed"
            case .trialStarted: return "trialStarted"
            case .aiScanCompleted: return "aiScanCompleted"
            case .aiScanBlockedTrialLimit: return "aiScanBlockedTrialLimit"
            case .patternDetected: return "patternDetected"
            case .patternDismissed: return "patternDismissed"
            case .patternMuted: return "patternMuted"
            case .medicationDiscontinuationMarked: return "medicationDiscontinuationMarked"
            case .medicationResumedAfterDiscontinuation: return "medicationResumedAfterDiscontinuation"
            case .lifeAfterGLP1Viewed: return "lifeAfterGLP1Viewed"
            case .insuranceInfoCardShared: return "insuranceInfoCardShared"
            }
        }

        fileprivate var parameters: [String: String] {
            switch self {
            case .appOpened:
                return [:]
            case .onboardingStepReached(let step):
                return ["step": String(step.rawValue), "stepName": String(describing: step)]
            case .onboardingCompleted:
                return [:]
            case .paywallViewed(let trigger):
                return ["trigger": trigger.rawValue, "gate": trigger.gateGroup]
            case .trialStarted(let trigger, let plan):
                return ["trigger": trigger.rawValue, "gate": trigger.gateGroup, "plan": plan.rawValue]
            case .aiScanCompleted(let feature):
                return ["feature": feature.rawValue]
            case .aiScanBlockedTrialLimit(let feature):
                return ["feature": feature.rawValue]
            case .patternDetected(let kind, let isPremium):
                return ["kind": kind.rawValue, "isPremium": isPremium ? "true" : "false"]
            case .patternDismissed(let kind):
                return ["kind": kind.rawValue]
            case .patternMuted(let kind):
                return ["kind": kind.rawValue]
            case .medicationDiscontinuationMarked, .medicationResumedAfterDiscontinuation, .lifeAfterGLP1Viewed, .insuranceInfoCardShared:
                return [:]
            }
        }
    }

    /// Every place `PaywallView` can be reached from, named specifically
    /// rather than generically — `gateGroup` below is what actually answers
    /// growth-strategy item 4's request ("split by the two gates: AI feature
    /// paywall vs. the 30-day history wall"), but keeping the finer-grained
    /// case here too costs nothing and is strictly more useful later (e.g.
    /// telling the AI chat coach's conversion rate apart from the AI photo
    /// estimate's, instead of only ever seeing them merged).
    enum PaywallTrigger: String {
        case aiPhotoEstimate = "ai_photo_estimate"
        case aiChatCoach = "ai_chat_coach"
        case aiWeeklyRecap = "ai_weekly_recap"
        case aiLabResults = "ai_lab_results"
        case historyWall = "history_wall"
        case bodyComposition = "body_composition"
        case recovery = "recovery"
        case progressPhotos = "progress_photos"
        case settingsMenu = "settings_menu"
        case postOnboarding = "post_onboarding"
        /// Added 2026-09 alongside the pattern-detection feature — grouped under
        /// `ai_feature` below since, like the other AI triggers, it's gated behind an
        /// AI-adjacent capability rather than the plain history window.
        case patternDetection = "pattern_detection"

        var gateGroup: String {
            switch self {
            case .aiPhotoEstimate, .aiChatCoach, .aiWeeklyRecap, .aiLabResults, .patternDetection:
                return "ai_feature"
            case .historyWall:
                return "history_wall"
            case .bodyComposition, .recovery, .progressPhotos, .settingsMenu, .postOnboarding:
                return "other"
            }
        }
    }

    // MARK: - Sending

    /// Call from anywhere, on any thread — the TelemetryDeck SDK queues
    /// signals sent before `configure()` runs and flushes them once it does,
    /// so call-site ordering relative to app launch doesn't need to be
    /// reasoned about the way `Purchases.shared` in `EntitlementManager`
    /// does.
    static func track(_ event: Event) {
        TelemetryDeck.signal(event.signalName, parameters: event.parameters, customUserID: currentUserID)
    }

    // MARK: - Identity

    private static let anonymousIDKey = "analyticsAnonymousID"

    /// See this type's header comment for why this is the account ID, not a
    /// fresh per-install UUID, whenever one is available.
    private static var currentUserID: String {
        if let accountID = AuthManager.shared.session?.userId.uuidString {
            return accountID
        }
        if let existing = UserDefaults.standard.string(forKey: anonymousIDKey) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: anonymousIDKey)
        return newID
    }

    // MARK: - Configuration

    /// Called once from `SustainApp.init()`, alongside `Purchases.configure`
    /// — same "must happen before anything tries to use the SDK" reasoning
    /// that file already documents for RevenueCat. Unlike that call,
    /// silently no-ops on a missing key rather than an `assertionFailure`:
    /// losing analytics for a session is a real but low-stakes gap, while a
    /// misconfigured RevenueCat key would silently break real billing, which
    /// is why only that one asserts.
    static func configure() {
        guard let appID = Bundle.main.object(forInfoDictionaryKey: "TelemetryDeckAppID") as? String,
              !appID.isEmpty else {
            #if DEBUG
            print("AnalyticsManager: TelemetryDeckAppID missing from Info.plist — check Secrets.xcconfig. Analytics disabled for this session.")
            #endif
            return
        }
        TelemetryDeck.initialize(config: .init(appID: appID))
    }

    // MARK: - RevenueCat correlation

    /// Sets a RevenueCat subscriber attribute recording which paywall
    /// trigger this subscriber most recently saw. This is deliberately how
    /// growth-strategy item 4's trial-to-paid *conversion* number (as
    /// opposed to the paywall-*view* number, which is a TelemetryDeck event
    /// above) gets split by gate: RevenueCat's own dashboard already
    /// computes trial starts and trial→paid conversion natively without any
    /// custom event needed, so duplicating that in TelemetryDeck as a second,
    /// parallel system would be exactly the redundant build the growth
    /// request's own constraints said to avoid. Tagging the subscriber with
    /// which gate they came from lets that existing RevenueCat number be
    /// filtered by gate directly, the same way `AIFeatureEngagementTracker`
    /// already tags subscribers with AI-feature usage via the exact same
    /// `Purchases.shared.attribution.setAttributes` mechanism — reused here,
    /// not a new pattern.
    static func recordPaywallTriggerForConversionAttribution(_ trigger: PaywallTrigger) {
        guard Purchases.isConfigured else { return }
        Purchases.shared.attribution.setAttributes([
            "last_paywall_trigger": trigger.rawValue,
            "last_paywall_gate": trigger.gateGroup,
        ])
    }
}
