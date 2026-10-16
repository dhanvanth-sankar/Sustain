import Foundation
import Observation
import RevenueCat

/// Real billing, backed by RevenueCat/StoreKit — this used to be a local
/// `UserDefaults`-only stand-in (see CHANGELOG.md for that history); this file
/// is the "swap this for RevenueCat once you have a project" the old version
/// of this comment was pointing at. `Purchases.configure` happens exactly once,
/// at app launch in `SustainApp.swift`, before any view can construct
/// `EntitlementManager.shared` — everything here just reads and reacts to the
/// SDK's `CustomerInfo` from that point on.
///
/// Manual dose/weight/protein/side-effect logging is free forever per the
/// product's trust-first monetization model — this type only gates the "see
/// your full history" and AI features.
@Observable
final class EntitlementManager: NSObject, PurchasesDelegate {
    static let shared = EntitlementManager()

    static let freeHistoryWindowDays = 30

    // Fallback display strings only — used before the real Offering has loaded
    // (e.g. the first frame after a cold launch) or if fetching it fails. Once
    // `monthlyPackage`/`annualPackage` load, `monthlyPriceString`/
    // `annualPriceString` below return RevenueCat's live, localized price
    // instead, which is the actual source of truth.
    static let monthlyPriceDisplay = "$7.99/mo"
    static let annualPriceDisplay = "$59.99/yr"
    static let maintenanceProgramPriceDisplay = "$19.99"

    enum Plan: String { case monthly, annual }

    // Trial length is plan-dependent rather than one flat number. The opportunity
    // report's own cited RevenueCat data (Phase 1) puts 17-32 day trials at 42.5%
    // trial->paid conversion vs. 25.5% for <=4-day trials — that's why annual kept a
    // trial in that range. Monthly is intentionally shorter: RevenueCat documents
    // Headspace running exactly this asymmetric pattern (14-day trial on annual,
    // 7-day on monthly) specifically to make the higher-commitment plan the more
    // attractive one, and it has a second benefit here — it caps how many people get
    // a long, free run of the AI features on the plan most prone to trial-and-cancel.
    //
    // Annual is 30, not the originally-intended 21: Apple's real introductory-offer
    // durations in App Store Connect are a fixed list (3 days/1 week/2 weeks/1 month/
    // 2 months/3 months/6 months/1 year) with no 3-week option, so the real
    // subscription's free trial had to be set to 1 Month there. This constant must
    // match whatever was actually configured on the real subscription product, since
    // it drives this screen's countdown copy and the paywall's trial-timeline text.
    static let annualTrialLengthDays = 30
    static let monthlyTrialLengthDays = 7

    /// A separate, more direct lever on AI cost than trial length: caps how many AI
    /// calls (photo estimates + weekly summaries combined) a trialing user can make
    /// before being asked to actually convert, independent of how many days are left
    /// in the trial. This stays a purely local, app-level counter — RevenueCat/Apple
    /// have no concept of "how many AI calls a user made," so this metering is ours
    /// to keep regardless of real billing being wired up now. Modeled on Cal AI's "N
    /// scans/day" free-tier cap, adapted to a per-trial total since Sustain's
    /// features are weekly-cadence, not a daily habit loop.
    static let trialAICallLimit = 15

    // Real App Store product/entitlement identifiers — must match exactly what's
    // configured in App Store Connect and RevenueCat's dashboard (Entitlements →
    // "premium", Offerings → "default" → $rc_monthly/$rc_annual packages).
    private static let premiumEntitlementID = "premium"
    private static let monthlyProductID = "com.sustainapp.glp1.monthly"
    private static let annualProductID = "com.sustainapp.glp1.annual"
    private static let maintenanceProductID = "com.sustainapp.glp1.maintenance"

    private static let trialAICallsUsedKey = "trialAICallsUsedRaw"

