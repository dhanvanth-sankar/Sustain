import Foundation
import RevenueCat

/// Closes report priority #5 in
/// `Sustain-Subscription-Payer-Features-Report-2026-08.md`: "Monitor
/// AI-feature retention specifically, not just conversion." That item was
/// marked "N/A — process, not a feature" because, as written, it's a
/// metrics-watching habit, not a screen to build. But the report's own
/// justification — industry-wide, AI-powered apps convert better but churn
/// 30% faster, which is a real risk given how AI-heavy Sustain's premium
/// tier already is — was previously unanswerable from inside this app:
/// nothing recorded AI-feature usage anywhere, so there was no way to ever
/// actually build the retention cohort the report is warning to watch for.
/// This tracker closes that gap directly: it's the instrumentation that
/// makes the "process" monitoring possible, not a user-facing feature.
///
/// **Deliberately does not add a new analytics SDK.** Firebase, Mixpanel,
/// and Amplitude were all real options; all three would add a new
/// third-party data-collection vendor to an app whose own marketing
/// (see `CHANGELOG.md`, the paywall copy) leans on "no ads, privacy-first"
/// positioning, and would each need their own App Store privacy
/// "nutrition label" entry and likely an App Review notes update — a real
/// product decision, not something to make unilaterally while closing a
/// research-report gap. RevenueCat is not a new vendor: it's the billing
/// SDK already integrated (`EntitlementManager.swift`, `AuthManager.swift`'s
/// `Purchases.shared.logIn`) and already covered by the app's existing
/// privacy policy, and subscriber attributes
/// (`Purchases.shared.attribution.setAttributes`) are a native, documented
/// RevenueCat capability, not a new tracking surface layered on top of it.
/// This is the same reasoning `PhoneConnectivityManager` used for choosing
/// `WatchConnectivity` over a new sync backend: prefer the infrastructure
/// already present and already disclosed over adding a new one.
///
/// **What actually gets recorded**: only a per-AI-feature last-used
/// timestamp and a rolling 30-day use count, kept locally in
/// `UserDefaults` and periodically summarized up to RevenueCat as string
/// subscriber attributes. No message content, no photo, no health data of
/// any kind — just "did this subscriber use this specific AI feature, and
/// when." That's exactly the shape of data a retention cohort needs
/// ("subscribers who used the chat coach in month 1 — do they look
/// different at month 3 than subscribers who never touched it") without
/// exporting anything more sensitive than that.
///
/// **Call sites**: `recordUse(_:)` is called immediately alongside every
/// existing `entitlements.recordAIUsage()` call — the same "a real AI call
/// just completed" moment already used for trial-budget metering, not a
/// separate hook — in `LogProteinView.swift`, `DashboardView.swift`,
/// `LabResultsView.swift`, `ChatCoachView.swift`, and
/// `WeeklySummaryCard.swift`. `BodyScanEstimator`'s call site does the
/// same once that feature exists.
enum AIFeatureEngagementTracker {
    enum Feature: String, CaseIterable {
        case proteinPhotoEstimate = "protein_photo_estimate"
        case labResultImport = "lab_result_import"
        case chatCoach = "chat_coach"
        case weeklyRecap = "weekly_recap"
        case bodyScanEstimate = "body_scan_estimate"
    }

    private static let defaults = UserDefaults.standard
    private static func usesKey(_ feature: Feature) -> String { "aiEngagement_\(feature.rawValue)_uses" }

    /// Appends a use timestamp for `feature` and re-pushes the full summary
    /// to RevenueCat. Cheap and safe to call from anywhere — if RevenueCat
    /// hasn't finished configuring yet (shouldn't happen here, since every
    /// real call site is already gated behind `isPremium`, which itself
    /// requires a configured SDK), `Purchases.isConfigured` guards against
    /// the force-crash `SustainApp.swift`'s header comment documents for
    /// touching `Purchases.shared` too early.
    static func recordUse(_ feature: Feature, date: Date = .now) {
        var uses = (defaults.array(forKey: usesKey(feature)) as? [Double]) ?? []
        uses.append(date.timeIntervalSince1970)
        // Keep at most the trailing 90 days of raw timestamps per feature —
        // this is a rolling engagement signal, not a permanent usage log;
        // nothing downstream reads further back than the 30-day window
        // `pushSummary` computes.
        let cutoff = date.addingTimeInterval(-90 * 24 * 3600).timeIntervalSince1970
        uses = uses.filter { $0 >= cutoff }
        defaults.set(uses, forKey: usesKey(feature))
        pushSummary()
    }

    /// Added 2026-09 for the trial-compression change (`PaywallView`'s post-trial
    /// prompt) — needs a plain "has this person ever actually run the AI photo
    /// estimate" check, which nothing here previously exposed (`pushSummary` only
    /// ever reads the raw arrays internally). Deliberately checks the full stored
    /// history, not just the rolling 30-day window `pushSummary` uses for RevenueCat
    /// attributes — someone who tried the feature 40 days ago and is only now
    /// starting a trial has still "ever used" it, and shouldn't get a redundant
    /// first-time prompt.
    static func hasEverUsed(_ feature: Feature) -> Bool {
        !((defaults.array(forKey: usesKey(feature)) as? [Double])?.isEmpty ?? true)
    }

    /// Summarizes every feature's rolling 30-day use count and most recent
    /// use date into RevenueCat subscriber attributes — one pair per
    /// feature (`ai_uses_30d_<feature>`, `ai_last_used_<feature>`) plus two
    /// combined "any AI feature" attributes so a retention cohort doesn't
    /// require unioning five separate ones by hand in the dashboard.
    private static func pushSummary() {
        guard Purchases.isConfigured else { return }

        let now = Date()
        var attributes: [String: String] = [:]
        var mostRecentAnyFeature: Date?
        var anyFeature30dCount = 0

        for feature in Feature.allCases {
            let uses = ((defaults.array(forKey: usesKey(feature)) as? [Double]) ?? [])
                .map { Date(timeIntervalSince1970: $0) }
            let uses30d = uses.filter { now.timeIntervalSince($0) <= 30 * 24 * 3600 }
            attributes["ai_uses_30d_\(feature.rawValue)"] = String(uses30d.count)
            if let last = uses.max() {
                attributes["ai_last_used_\(feature.rawValue)"] = isoFormatter.string(from: last)
                if mostRecentAnyFeature.map({ last > $0 }) ?? true {
                    mostRecentAnyFeature = last
                }
            }
            anyFeature30dCount += uses30d.count
        }

        attributes["ai_uses_30d_any_feature"] = String(anyFeature30dCount)
        if let mostRecentAnyFeature {
            attributes["ai_last_used_any_feature"] = isoFormatter.string(from: mostRecentAnyFeature)
        }

        Purchases.shared.attribution.setAttributes(attributes)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
