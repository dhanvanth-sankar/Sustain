import StoreKit
import SwiftUI
import UIKit

/// Color choices here follow evidence rather than house style, since this screen is
/// the app's actual revenue surface:
/// - Light background, forced regardless of system appearance — paywalls measurably
///   outperform dark backgrounds (RevenueCat cites a case study where dark-green →
///   white background lifted trial conversion), and light mode reads as more
///   trustworthy/clinical in healthcare-adjacent contexts specifically. This only
///   applies to the acquisition pitch, not the member-management state below — an
///   existing subscriber isn't being sold anything, so forcing a scheme flip there
///   was just an unmotivated dark-to-light flash on every open from a dark-mode
///   device, with none of the conversion rationale to justify it.
/// - The CTA button is the only saturated, high-contrast element on the screen —
///   RevenueCat's own paywall guidance: making the CTA the sole colored element is
///   the single highest-leverage change, because every other saturated color
///   competes for attention instead of reinforcing the one action that matters.
///   Everything else (badges, icons) is deliberately monochrome.
/// - Teal/green as the one brand accent is intentional, not arbitrary: color-psychology
///   research on purchase paths specifically finds green wins in health & wellness and
///   in SaaS free-trial contexts — both apply directly here.
///
/// This view branches on `entitlements.isPremium`: existing members get a distinct
/// management state, not the acquisition pitch. Showing "Start your free trial" to
/// someone who already pays is a real trust problem, not a cosmetic one — it reads as
/// the app not knowing they're a customer.
struct PaywallView: View {
    /// Which screen/feature actually opened this paywall — see
    /// `AnalyticsManager.PaywallTrigger` for the full case list and why it's
    /// finer-grained than the two buckets (AI feature vs. history wall)
    /// growth-strategy item 4 asked to split conversion by. Every call site
    /// used to just write bare `PaywallView()`; each one now names its own
    /// trigger explicitly. Defaults to `.settingsMenu` only because that's
    /// the one real call site with no more specific gate to name (a person
    /// browsing to Settings and tapping "Upgrade" directly, not blocked by
    /// anything) — every other call site passes its own real trigger and
    /// should never rely on this default.
    var trigger: AnalyticsManager.PaywallTrigger = .settingsMenu

    @Environment(\.dismiss) private var dismiss
    @State private var entitlements = EntitlementManager.shared
    @State private var selectedPlan: EntitlementManager.Plan = .annual
    @State private var isRestoring = false
    @State private var isPurchasing = false
    @State private var purchaseErrorMessage: String?
    /// Drives StoreKit's own native manage-subscriptions sheet — see
    /// `manageSubscriptionSection`'s comment for why that replaced the old
    /// `apps.apple.com` deep link.
    @State private var showingManageSubscriptions = false
    /// Trial-compression change, `Sustain-Subscription-Conversion-Research-2026-09.md`
    /// Part 8 item 3 — see the purchase button's success handler below for where this
    /// gets set, and `PostTrialAIPromptView` for what it presents.
    @State private var showingPostTrialAIPrompt = false

    /// Trial length now genuinely depends on which plan is selected (previously
    /// both plan buttons led to an identical `setPremium(true)` call regardless of
    /// `selectedPlan` — a documented gap in PROJECT_HANDOFF.md). Monthly gets a
    /// shorter trial than annual, matching the Headspace pattern RevenueCat cites
    /// (full-length trial on the plan you want people to commit to) and, as a
    /// second benefit, bounding how many people get a long free run of the
    /// AI features on the plan most prone to trial-and-cancel.
    private var selectedTrialLengthDays: Int {
        switch selectedPlan {
        case .monthly: return EntitlementManager.monthlyTrialLengthDays
        case .annual: return EntitlementManager.annualTrialLengthDays
        }
    }