    private(set) var isPremium = false
    /// True only while the "premium" entitlement's current period is an actual
    /// StoreKit free trial (`PeriodType.trial`), not just active. Once a trial
    /// converts to a paid period, this flips to `false` even though `isPremium`
    /// stays `true` — same distinction the old local simulation made, just now
    /// driven by Apple's real trial state instead of a locally-tracked date.
    private(set) var isTrialing = false
    /// One-time purchase, independent of the subscription — unlocked once, when a
    /// user reaches their goal weight, per the report's "what now?" upsell moment.
    /// Derived from `CustomerInfo.allPurchasedProductIdentifiers`, which (unlike the
    /// subscription entitlement) doesn't expire, matching a non-consumable's actual
    /// "owned forever once bought" semantics.
    private(set) var hasMaintenanceProgram = false

    /// Whether the active subscription is currently set to auto-renew. `false`
    /// means the person has cancelled but still has paid time remaining — they
    /// keep full access until `expirationDate`, then lose it. Added 2026-08-01:
    /// before this, a cancelled-but-still-active subscriber saw exactly the
    /// same "You're a Sustain+ member" screen as a renewing one, with no way to
    /// tell that access was ending or when. Showing renewal state and date is
    /// standard practice across subscription apps for exactly this reason —
    /// see `PROJECT_HANDOFF.md` §17 item 11.
    private(set) var willRenew = false
    /// When the current entitlement period ends. For a renewing subscription
    /// this is the next billing date; for a cancelled one it's when access
    /// actually stops. Nil when there's no active entitlement at all.
    private(set) var expirationDate: Date?
    /// True while Apple has reported a failed renewal payment for this
    /// subscription. Whether the person still has access during this window
    /// depends on the billing grace period configured in App Store Connect —
    /// with a grace period they keep access while Apple retries, without one
    /// the entitlement lapses immediately (see RevenueCat's "Billing Issues &
    /// Grace Periods" doc). Either way this is worth surfacing, since the fix
    /// is entirely in the person's hands: update the payment method in the
    /// App Store.
    private(set) var hasBillingIssue = false

    private(set) var trialPlan: Plan?
    /// When the current entitlement period (trial or paid) started, per RevenueCat's
    /// own record. Used for the paywall's "Day X of Y" trial countdown instead of a
    /// locally-tracked date, now that there's a real StoreKit trial to read from.
    private(set) var trialStartDate: Date?

    private(set) var trialAICallsUsed: Int

    private var monthlyPackage: Package?
    private var annualPackage: Package?

    private override init() {
        trialAICallsUsed = UserDefaults.standard.integer(forKey: Self.trialAICallsUsedKey)
        super.init()
        Purchases.shared.delegate = self

        // Permanent dev convenience, kept intentionally (not leftover debug
        // scaffolding) for capturing App Store marketing screenshots on the
        // Simulator, where real StoreKit sandbox sign-in is unreliable —
        // physical-device sandbox purchases were already verified separately
        // and remain the source of truth for real purchase-flow testing (see
        // CHANGELOG). Inert unless `SCREENSHOT_MODE` is manually added to
        // Debug's Active Compilation Conditions in Xcode Build Settings —
        // that flag is never defined for Release, so this branch can never
        // compile into an archived/App Store build regardless.
        #if SCREENSHOT_MODE
        isPremium = true
        isTrialing = false
        hasMaintenanceProgram = true
        // Must be set explicitly alongside the overrides above, added
        // 2026-08-01 with the subscription-status card. `willRenew` defaults
        // to `false`, and `apply()` (the only thing that would normally set
        // it) is deliberately never called in this mode — so without this
        // line the new status card would render "Subscription ending / You've
        // cancelled" on every App Store marketing screenshot, which is both
        // wrong and the single worst possible string to ship in store artwork.
        willRenew = true
        hasBillingIssue = false
        expirationDate = Calendar.current.date(byAdding: .month, value: 1, to: Date())
        #else
        Task { await refreshFromCustomerInfo() }
        Task { await loadOfferings() }
        #endif
    }

