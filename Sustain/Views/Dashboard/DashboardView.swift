import SwiftData
import SwiftUI
import UIKit

private enum DashboardSheet: Identifiable {
    case logDose, logWeight, logProtein, logSideEffect
    var id: Self { self }
}

/// A completed AI estimate waiting to be reviewed before it's saved — carries the
/// photo-derived values into LogProteinView rather than saving them unreviewed.
private struct PendingProteinEstimate: Identifiable {
    let id = UUID()
    let grams: Double
    let note: String
    let confidence: String
}

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MedicationProfile.createdAt, order: .reverse) private var profiles: [MedicationProfile]
    @Query(sort: \DoseLog.date, order: .reverse) private var doseLogs: [DoseLog]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]
    @Query(sort: \BodyCompositionEntry.date, order: .reverse) private var bodyCompositionEntries: [BodyCompositionEntry]
    @Query(sort: \RecoveryEntry.date, order: .reverse) private var recoveryEntries: [RecoveryEntry]
    @Query(sort: \ProteinEntry.date, order: .reverse) private var proteinEntries: [ProteinEntry]
    @Query(sort: \SideEffectLog.date, order: .reverse) private var sideEffectLogs: [SideEffectLog]

    @AppStorage("weightUnitRaw") private var weightUnitRaw: String = WeightUnit.pounds.rawValue

    // Tracks the highest streak milestone already celebrated with a sheet, so the
    // same milestone doesn't pop up again every time the dashboard re-renders —
    // only a *newly crossed* milestone should trigger `celebratingMilestone`.
    // See `StreakMilestone.swift` for why this exists as its own moment instead
    // of just the quieter always-visible label already in `ProteinRingCard`.
    @AppStorage("highestCelebratedStreakMilestone") private var highestCelebratedStreakMilestoneRaw: Int = 0
    @State private var celebratingMilestone: StreakMilestone?

    // Behavior-change layer, added 2026-08-07 — see `StreakResetView.swift`'s
    // header comment for the full reasoning. Tracks the streak length as of
    // the last time this check ran, so a *drop* (not just the current value)
    // can be detected; `checkForStreakReset()` is the only place either of
    // these is written.
    @AppStorage("lastKnownProteinStreakDays") private var lastKnownProteinStreakDays: Int = 0
    @State private var showingStreakReset = false
    @State private var streakResetPreviousDays = 0

    @State private var activeSheet: DashboardSheet?
    @State private var entitlements = EntitlementManager.shared
    @State private var showingMaintenanceOffer = false
    @State private var showingMaintenanceGuide = false

    @State private var showingPaywall = false
    /// Separate from `showingPaywall` above deliberately — that one is hardcoded to
    /// `.aiPhotoEstimate` at its own sheet site and shared by two call sites that are
    /// both genuinely that trigger (the AI estimate card, the trial-limit alert). Reusing
    /// it here would mislabel every pattern-detection paywall view as an AI-photo-estimate
    /// one in analytics, which is exactly the kind of drift `AnalyticsManager.PaywallTrigger`
    /// was built to prevent.
    @State private var showingPatternPaywall = false
    /// Computed once per relevant data change (see the `.onChange` below), not on every
    /// body evaluation — `PatternDetectionEngine` is cheap, but there's no reason to
    /// re-run it on every SwiftUI re-render when dose/weight/protein logs are the only
    /// thing that can actually change its output.
    @State private var unseenPattern: PatternDetectionEngine.DetectedPattern?
    @State private var showingAISourceDialog = false
    @State private var aiPickerSource: ImagePickerSource?
    @State private var isEstimatingFromDashboard = false
    @State private var pendingEstimate: PendingProteinEstimate?
    @State private var showingDashboardEstimateError = false
    @State private var dashboardEstimateErrorMessage = ""
    @State private var showingAddMedication = false
    @State private var showingTrialLimitAlert = false
    /// Added 2026-09-27 — see `LifeAfterGLP1View`'s header comment. Separate from
    /// `showingMaintenanceGuide` deliberately: they're two different life stages
    /// (still on medication vs. stopped) with different content, even though both
    /// are reached from a similarly-shaped Dashboard teaser card.
    @State private var showingLifeAfterGLP1 = false
    // comp-022 in sustain-pros-and-cons.json — see `ChatCoachView.swift`.
    @State private var showingChatCoach = false

    private var profile: MedicationProfile? { profiles.first }
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .pounds }

    private var recentWeightEntries: [WeightEntry] {
        Array(weightEntries.prefix(30))
    }

    /// True once the user's latest logged weight has reached (or passed) their
    /// goal — the "what now?" moment the maintenance-program upsell targets.
    private var hasReachedGoalWeight: Bool {
        guard let target = profile?.targetWeightLbs, let latest = weightEntries.first?.weightLbs else { return false }
        return latest <= target
    }

    // Same inputs and same call as the `ProteinRingCard` instantiation below —
    // pulled into its own property so `.onChange` (and the milestone check it
    // drives) has something concrete to watch without duplicating the
    // `ProgressCalculator` call inline in a modifier.
    private var currentStreakDays: Int {
        guard let profile else { return 0 }
        return ProgressCalculator.proteinGoalStreak(
            proteinEntries: proteinEntries,
            goalGrams: profile.dailyProteinGoalGrams(fallbackWeightLbs: weightEntries.first?.weightLbs ?? 180)
        )
    }

    /// Drives `CompanionCard` — see `CompanionEngagement.swift`'s header comment
    /// for why this only ever looks at *whether* something was logged, never at
    /// a weight or dose-adherence outcome.
    private var companionMood: CompanionMood {
        CompanionEngagement.mood(
            doseLogs: doseLogs,
            proteinEntries: proteinEntries,
            weightEntries: weightEntries,
            sideEffectLogs: sideEffectLogs
        )
    }

    // Fires the celebration sheet the first time (and only the first time) a
    // streak crosses into a new `StreakMilestone` tier. Called both on appear
    // (covers the case where the qualifying log happened in a previous session,
    // e.g. logging protein then closing the app) and on every change to the
    // streak count itself.
    private func checkForNewStreakMilestone() {
        guard let milestone = StreakMilestone.highestReached(forStreakDays: currentStreakDays) else { return }
        guard milestone.rawValue > highestCelebratedStreakMilestoneRaw else { return }
        highestCelebratedStreakMilestoneRaw = milestone.rawValue
        celebratingMilestone = milestone
    }

    /// Counterpart to `checkForNewStreakMilestone()` above — fires
    /// `StreakResetView` the first time a streak that had already reached at
    /// least a week (i.e. was ever worth celebrating) drops back down. A
    /// streak of, say, 2 or 3 days resetting isn't flagged — matching
    /// `StreakMilestone.week`'s own bar for "meaningful enough to say
    /// something about" keeps this from feeling naggy on the ordinary,
    /// unremarkable gaps that happen constantly and don't need a whole sheet
    /// acknowledging them. `lastKnownProteinStreakDays` is updated
    /// unconditionally on every call (via `defer`) so this only ever fires
    /// once per genuine drop, not on every subsequent appearance while the
    /// streak stays at its new, lower value.
    private func checkForStreakReset() {
        defer { lastKnownProteinStreakDays = currentStreakDays }
        guard currentStreakDays < lastKnownProteinStreakDays else { return }
        guard lastKnownProteinStreakDays >= StreakMilestone.week.rawValue else { return }
        streakResetPreviousDays = lastKnownProteinStreakDays
        showingStreakReset = true
    }

    /// Re-runs `PatternDetectionEngine` and updates `unseenPattern` with whatever's
    /// actually new, per `PatternNoticeStore`. This runs for every user, free or
    /// premium — see `PatternNoticeCard`'s header comment for why the *detection* is
    /// never itself gated (it isn't AI, it's arithmetic over data the person already
    /// logged), only the detail/notification is.
    ///
    /// Only ever surfaces the single highest-priority unseen pattern at a time
    /// (`.first`), not a stack of cards — this app's whole dashboard philosophy is
    /// calm, not a notification-center pileup, and `PatternDetectionEngine` already
    /// orders its own output by specificity for exactly this reason.
    private func refreshUnseenPattern() {
        let detected = PatternDetectionEngine.detectPatterns(
            doseLogs: doseLogs,
            proteinEntries: proteinEntries,
            weightEntries: weightEntries,
            profile: profile
        )
        let unseen = PatternNoticeStore.unseenPatterns(from: detected)
        guard let newPattern = unseen.first else { return }
        // Only fires once per pattern instance, the moment it's first computed as
        // unseen — `unseenPattern` being non-nil already means this exact one was
        // logged this session, so re-running (e.g. from the weight-entry `.onChange`
        // firing right after the dose-log one) can't double-count it.
        if unseenPattern?.stableKey != newPattern.stableKey {
            AnalyticsManager.track(.patternDetected(kind: newPattern.kind, isPremium: entitlements.isPremium))
            // Proactive notification is premium-only and scheduled, not immediate —
            // see `NotificationManager.schedulePatternNotification`'s own doc comment
            // for why a next-morning nudge, not a push while the app is already open
            // and showing the same card in front of the user right now.
            if entitlements.isPremium {
                NotificationManager.shared.schedulePatternNotification(title: newPattern.title)
            }
        }
        unseenPattern = newPattern
    }

    // Keeps the Lock Screen Live Activity and the home screen widget in sync
    // with whatever's actually been logged. Triggered from `.onChange` on the
    // two `@Query` arrays that feed it (below) rather than from inside each
    // logging sheet's own `save()` — one call site here covers every way a
    // dose or protein entry can change (manual log, HealthKit sync, Supabase
    // sync) instead of needing to be threaded through each of them individually.
    // See `LiveActivityManager.swift`'s header comment for why this is gated
    // behind Sustain+ and why it's safe to call unconditionally here.
    private func refreshLiveActivity() {
        guard let profile else { return }
        LiveActivityManager.shared.refresh(
            profile: profile,
            doseLogs: doseLogs,
            proteinEntries: proteinEntries,
            weightFallbackLbs: weightEntries.first?.weightLbs ?? 180
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    if let profile {
                        if profile.hasStartedMedication {
                            if profile.isDiscontinued {
                                // Report finding (§15): most GLP-1 patients eventually
                                // stop, usually for cost/coverage reasons, and every
                                // reviewed competitor treats that as churn rather than
                                // a life stage to support. `NextDoseCard`/
                                // `TitrationScheduleCard` would be actively wrong to
                                // show here (there's no next dose), so this replaces
                                // them the same way `StartMedicationCard` replaces them
                                // for the "haven't started yet" case above.
                                lifeAfterGLP1Card
                            } else {
                                NextDoseCard(
                                    profile: profile,
                                    nextDoseDate: ProgressCalculator.nextDoseDate(profile: profile, logs: doseLogs),
                                    onLogDose: { activeSheet = .logDose }
                                )

                                if profile.hasPendingTitration {
                                    TitrationScheduleCard(profile: profile, onApply: { applyTitration(profile) })
                                }
                            }
                        } else {
                            StartMedicationCard(onAddMedication: { showingAddMedication = true })
                        }

                        // Sustain's mascot — see `CompanionCharacterView.swift`'s header
                        // comment and `Sustain-Companion-Character-Research-2026-08.md`
                        // for the full reasoning. Placed right after the dose card (the
                        // one piece of medical-safety information that has to stay the
                        // very first thing on screen) and before the AI upsell cards, so
                        // Pip reads as the app's actual personality rather than another
                        // feature tile competing with them.
                        //
                        // Also now Sustain's entry point into the AI chat coach — see
                        // `CompanionCard`'s own doc comment for why the old standalone
                        // `chatCoachCard` tile that used to sit here was removed rather
                        // than kept alongside it. comp-022 in sustain-pros-and-cons.json
                        // still names the underlying feature; only how it's *reached* changed.
                        CompanionCard(mood: companionMood, isPremium: entitlements.isPremium) {
                            showingChatCoach = true
                        }

                        // `Sustain-Subscription-Conversion-Research-2026-09.md` Part 10 —
                        // the one proactive (not reactive) premium capability in the app.
                        // Placed right after Pip, before the AI estimate upsell, since a
                        // real detected pattern is more specific/urgent than a generic
                        // feature pitch when one exists; entirely absent from the layout
                        // when `unseenPattern` is nil, matching every other conditional
                        // card on this screen.
                        if let unseenPattern {
                            PatternNoticeCard(
                                pattern: unseenPattern,
                                isPremium: entitlements.isPremium,
                                onUpgrade: {
                                    AnalyticsManager.track(.paywallViewed(trigger: .patternDetection))
                                    showingPatternPaywall = true
                                },
                                onDismiss: {
                                    PatternNoticeStore.markSeen(unseenPattern.stableKey)
                                    AnalyticsManager.track(.patternDismissed(kind: unseenPattern.kind))
                                    self.unseenPattern = nil
                                },
                                onMute: {
                                    PatternNoticeStore.markSeen(unseenPattern.stableKey)
                                    PatternNoticeStore.mute(kind: unseenPattern.kind)
                                    AnalyticsManager.track(.patternMuted(kind: unseenPattern.kind))
                                    self.unseenPattern = nil
                                }
                            )
                        }

                        aiEstimateCard

                        ProteinRingCard(
                            consumedGrams: ProgressCalculator.todaysTotal(proteinEntries),
                            goalGrams: profile.dailyProteinGoalGrams(fallbackWeightLbs: weightEntries.first?.weightLbs ?? 180),
                            streakDays: ProgressCalculator.proteinGoalStreak(
                                proteinEntries: proteinEntries,
                                goalGrams: profile.dailyProteinGoalGrams(fallbackWeightLbs: weightEntries.first?.weightLbs ?? 180)
                            ),
                            onLogProtein: { activeSheet = .logProtein }
                        )

                        WeightTrendCard(
                            entries: recentWeightEntries,
                            unit: weightUnit,
                            onLogWeight: { activeSheet = .logWeight }
                        )

                        if hasReachedGoalWeight {
                            maintenanceCard
                        }

                        quickLogRow

                        if !sideEffectLogs.isEmpty {
                            recentSideEffectsCard
                        }
                    } else {
                        ProgressView("Loading your plan…")
                            .padding(.top, 80)
                    }
                }
                .padding()
                .readableContentWidth()
            }
            .background(Theme.screenBackground)
            .navigationTitle("Today")
            .task {
                if let profile {
                    WatchSyncManager.drainPendingDoseLogs(profile: profile, modelContext: modelContext)
                }
                await syncHealthKitEntries()
                await syncCloudIfSignedIn()
            }
            .onAppear {
                checkForNewStreakMilestone()
                checkForStreakReset()
                refreshUnseenPattern()
            }
            .onChange(of: currentStreakDays) { _, _ in
                checkForNewStreakMilestone()
                checkForStreakReset()
            }
            .onChange(of: doseLogs) { _, _ in refreshUnseenPattern() }
            .onChange(of: proteinEntries) { _, _ in refreshUnseenPattern() }
            .onChange(of: weightEntries) { _, _ in refreshUnseenPattern() }
            .task {
                LiveActivityManager.shared.reattachToRunningActivityIfNeeded()
                refreshLiveActivity()
            }
            .onChange(of: doseLogs) { _, _ in refreshLiveActivity() }
            .onChange(of: proteinEntries) { _, _ in refreshLiveActivity() }
            .sheet(item: $activeSheet) { sheet in
                sheetView(for: sheet)
            }
            .sheet(item: $celebratingMilestone) { milestone in
                StreakMilestoneCelebrationView(milestone: milestone) {
                    celebratingMilestone = nil
                }
            }
            .sheet(isPresented: $showingStreakReset) {
                StreakResetView(previousStreakDays: streakResetPreviousDays) {
                    showingStreakReset = false
                }
            }
            .sheet(isPresented: $showingAddMedication) {
                if let profile {
                    MedicationProfileEditView(profile: profile)
                }
            }
            .sheet(isPresented: $showingMaintenanceOffer) {
                MaintenancePhaseView()
            }
            .sheet(isPresented: $showingChatCoach) {
                if let profile {
                    ChatCoachView(profile: profile)
                }
            }
            .sheet(isPresented: $showingMaintenanceGuide) {
                // MaintenanceGuideView no longer wraps itself in a
                // NavigationStack (that broke its other call site, the
                // NavigationLink push from SettingsView) — as a sheet it
                // needs its own stack and an explicit Close button, since
                // sheets don't get an automatic back button.
                NavigationStack {
                    MaintenanceGuideView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showingMaintenanceGuide = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingLifeAfterGLP1) {
                if let profile {
                    NavigationStack {
                        LifeAfterGLP1View(profile: profile)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Close") { showingLifeAfterGLP1 = false }
                                }
                            }
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(trigger: .aiPhotoEstimate)
            }
            .sheet(isPresented: $showingPatternPaywall) {
                PaywallView(trigger: .patternDetection)
            }
            // Same "stuck in light mode" fix as `ChatCoachView` — see that
            // file's comment for the full explanation.
            .preferredColorScheme(nil)
            .sheet(item: $pendingEstimate) { estimate in
                LogProteinView(initialGrams: estimate.grams, initialNote: estimate.note, initialConfidence: estimate.confidence)
            }
            .confirmationDialog("Estimate protein from a photo", isPresented: $showingAISourceDialog, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") { aiPickerSource = ImagePickerSource(sourceType: .camera) }
                }
                Button("Choose from Library") { aiPickerSource = ImagePickerSource(sourceType: .photoLibrary) }
                Button("Cancel", role: .cancel) {}
            }
            // Real bug, reported directly from a device screenshot: this
            // rendered as a small floating popover with an arrow near the
            // top of the screen instead of a full-width bottom sheet. Same
            // fix already applied once in `SettingsView.swift` (see its own
            // comment on this exact modifier) — without it, SwiftUI can
            // render `confirmationDialog` via popover adaptation instead of
            // a sheet. Sustain is iPhone-only so this should never actually
            // be needed by size class alone, but forcing it removes any
            // doubt regardless of what triggered the misrender.
            .presentationCompactAdaptation(.sheet)
            .fullScreenCover(item: $aiPickerSource) { source in
                if source.sourceType == .camera {
                    CameraCaptureView { image in
                        Task { await estimateFromDashboard(image) }
                    }
                    .ignoresSafeArea()
                } else {
                    ImagePicker(sourceType: source.sourceType) { image, _ in
                        Task { await estimateFromDashboard(image) }
                    }
                    .ignoresSafeArea()
                }
            }
            .alert("Couldn't estimate protein", isPresented: $showingDashboardEstimateError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(dashboardEstimateErrorMessage)
            }
            .alert("Trial AI limit reached", isPresented: $showingTrialLimitAlert) {
                Button("Upgrade") { showingPaywall = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You've used all \(EntitlementManager.trialAICallLimit) AI estimates included in your trial. Subscribe to keep using photo estimates and weekly recaps.")
            }
        }
    }

    /// Top-of-screen placement is deliberate, not incidental — this is the report's
    /// named "magic moment" feature and its whole monetization thesis, so it gets the
    /// most valuable real estate on the app's most-visited screen. Free users tap
    /// straight into the paywall rather than a softer "learn more" state, matching the
    /// report's own conversion data (hard paywall triggers convert far better than
    /// discovery-gated features).
    private var aiEstimateCard: some View {
        Button {
            handleAIEstimateTap()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.primaryLight)
                        .frame(width: 44, height: 44)
                    Image(systemName: "camera.fill")
                        .foregroundStyle(Theme.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("AI Photo Estimate")
                            .font(.subheadline.weight(.semibold))
                        if !entitlements.isPremium {
                            Text("SUSTAIN+")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                    }
                    Text("Snap a photo of your food for an instant protein estimate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isEstimatingFromDashboard {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            // Explicit request: tapping anywhere on the tile should trigger
            // it, not just the icon/text. The `Spacer()` above already makes
            // this `HStack` span the tile's full width, but SwiftUI only
            // treats a view as tappable where it actually draws something —
            // the `Spacer()`'s own region (and the gap around the trailing
            // chevron) is empty space, invisible to hit-testing by default
            // regardless of layout width. `.contentShape(Rectangle())`
            // explicitly declares the *whole* rectangular frame as the tap
            // target, transparent regions included.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEstimatingFromDashboard)
        .cardStyle()
    }

    /// Pulls in weight/protein samples HealthKit has that Sustain didn't write itself
    /// — e.g. a smart-scale weigh-in, or protein logged in another app — so the
    /// permission screen's "without double entry" promise is actually true. Runs on
    /// every Dashboard appearance rather than a background observer for simplicity;
    /// the watermark (latest existing entry date) keeps repeat runs cheap and
    /// prevents re-importing the same sample twice.
    private func syncHealthKitEntries() async {
        guard HealthKitManager.shared.isAuthorized else { return }

        let fallbackSince = profile?.startDate ?? Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let weightSince = weightEntries.first?.date ?? fallbackSince
        let proteinSince = proteinEntries.first?.date ?? fallbackSince
        // Body composition entries are a Sustain+ feature (see `TrendsView`'s
        // gating), but importing them here unconditionally is harmless and
        // actually the simpler choice: the data is just sitting unused in
        // SwiftData for a free-tier user until/unless they subscribe, exactly
        // like how full history keeps accumulating for everyone regardless of
        // whether the free-tier 30-day window currently shows it.
        let bodyCompositionSince = bodyCompositionEntries.first?.date ?? fallbackSince
        // Same "harmless to import unconditionally, gated at the display
        // layer instead" reasoning as body composition above — see
        // `RecoveryChartView`'s Sustain+ gating in `TrendsView`.
        let recoverySince = recoveryEntries.first?.date ?? fallbackSince

        async let externalWeights = HealthKitManager.shared.fetchExternalWeightSamples(since: weightSince)
        async let externalProteins = HealthKitManager.shared.fetchExternalProteinSamples(since: proteinSince)
        async let externalBodyFat = HealthKitManager.shared.fetchExternalBodyFatSamples(since: bodyCompositionSince)
        async let externalLeanMass = HealthKitManager.shared.fetchExternalLeanMassSamples(since: bodyCompositionSince)
        async let externalSleep = HealthKitManager.shared.fetchExternalSleepSamples(since: recoverySince)
        async let externalHRV = HealthKitManager.shared.fetchExternalHRVSamples(since: recoverySince)
        async let externalRestingHR = HealthKitManager.shared.fetchExternalRestingHeartRateSamples(since: recoverySince)
        let (weights, proteins, bodyFatSamples, leanMassSamples) = await (externalWeights, externalProteins, externalBodyFat, externalLeanMass)
        let (sleepSamples, hrvSamples, restingHRSamples) = await (externalSleep, externalHRV, externalRestingHR)

        guard !weights.isEmpty || !proteins.isEmpty || !bodyFatSamples.isEmpty || !leanMassSamples.isEmpty
            || !sleepSamples.isEmpty || !hrvSamples.isEmpty || !restingHRSamples.isEmpty else { return }

        for sample in weights {
            modelContext.insert(WeightEntry(date: sample.date, weightLbs: sample.pounds, source: .healthKit))
        }
        for sample in proteins {
            modelContext.insert(ProteinEntry(date: sample.date, grams: sample.grams, note: "Imported from Health", source: .healthKit))
        }
        // Body fat and lean mass usually arrive as separate HealthKit samples
        // (most scales write them independently, even from the same weigh-in),
        // so each becomes its own `BodyCompositionEntry` rather than trying to
        // pair them up by matching timestamps — `BodyCompositionChartView`
        // already filters each metric's own chart to only the entries that
        // have that specific field set, so two entries on the same day (one
        // with body fat, one with lean mass) render correctly as two points.
        for sample in bodyFatSamples {
            modelContext.insert(BodyCompositionEntry(date: sample.date, bodyFatPercent: sample.percent, source: .healthKit))
        }
        for sample in leanMassSamples {
            modelContext.insert(BodyCompositionEntry(date: sample.date, leanMassLbs: sample.pounds, source: .healthKit))
        }
        // Same independent-samples reasoning as body fat/lean mass above:
        // sleep, HRV, and resting heart rate each arrive as their own
        // HealthKit samples (an Apple Watch writes HRV/resting-HR daily
        // regardless of whether sleep tracking happened that night), so each
        // becomes its own `RecoveryEntry` rather than trying to merge them
        // by date — `RecoveryChartView` filters each metric's own chart to
        // entries that actually have that field set.
        for sample in sleepSamples {
            modelContext.insert(RecoveryEntry(date: sample.date, sleepHours: sample.hours))
        }
        for sample in hrvSamples {
            modelContext.insert(RecoveryEntry(date: sample.date, hrvMilliseconds: sample.milliseconds))
        }
        for sample in restingHRSamples {
            modelContext.insert(RecoveryEntry(date: sample.date, restingHeartRateBPM: sample.bpm))
        }
        try? modelContext.save()
    }

    /// Keeps a signed-in account's cloud data current automatically, using the
    /// exact same "run on every Dashboard appearance" trigger
    /// `syncHealthKitEntries()` already established above — no separate
    /// background-sync scheduling infrastructure needed, just piggybacking on
    /// the one screen every session predictably passes through on launch.
    /// A no-op for anyone not signed in, which is the default for most users
    /// since account sync is opt-in, so this costs nothing for the common
    /// case. Failures are swallowed here deliberately, same reasoning as
    /// `syncHealthKitEntries()`'s own best-effort framing: `CloudSyncManager
    /// .lastSyncError` already surfaces the most recent failure inline in
    /// Settings -> Account & sync, so a second error alert on every Dashboard
    /// appearance would be redundant, and — for a background action nobody
    /// explicitly triggered — more annoying than helpful.
    private func syncCloudIfSignedIn() async {
        // Real crash found capturing 2.1 screenshots: `ScreenshotModeSeeder` wipes
        // and re-fabricates local data on every launch (see its header comment),
        // but this sync call was never guarded against `SCREENSHOT_MODE` — so on
        // a signed-in account with real cloud history, this pulled the real data
        // straight back down over the freshly-seeded fake dataset moments later,
        // via `CloudSyncManager.apply`'s upsert-and-save. That's a silent
        // data-clobbering bug even when it doesn't crash (the seeded Wegovy
        // journey would just get overwritten by real Rybelsus data seconds after
        // launch), and here it escalated to a genuine `context.save()` abort,
        // presumably from the merge conflicting with objects the seeder had just
        // inserted/deleted on the same context. Skipping this entirely under
        // `SCREENSHOT_MODE` matches the same isolation `EntitlementManager`
        // already uses for its own screenshot override — never compiled into a
        // Release build, so this can't affect real users' sync.
        #if SCREENSHOT_MODE
        return
        #else
        guard AuthManager.shared.isSignedIn else { return }
        try? await CloudSyncManager.shared.syncNow(context: modelContext)
        #endif
    }

    private func applyTitration(_ profile: MedicationProfile) {
        profile.applyPlannedTitration()
        try? modelContext.save()
        CloudSyncManager.shared.syncSoon(context: modelContext)
        NotificationManager.shared.cancelTitrationReminder()
    }

    private func handleAIEstimateTap() {
        guard entitlements.isPremium else {
            showingPaywall = true
            return
        }
        // A trialing user can still be `isPremium` but have exhausted the trial's
        // AI call cap (see EntitlementManager.canUseAIFeature) — a full paying
        // subscriber outside a trial is never blocked here.
        guard entitlements.canUseAIFeature else {
            showingTrialLimitAlert = true
            AnalyticsManager.track(.aiScanBlockedTrialLimit(feature: .proteinPhotoEstimate))
            return
        }
        showingAISourceDialog = true
    }

    private func estimateFromDashboard(_ image: UIImage) async {
        isEstimatingFromDashboard = true
        defer { isEstimatingFromDashboard = false }
        do {
            let result = try await AIProteinEstimator.estimateProtein(from: image)
            entitlements.recordAIUsage()
            AIFeatureEngagementTracker.recordUse(.proteinPhotoEstimate)
            AnalyticsManager.track(.aiScanCompleted(feature: .proteinPhotoEstimate))
            pendingEstimate = PendingProteinEstimate(grams: result.grams, note: result.foodDescription, confidence: result.confidence)
        } catch {
            dashboardEstimateErrorMessage = error.localizedDescription
            showingDashboardEstimateError = true
        }
    }

    private var maintenanceCard: some View {
        Button {
            if entitlements.hasMaintenanceProgram {
                showingMaintenanceGuide = true
            } else {
                showingMaintenanceOffer = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You've reached your goal weight!")
                        .font(.subheadline.weight(.semibold))
                    Text(entitlements.hasMaintenanceProgram ? "Open your Maintenance Guide" : "See the Sustain+ Maintenance Program")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    /// The Dashboard teaser for a discontinued profile — always free to open (see
    /// `LifeAfterGLP1View`'s header comment for why), so this is a plain
    /// button-styled card, not a paywall entry point like `aiEstimateCard`.
    private var lifeAfterGLP1Card: some View {
        Button {
            AnalyticsManager.track(.lifeAfterGLP1Viewed)
            showingLifeAfterGLP1 = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.primaryLight)
                        .frame(width: 44, height: 44)
                    Image(systemName: "leaf.arrow.circlepath")
                        .foregroundStyle(Theme.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Life After GLP-1")
                        .font(.subheadline.weight(.semibold))
                    Text("Support for staying on track without medication")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    private var quickLogRow: some View {
        Button {
            activeSheet = .logSideEffect
        } label: {
            Label("Log a side effect", systemImage: "bandage.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Theme.warning)
        .controlSize(.regular)
    }

    private var recentSideEffectsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent side effects")
                .font(.subheadline.weight(.semibold))
            ForEach(sideEffectLogs.prefix(3)) { log in
                HStack {
                    Image(systemName: log.symptom.systemImage)
                        .foregroundStyle(Theme.warning)
                    Text(log.symptom.displayName)
                        .font(.footnote)
                    Spacer()
                    Text(log.date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func sheetView(for sheet: DashboardSheet) -> some View {
        switch sheet {
        case .logDose:
            if let profile {
                LogDoseView(profile: profile)
            }
        case .logWeight:
            LogWeightView(weightUnit: weightUnit)
        case .logProtein:
            LogProteinView()
        case .logSideEffect:
            LogSideEffectView()
        }
    }
}

#Preview {
    DashboardView()
        .modelContainer(for: [
            MedicationProfile.self, DoseLog.self, WeightEntry.self, ProteinEntry.self, SideEffectLog.self,
            BodyCompositionEntry.self, RecoveryEntry.self,
        ], inMemory: true)
}