    /// Real gap found capturing 2.1 screenshots: `EntitlementManager` forces
    /// `isPremium = true` under `SCREENSHOT_MODE` (so every gated feature
    /// renders unlocked for marketing shots), but that same override made
    /// this view's own `isPremium` branch always land on `manageView` —
    /// structurally making the acquisition pitch (the comparison table, the
    /// price-anchor line, all the paywall content actually worth
    /// screenshotting) unreachable through any normal navigation path while
    /// screenshot mode is on. This computed property is the one place that
    /// branch decision is made, so overriding it here — and nowhere else —
    /// keeps every other screenshot-mode override (unlocked features,
    /// fabricated data) completely untouched.
    private var showManageView: Bool {
        #if SCREENSHOT_MODE
        false
        #else
        entitlements.isPremium
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if showManageView {
                    manageView
                } else {
                    acquisitionView
                }
            }
            .navigationTitle("Sustain+")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        // Forced light only for the acquisition pitch, independent of system
        // appearance — see file-level note. Members get `nil`, i.e. follow the
        // system setting like every other screen, so opening "Manage" from a
        // dark-mode Settings screen doesn't flash to light and back.
        .preferredColorScheme(showManageView ? nil : .light)
        .alert("Couldn't complete purchase", isPresented: Binding(
            get: { purchaseErrorMessage != nil },
            set: { if !$0 { purchaseErrorMessage = nil } }
        )) {
            Button("OK") { purchaseErrorMessage = nil }
        } message: {
            Text(purchaseErrorMessage ?? "")
        }
        // Fires once per real appearance of the acquisition pitch — not for
        // `manageView` (an existing subscriber opening "Manage" isn't a
        // paywall "view" in the funnel sense growth-strategy item 4 means).
        // `.task` rather than `.onAppear` so a SwiftUI re-appearance from a
        // parent sheet dismiss/represent cycle can't double-fire mid-flight;
        // `.task` is cancelled and doesn't re-run on unrelated redraws the
        // way `.onAppear` can.
        .task {
            guard !showManageView else { return }
            AnalyticsManager.track(.paywallViewed(trigger: trigger))
            AnalyticsManager.recordPaywallTriggerForConversionAttribution(trigger)
        }
        .fullScreenCover(isPresented: $showingPostTrialAIPrompt, onDismiss: { dismiss() }) {
            PostTrialAIPromptView()
        }
    }

    private var acquisitionView: some View {
        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                header
                featureList
                comparisonTable
                planPicker
                trialTimeline
                subscriptionTermsCard
                footer
            }
            .padding()
            .padding(.bottom, 8)
            .readableContentWidth()
        }
        .background(Theme.screenBackground)
        .safeAreaInset(edge: .bottom) {
            subscribeSection
                .padding()
                .readableContentWidth()
                .background(.thinMaterial)
        }
        // Covers the case where the app's one launch-time offerings fetch (see
        // `EntitlementManager.ensureOfferingsLoaded()`) already failed by the time
        // someone opens this screen — retries as soon as the pitch appears rather
        // than waiting for a purchase attempt to discover pricing never loaded.
        // No-ops instantly if packages are already loaded, so this costs nothing on
        // the common path.
        .task { await entitlements.ensureOfferingsLoaded() }
    }

    private var manageView: some View {
        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.primary)
                    Text("You're a Sustain+ member")
                        .font(.title.bold())
                    Text("Full history, side-effect pattern reports, the AI photo estimate, and weekly recaps are all unlocked.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                subscriptionStatusCard

                if entitlements.isTrialing {
                    trialStatusCard
                }

                featureList

                VStack(spacing: 12) {
                    Text("Manage subscription")
                        .font(.headline)

                    // Sustain never handles cancellation itself, the same way it
                    // never handles payment info; both are strictly between the
                    // subscriber and Apple.
                    Text("You can view or cancel your subscription anytime in the App Store.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    // 2026-08-01: was `UIApplication.shared.open` on
                    // `apps.apple.com/account/subscriptions`, which kicks the
                    // person out of Sustain into the App Store app entirely.
                    // Apple's own account-deletion guidance names
                    // `showManageSubscriptions` as the preferred option on iOS
                    // 15+ and the URL only as the fallback for older systems —
                    // this app targets iOS 17+, so the fallback isn't needed.
                    // SwiftUI's `.manageSubscriptionsSheet` wraps the same
                    // StoreKit sheet and presents it inline, so someone
                    // cancelling lands back where they started instead of
                    // having to navigate back into the app.
                    //
                    // Note for testing: this sheet does nothing in the
                    // Simulator — it needs a real device with a real (or
                    // sandbox) App Store account, which is why the previous
                    // URL-based approach appeared to "work" in more places.
                    Button("Manage subscription") {
                        showingManageSubscriptions = true
                    }
                    .buttonStyle(.bordered)

                    Divider()

                    // Members need these as much as prospects do — 3.1.2(c) is about
                    // the app containing the links, and an existing subscriber
                    // reviewing what they agreed to shouldn't have to cancel out to
                    // Settings to find them.
                    LegalLinksFooter()
                }
                .cardStyle()
            }
            .padding()
            .readableContentWidth()
        }
        .background(Theme.screenBackground)
        .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
    }

    /// Shows what's actually happening with the subscription — renewing,
    /// cancelled-but-still-active, in a free trial, or stuck on a failed
    /// payment — plus the real date it changes.
    ///
    /// Added 2026-08-01. Before this, every member saw an identical "You're a
    /// Sustain+ member" screen with no dates and no renewal state, so someone
    /// who had already cancelled had no way to tell from inside Sustain that
    /// their access was ending, or when. Showing current status and the
    /// renewal/expiry date is standard practice across subscription apps, and
    /// it's the surface that makes a billing failure recoverable rather than
    /// silent — the subscriber is the only one who can fix a declined card.
    private var subscriptionStatusCard: some View {
        Group {
            if let title = entitlements.subscriptionStatusTitle,
               let detail = entitlements.subscriptionStatusDetail {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entitlements.subscriptionStatusNeedsAttention
                          ? "exclamationmark.triangle.fill"
                          : "arrow.triangle.2.circlepath")
                        .font(.title3)
                        .foregroundStyle(entitlements.subscriptionStatusNeedsAttention
                                         ? Theme.warning
                                         : Theme.primary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .cardStyle()
            }
        }
    }

    /// Surfaces the two things that actually change during a trial and would
    /// otherwise be invisible to the user: how many days are left, and how many
    /// AI calls remain against the trial's combined cap (see
    /// `EntitlementManager.trialAICallLimit`) — so hitting the cap in
    /// `handleAIEstimateTap`/`estimate(from:)` elsewhere in the app doesn't come
    /// as a surprise with nowhere to check it beforehand.
    private var trialStatusCard: some View {
        let dayNumber = min(
            entitlements.trialLengthDays,
            (Calendar.current.dateComponents([.day], from: entitlements.trialStartDate ?? .now, to: .now).day ?? 0) + 1
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text("Your trial")
                .font(.headline)
            HStack {
                Text("Day \(dayNumber) of \(entitlements.trialLengthDays)")
                Spacer()
                Text("\(entitlements.trialAICallsRemaining) AI calls left")
                    .foregroundStyle(entitlements.trialAICallsRemaining > 0 ? .secondary : Theme.danger)
            }
            .font(.subheadline)
        }
        .cardStyle()
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "leaf.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.primary)
            Text("Sustain+")
                .font(.title.bold())
            Text("Everything you need to protect your muscle through your whole GLP-1 journey.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Added 2026-09, deliberately placed FIRST — per
            // `Sustain-Subscription-Conversion-Research-2026-09.md` Part 12's
            // recommendation to headline this feature "not buried eighth." Every
            // other row below is a capability the user has to remember to go use;
            // this is the one thing Sustain does *to* them, proactively, which the
            // research doc's Part 10 argues is the strongest differentiator against
            // both a free competitor (Noom's GLP-1 companion, curated content only)
            // and a free generalist AI (ChatGPT/Google Health Coach, no persistent
            // access to this person's own logged history).
            featureRow(
                icon: "sparkle.magnifyingglass",
                title: "Pip notices patterns for you",
                detail: "Proactive notices — like a protein drop right after a dose increase — before you'd think to look"
            )
            featureRow(
                icon: "camera.fill",
                title: "Photo protein estimate",
                detail: "Snap a photo, get an instant protein estimate"
            )
            featureRow(
                icon: "chart.line.uptrend.xyaxis",
                title: "Full history & trends",
                detail: "See your entire journey, not just the last \(EntitlementManager.freeHistoryWindowDays) days"
            )
            featureRow(
                icon: "doc.text.magnifyingglass",
                title: "Side-effect pattern reports",
                detail: "Spot patterns across your whole history to discuss with your prescriber"
            )
            featureRow(
                icon: "text.bubble.fill",
                title: "Weekly AI recap",
                detail: "A short \"your week on Xmg\" summary of dose, protein, and weight"
            )
            // Three rows below added 2026-08-03 — this list had gone stale
            // relative to what `entitlements.isPremium` actually gates
            // (confirmed by grepping every real call site rather than
            // guessing): the AI chat coach, body composition, and progress
            // photos had all shipped since this list was last touched.
            featureRow(
                icon: "bubble.left.and.bubble.right.fill",
                title: "Ask Sustain",
                detail: "A conversational AI coach grounded in your own logged data"
            )
            featureRow(
                icon: "figure.arms.open",
                title: "Body composition trends",
                detail: "Body fat % and lean mass over time, synced from Apple Health"
            )
            featureRow(
                icon: "camera.on.rectangle.fill",
                title: "Progress photos",
                detail: "Compare any two photos side by side, with stats filled in for you"
            )
            featureRow(
                icon: "cross.case.fill",
                title: "Lab result tracking",
                detail: "Photograph a lab report and see your values trend over time"
            )
        }
        .cardStyle()
    }

    /// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §4c: a
    /// scannable Free-vs-Plus table is named across 2026 paywall teardowns
    /// (fitness, education, productivity, AI tools alike) as one of the most
    /// consistent additions to high-performing paywalls — it answers "wait,
    /// what do I actually get" without anyone having to leave this screen to
    /// find out. `featureList` above already covers what Sustain+ unlocks in
    /// prose form; this is deliberately terser and side-by-side rather than
    /// a redundant second prose list, since the whole point is a fast visual
    /// scan, not more reading.
    private var comparisonTable: some View {
        VStack(spacing: 0) {
            comparisonHeaderRow
            Divider()
            ForEach(Array(Self.comparisonRows.enumerated()), id: \.offset) { index, row in
                comparisonRow(row)
                if index < Self.comparisonRows.count - 1 {
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    private var comparisonHeaderRow: some View {
        HStack {
            Text("").frame(maxWidth: .infinity, alignment: .leading)
            Text("Free").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 56)
            Text("Plus").font(.caption.weight(.semibold)).foregroundStyle(Theme.primary).frame(width: 56)
        }
        .padding(.bottom, 8)
    }

    /// `plus` defaults to a checkmark, since Sustain+ is a strict superset of
    /// the free tier and most rows are a plain yes/no. It's still an explicit
    /// field rather than hardcoded: caught in pre-test audit, the history-window
    /// row read "30 days" under Free and a bare checkmark under Plus, which
    /// says nothing about what Plus actually gives you there.
    private struct ComparisonRow {
        let label: String
        let free: String
        var plus: String = "✓"
    }

    /// `static`, not a computed property — this was being rebuilt once per row
    /// by the `comparisonRows.count` reference inside its own ForEach body.
    private static let comparisonRows: [ComparisonRow] = [
        ComparisonRow(label: "Manual dose, weight & protein logging", free: "✓"),
        ComparisonRow(label: "History window", free: "\(EntitlementManager.freeHistoryWindowDays) days", plus: "All"),
        ComparisonRow(label: "AI photo protein estimate", free: "—"),
        ComparisonRow(label: "Weekly AI recap", free: "—"),
        ComparisonRow(label: "Ask Sustain (AI chat)", free: "—"),
        ComparisonRow(label: "Body composition trends", free: "—"),
        ComparisonRow(label: "Progress photos", free: "—"),
        ComparisonRow(label: "Lab result tracking", free: "—"),
        ComparisonRow(label: "Side-effect pattern reports", free: "—"),
    ]

    private func comparisonRow(_ row: ComparisonRow) -> some View {
        HStack {
            Text(row.label)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.free)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 56)
            Text(row.plus)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.primary)
                .frame(width: 56)
        }
        .padding(.vertical, 6)
    }

    private func featureRow(icon: String, title: String, detail: String, isComingSoon: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Muted, not brand-teal — keeps every icon here from competing with the CTA.
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if isComingSoon {
                        Text("SOON")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var planPicker: some View {
        VStack(spacing: 10) {
            planOption(
                .annual, price: entitlements.annualPriceString,
                subtitle: "Save \(entitlements.annualSavingsPercentString) vs. monthly · \(EntitlementManager.annualTrialLengthDays)-day trial",
                badge: "BEST VALUE",
                anchor: entitlements.annualPriceAnchorString
            )
            planOption(
                .monthly, price: entitlements.monthlyPriceString,
                subtitle: "Cancel anytime · \(EntitlementManager.monthlyTrialLengthDays)-day trial",
                badge: nil
            )
        }
    }

    // `anchor` added 2026-08-03 per the conversion report's §8 price-anchoring
    // finding — optional and defaults to nil so the monthly plan's call site
    // above is unaffected; only the annual option currently has a per-month
    // breakdown worth anchoring against.
    private func planOption(_ plan: EntitlementManager.Plan, price: String, subtitle: String, badge: String?, anchor: String? = nil) -> some View {
        let isSelected = selectedPlan == plan
        return Button {
            selectedPlan = plan
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(price).font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    if let anchor {
                        Text(anchor)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.primary)
                    }
                }
                Spacer()
                // The one place color signals state rather than draws attention —
                // selection feedback is functional, not persuasive, so it stays subtle
                // relative to the CTA below.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.primary : Color.secondary.opacity(0.5))
            }
            .padding()
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Theme.primary : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Transparent trial timeline instead of just a price — shows exactly what
    /// happens and when, which research on paywall clarity (Duolingo's own findings)
    /// found drives more conversions than persuasive copy. Same muted-icon
    /// treatment as everywhere else on this screen, so it doesn't compete with the CTA.
    private var trialTimeline: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How your trial works")
                .font(.headline)

            timelineStep(
                icon: "checkmark.circle.fill",
                title: "Today",
                detail: "Start your \(selectedTrialLengthDays)-day free trial: full access, nothing charged"
            )
            timelineStep(
                icon: "bell.fill",
                title: "Day \(max(1, selectedTrialLengthDays - 2))",
                detail: "We'll remind you before your trial ends, no surprise charge"
            )
            timelineStep(
                icon: "creditcard.fill",
                title: "Day \(selectedTrialLengthDays)",
                detail: "Your plan starts. Cancel anytime before this date and you won't be charged"
            )
        }
        .cardStyle()
    }

    private func timelineStep(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Everything App Store Guideline 3.1.2(c) requires to be visible inside the
    /// app's own purchase flow, in one block a reviewer can point at:
    /// subscription title, length, price, price per unit, and functional links to
    /// the Terms of Use (EULA) and Privacy Policy. v1.0(2) was rejected because
    /// these lived only in App Store Connect metadata, not in the app.
    ///
    /// Deliberately reflects `selectedPlan` rather than listing both plans
    /// statically — the disclosure should describe the thing the CTA below will
    /// actually purchase, not make the user work out which half applies to them.
    private var subscriptionTermsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Subscription details")
                .font(.headline)

            termsRow("Subscription", "Sustain+ \(selectedPlan == .annual ? "Annual" : "Monthly")")
            termsRow("Length", EntitlementManager.billingPeriodDescription(for: selectedPlan))

            // 3.1.2(c) asks specifically for "content or services provided during each
            // subscription period" alongside length and price, not just the length
            // itself — `featureList` above states this once for the pitch as a whole,
            // but the rejection quoted this phrase directly, so it's restated here,
            // explicitly tied to the period it recurs every cycle of, rather than left
            // to a reviewer to infer from a features list elsewhere on the screen.
            VStack(alignment: .leading, spacing: 2) {
                Text("Included every period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Full history & trends, AI photo protein estimate, side-effect pattern reports, weekly AI recap")
                    .font(.caption.weight(.semibold))
            }

            termsRow("Price", selectedPlan == .annual ? entitlements.annualPriceString : entitlements.monthlyPriceString)

            // Only meaningful for the annual plan (the monthly plan's price already
            // is its per-month price), and only once the real Offering has loaded —
            // see `annualPricePerMonthString`.
            if selectedPlan == .annual, let perMonth = entitlements.annualPricePerMonthString {
                termsRow("Price per month", "\(perMonth)/month, billed annually")
            }

            termsRow("Free trial", "\(selectedTrialLengthDays) days, then the price above")

            Text("\(EntitlementManager.renewalDescription(for: selectedPlan)) Payment is charged to your Apple ID at confirmation of purchase. Your subscription renews automatically unless auto-renew is turned off at least 24 hours before the end of the current period. Your account is charged for renewal within 24 hours before the end of the current period. You can manage or cancel your subscription in your Apple ID account settings after purchase.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Divider()

            LegalLinksFooter()
        }
        .cardStyle()
    }

    private func termsRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private var subscribeSection: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    isPurchasing = true
                    do {
                        try await entitlements.purchase(plan: selectedPlan)
                        // Top of growth-strategy item 4's funnel. Trial-to-
                        // paid conversion itself deliberately isn't tracked
                        // here or anywhere else in TelemetryDeck — see
                        // `AnalyticsManager.recordPaywallTriggerForConversionAttribution`'s
                        // doc comment for why that half already lives in
                        // RevenueCat's own native trial/conversion tracking.
                        AnalyticsManager.track(.trialStarted(trigger: trigger, plan: selectedPlan))
                        // Trial-compression change (research doc Part 8 item 3): if this
                        // person has never actually run the AI photo estimate — the
                        // feature this whole paywall's #1 row and the app's own "magic
                        // moment" positioning are built around — show them how right
                        // now, in this same session, instead of dismissing straight back
                        // to wherever they were and hoping they find the camera button
                        // on their own before the trial's Day-0 cancellation window
                        // closes. Skipped entirely for anyone who's already tried it —
                        // this is a first-time nudge, not a recurring interruption.
                        if !AIFeatureEngagementTracker.hasEverUsed(.proteinPhotoEstimate) {
                            showingPostTrialAIPrompt = true
                        } else {
                            dismiss()
                        }
                    } catch EntitlementManager.PurchaseError.userCancelled {
                        // Deliberate cancel — no error to show, just stay on the paywall.
                    } catch {
                        purchaseErrorMessage = error.localizedDescription
                    }
                    isPurchasing = false
                }
            } label: {
                if isPurchasing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                } else {
                    Text("Start \(selectedTrialLengthDays)-day free trial")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.primary)
            .controlSize(.large)
            .disabled(isPurchasing || isRestoring)

            Text("Cancel anytime before your trial ends and you won't be charged. Billed through your Apple ID.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Restore purchases") {
                Task {
                    isRestoring = true
                    let restored = await entitlements.restorePurchases()
                    isRestoring = false
                    if restored { dismiss() }
                }
            }
            .font(.caption)
            .tint(.secondary)
            .disabled(isPurchasing || isRestoring)

            // Repeated here as well as in `subscriptionTermsCard` on purpose: this
            // bar is pinned above the safe area and is the only part of the paywall
            // guaranteed to be on screen without scrolling, so the required 3.1.2(c)
            // links are reachable even if a reviewer never scrolls the pitch.
            LegalLinksFooter()
        }
    }

    private var footer: some View {
        Text("Manual dose, weight, and side-effect logging are always free. Sustain+ only unlocks deeper history and reporting.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

#Preview {
    PaywallView()
}