    // MARK: - Syncing from RevenueCat

    /// `PurchasesDelegate` callback — fires whenever the SDK receives updated
    /// `CustomerInfo` from any call (`purchase`, `restorePurchases`, a background
    /// refresh, etc.), so this stays current without every call site having to
    /// manually re-fetch and re-apply state after every action.
    ///
    /// Assigning `Purchases.shared.delegate = self` in `init()` triggers this
    /// callback itself, asynchronously, with whatever real (unentitled, on a
    /// simulator with no sandbox sign-in) `CustomerInfo` the SDK has cached —
    /// which clobbers the `isPremium = true` override `init()` just set under
    /// `SCREENSHOT_MODE`, moments after it was set. Skip it entirely in that
    /// mode so the override actually sticks.
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        #if SCREENSHOT_MODE
        return
        #else
        apply(customerInfo)
        #endif
    }

    private func refreshFromCustomerInfo() async {
        guard let customerInfo = try? await Purchases.shared.customerInfo() else { return }
        apply(customerInfo)
    }

    /// Fetches once and applies. Left as the fast path `init()` calls — most launches
    /// succeed on the first try, and this stays cheap for that common case.
    private func loadOfferings() async {
        guard let offerings = try? await Purchases.shared.offerings() else { return }
        monthlyPackage = offerings.current?.monthly
        annualPackage = offerings.current?.annual
    }

    /// `init()` fired `loadOfferings()` exactly once with no retry, so a single
    /// transient failure (a sandbox blip, a slow cold-launch network path — both
    /// materially more common on the Simulator's StoreKit sandbox than on a real
    /// device or in production) left `monthlyPackage`/`annualPackage` nil for the rest
    /// of the app's session. The paywall then permanently showed fallback display
    /// prices and any purchase attempt threw `.offeringsUnavailable`, with no way to
    /// recover short of force-quitting and relaunching — a real risk during App
    /// Review specifically, since a reviewer hitting this once reads as "purchase is
    /// broken," not "the network hiccuped." Diagnosed from a real repro: RevenueCat's
    /// own sandbox transaction history confirmed purchases have succeeded repeatedly
    /// on this same account, so the flow itself works — this was purely "the one
    /// fetch that happened to run at launch didn't come back."
    ///
    /// Called from `PaywallView` whenever the acquisition pitch appears while a
    /// package is still missing, and inline from `purchase(plan:)` as a last-chance
    /// retry before actually giving up — see both call sites.
    func ensureOfferingsLoaded() async {
        guard monthlyPackage == nil || annualPackage == nil else { return }
        for attempt in 0..<3 {
            await loadOfferings()
            if monthlyPackage != nil, annualPackage != nil { return }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt + 1))
            }
        }
    }

    private func apply(_ customerInfo: CustomerInfo) {
        let entitlement = customerInfo.entitlements.all[Self.premiumEntitlementID]
        isPremium = entitlement?.isActive ?? false
        isTrialing = entitlement?.periodType == .trial
        trialStartDate = entitlement?.latestPurchaseDate

        // Renewal/expiry/billing state, all read straight from RevenueCat's
        // `EntitlementInfo` rather than tracked locally — see each property's
        // doc comment above. `willRenew` defaults to false when there's no
        // entitlement at all, which is correct: nothing to renew.
        willRenew = entitlement?.willRenew ?? false
        expirationDate = entitlement?.expirationDate
        hasBillingIssue = entitlement?.billingIssueDetectedAt != nil

        switch entitlement?.productIdentifier {
        case Self.monthlyProductID: trialPlan = .monthly
        case Self.annualProductID: trialPlan = .annual
        default: trialPlan = nil
        }

        hasMaintenanceProgram = customerInfo.allPurchasedProductIdentifiers.contains(Self.maintenanceProductID)

        // Trial usage metering only means something during an actual trial —
        // once it ends (converted to paid, cancelled, or never started), a stale
        // count from a previous trial shouldn't linger and affect anything.
        if !isTrialing {
            trialAICallsUsed = 0
            UserDefaults.standard.removeObject(forKey: Self.trialAICallsUsedKey)
        }
    }

    // MARK: - Live pricing

    /// RevenueCat's live, localized price for the monthly plan, falling back to
    /// the static display string above only until the real Offering has loaded
    /// (or if fetching it ever fails) — see that constant's doc comment.
    var monthlyPriceString: String {
        monthlyPackage?.storeProduct.localizedPriceString ?? Self.monthlyPriceDisplay
    }

    var annualPriceString: String {
        annualPackage?.storeProduct.localizedPriceString ?? Self.annualPriceDisplay
    }

    /// The annual plan's price expressed per month, i.e. the "price per unit if
    /// appropriate" that App Store Guideline 3.1.2(c) requires alongside the headline
    /// price. Computed from the real StoreKit product's price and currency (so it
    /// stays correct in every storefront) rather than hardcoded against the US
    /// dollar figure. Returns nil if the Offering hasn't loaded, in which case the
    /// paywall simply omits the per-month line rather than showing a wrong number.
    var annualPricePerMonthString: String? {
        guard let product = annualPackage?.storeProduct else { return nil }
        let perMonth = product.price / 12
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = product.currencyCode
        formatter.locale = .current
        return formatter.string(from: perMonth as NSDecimalNumber)
    }

    /// Added 2026-08-03 per `Sustain-Subscription-Conversion-Report-2026-08.md`
    /// §8: the annual plan's "save over 35%" line was a hardcoded literal (see
    /// CHANGELOG.md's "Paywall savings copy now computed live" entry for the
    /// full story) with no live tie to the real StoreKit prices at all — accurate
    /// today only because nobody had changed either product's price since it was
    /// written. Computed here from the two real product prices whenever both
    /// have loaded, so a future price change anywhere can't silently make this
    /// line wrong. Falls back to the same static "over 35%" wording only for the
    /// brief pre-load window, matching every other price string in this file.
    var annualSavingsPercentString: String {
        guard let monthly = monthlyPackage?.storeProduct.price,
              let annual = annualPackage?.storeProduct.price,
              monthly > 0 else {
            return "over 35%"
        }
        let monthlyAnnualized = monthly * 12
        guard monthlyAnnualized > annual else { return "over 35%" }
        let savings = (monthlyAnnualized - annual) / monthlyAnnualized * 100
        // Rounds down to the nearest whole percent so this reads as a
        // conservative, defensible claim ("save over 37%") rather than a
        // precise-looking decimal that invites scrutiny of the exact math.
        let roundedDown = Int(NSDecimalNumber(decimal: savings).doubleValue.rounded(.down))
        return "over \(roundedDown)%"
    }

    /// The report's cited finding (RevenueCat, at least one tested market):
    /// price-anchoring copy like "that's just $5/mo" alongside the annual
    /// plan's real headline price lifted trial starts 30% with no conversion
    /// penalty. `annualPricePerMonthString` above already computes this
    /// correctly per-storefront; this just phrases it as the anchor line the
    /// report specifically recommends testing, reusing that same live value
    /// rather than a second hardcoded number.
    var annualPriceAnchorString: String? {
        guard let perMonth = annualPricePerMonthString else { return nil }
        return "That's just \(perMonth)/mo"
    }

    /// Human-readable billing period per plan, required verbatim by 3.1.2(c)
    /// ("length of subscription"). Kept here rather than inline in the view so the
    /// paywall and any future purchase surface can't drift apart on the wording.
    static func billingPeriodDescription(for plan: Plan) -> String {
        switch plan {
        case .monthly: return "1 month"
        case .annual: return "12 months"
        }
    }

    static func renewalDescription(for plan: Plan) -> String {
        switch plan {
        case .monthly: return "Renews every month until cancelled."
        case .annual: return "Renews every 12 months until cancelled."
        }
    }

    var trialLengthDays: Int {
        switch trialPlan {
        case .monthly: return Self.monthlyTrialLengthDays
        case .annual, .none: return Self.annualTrialLengthDays
        }
    }

    // MARK: - Subscription status (renewal / cancellation / billing)

    /// What's actually happening with the subscription right now, as opposed to
    /// the binary `isPremium`. Added 2026-08-01 — see `willRenew`'s doc comment
    /// for why "active" alone wasn't enough to show someone.
    enum SubscriptionStatus {
        case none
        /// In a free trial that will convert to a paid subscription.
        case trialing
        /// In a free trial that has already been cancelled — access runs to the
        /// end of the trial and then stops, with no charge. Deliberately a
        /// separate case from `trialing`: cancelling during the trial is one of
        /// the most common things a trialist does, and collapsing the two
        /// meant telling someone their subscription was about to begin when
        /// they had explicitly stopped it from beginning.
        case trialCancelled
        case renewing
        /// Cancelled, but still inside the paid period — full access until
        /// `expirationDate`.
        case cancelled
        case billingIssue
    }

    var subscriptionStatus: SubscriptionStatus {
        guard isPremium else { return .none }
        // Billing trouble takes display priority over everything else: it's the
        // only one of these states the person can (and should) act on today.
        if hasBillingIssue { return .billingIssue }
        if isTrialing { return willRenew ? .trialing : .trialCancelled }
        return willRenew ? .renewing : .cancelled
    }

    /// A cached formatter — `DateFormatter` construction is genuinely
    /// expensive, and this is read during view body evaluation, so building a
    /// fresh one each time would put that cost on the render path (same
    /// reasoning as the performance pass documented in `README.md`).
    private static let expirationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var formattedExpirationDate: String? {
        expirationDate.map { Self.expirationFormatter.string(from: $0) }
    }

    /// Short headline for the current status. Centralized here, rather than
    /// written inline at each call site, for the same reason
    /// `billingPeriodDescription(for:)` is — the paywall's member view and the
    /// account screen must not drift apart on wording.
    var subscriptionStatusTitle: String? {
        switch subscriptionStatus {
        case .none: return nil
        case .trialing: return "Free trial"
        case .trialCancelled: return "Free trial ending"
        case .renewing: return "Subscription active"
        case .cancelled: return "Subscription ending"
        case .billingIssue: return "Payment problem"
        }
    }

    /// The supporting line under `subscriptionStatusTitle`, including the real
    /// date wherever one is known. Deliberately omits the date rather than
    /// inventing one if `expirationDate` is nil (it can legitimately be nil for
    /// a lifetime/non-expiring entitlement, or before the first `CustomerInfo`
    /// fetch lands).
    var subscriptionStatusDetail: String? {
        let dateText = formattedExpirationDate
        switch subscriptionStatus {
        case .none:
            return nil
        case .trialing:
            guard let dateText else { return "Your free trial is active." }
            return "Your free trial ends \(dateText), when your subscription begins."
        case .trialCancelled:
            guard let dateText else { return "You've cancelled, so you won't be charged. Your access ends when the trial does." }
            return "You've cancelled, so you won't be charged. Your access continues until \(dateText)."
        case .renewing:
            guard let dateText else { return "Renews automatically." }
            return "Renews automatically on \(dateText)."
        case .cancelled:
            guard let dateText else { return "Your subscription won't renew. You have access until it ends." }
            return "You've cancelled, so this won't renew. You keep full access until \(dateText)."
        case .billingIssue:
            return "Apple couldn't process your last payment. Update your payment method in the App Store to keep your subscription."
        }
    }

    /// True for states the person should actually do something about — used to
    /// tint the status card so a payment problem doesn't read as routine.
    var subscriptionStatusNeedsAttention: Bool {
        switch subscriptionStatus {
        case .billingIssue, .cancelled, .trialCancelled: return true
        case .none, .trialing, .renewing: return false
        }
    }

    // MARK: - AI usage metering (local, independent of real billing — see
    // `trialAICallLimit`'s doc comment)

    /// The actual gate the two AI call sites (`AIProteinEstimator`,
    /// `WeeklySummaryGenerator`) should check instead of raw `isPremium` — a full
    /// paying subscriber (post-trial) is unlimited, but a still-trialing user is
    /// capped at `trialAICallLimit` combined calls. Free (non-premium) users are
    /// blocked by the existing `isPremium` paywall gate before this is ever reached.
    var canUseAIFeature: Bool {
        guard isPremium else { return false }
        guard isTrialing else { return true }
        return trialAICallsUsed < Self.trialAICallLimit
    }

    var trialAICallsRemaining: Int {
        max(0, Self.trialAICallLimit - trialAICallsUsed)
    }

    /// Call once per successful AI request (photo estimate or weekly summary) —
    /// no-ops for a full subscriber outside a trial, since only trial usage is
    /// metered.
    func recordAIUsage() {
        guard isTrialing else { return }
        trialAICallsUsed += 1
        UserDefaults.standard.set(trialAICallsUsed, forKey: Self.trialAICallsUsedKey)
    }

    // MARK: - Purchases

    enum PurchaseError: LocalizedError {
        case offeringsUnavailable
        case userCancelled

        var errorDescription: String? {
            switch self {
            case .offeringsUnavailable:
                return "Pricing isn't available right now. Check your connection and try again."
            case .userCancelled:
                // Not a real error — a deliberate cancel shouldn't surface a red
                // error banner. Call sites should check for this case and treat
                // it as a silent no-op.
                return nil
            }
        }
    }

    /// Starts a real StoreKit purchase (with whatever free trial is configured on
    /// that product in App Store Connect) for the given plan. Throws
    /// `.userCancelled` if the person dismisses the system purchase sheet — call
    /// sites should treat that case as a silent no-op, not an error to display.
    @MainActor
    func purchase(plan: Plan) async throws {
        // Last-chance retry rather than failing immediately on a still-nil package —
        // see `ensureOfferingsLoaded()`'s doc comment for why the original single
        // launch-time fetch wasn't enough on its own.
        if monthlyPackage == nil || annualPackage == nil {
            await ensureOfferingsLoaded()
        }

        let package: Package?
        switch plan {
        case .monthly: package = monthlyPackage
        case .annual: package = annualPackage
        }
        guard let package else { throw PurchaseError.offeringsUnavailable }

        let result = try await Purchases.shared.purchase(package: package)
        guard !result.userCancelled else { throw PurchaseError.userCancelled }
        apply(result.customerInfo)
    }

    /// The Maintenance Program is deliberately not part of the "default" Offering
    /// (it's a one-time unlock shown only after reaching a goal weight, not a plan
    /// choice on the main paywall), so it's fetched directly by product ID rather
    /// than through a Package.
    @MainActor
    func purchaseMaintenanceProgram() async throws {
        let products = await Purchases.shared.products([Self.maintenanceProductID])
        guard let product = products.first else { throw PurchaseError.offeringsUnavailable }

        let result = try await Purchases.shared.purchase(product: product)
        guard !result.userCancelled else { throw PurchaseError.userCancelled }
        apply(result.customerInfo)
    }

    /// Required by App Store guidelines whenever purchases exist — lets someone
    /// recover access on a new device or after a reinstall, without RevenueCat
    /// creating a duplicate "purchase."
    @discardableResult
    func restorePurchases() async -> Bool {
        guard let customerInfo = try? await Purchases.shared.restorePurchases() else { return false }
        apply(customerInfo)
        return customerInfo.entitlements.all[Self.premiumEntitlementID]?.isActive ?? false
    }
}
