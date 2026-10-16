import SwiftData
import SwiftUI

struct TrendsView: View {
    @Query(sort: \MedicationProfile.createdAt, order: .reverse) private var profiles: [MedicationProfile]
    @Query(sort: \WeightEntry.date) private var weightEntries: [WeightEntry]
    @Query(sort: \BodyCompositionEntry.date) private var bodyCompositionEntries: [BodyCompositionEntry]
    @Query(sort: \RecoveryEntry.date) private var recoveryEntries: [RecoveryEntry]
    @Query(sort: \ProteinEntry.date, order: .reverse) private var proteinEntries: [ProteinEntry]
    @Query(sort: \DoseLog.date, order: .reverse) private var doseLogs: [DoseLog]
    @Query(sort: \SideEffectLog.date, order: .reverse) private var sideEffectLogs: [SideEffectLog]
    // Added 2026-08-07 for `VisitReportCard` — the only reason this screen
    // needs its own query at all, since every other lab-result view/query
    // lives in `LabResultsView`.
    @Query(sort: \LabResultEntry.date, order: .reverse) private var labResults: [LabResultEntry]

    @AppStorage("weightUnitRaw") private var weightUnitRaw: String = WeightUnit.pounds.rawValue
    // Triage item 3 — see `MaintenanceGuideView.swift`'s header comment on
    // the same key for the full reasoning.
    @AppStorage("maintenanceGraduationModeEnabled") private var maintenanceModeEnabled = false
    @State private var entitlements = EntitlementManager.shared
    @State private var showingPaywall = false
    @State private var showingBodyScan = false
    /// This screen has three separate paywall entry points sharing one
    /// `showingPaywall` sheet (history/body-composition/recovery upsell
    /// cards) — each one sets this alongside `showingPaywall = true` so the
    /// single shared sheet still reports the right trigger.
    @State private var paywallTrigger: AnalyticsManager.PaywallTrigger = .historyWall

    private var profile: MedicationProfile? { profiles.first }
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .pounds }

    private var proteinGoal: Double {
        profile?.dailyProteinGoalGrams(fallbackWeightLbs: weightEntries.last?.weightLbs ?? 180) ?? 120
    }

    private var historyCutoff: Date? {
        guard !entitlements.isPremium else { return nil }
        return Calendar.current.date(byAdding: .day, value: -EntitlementManager.freeHistoryWindowDays, to: .now)
    }

    var body: some View {
        // Each list is filtered exactly once here and reused for both the "is
        // anything hidden" check and the child views below, instead of computed
        // properties that each independently re-filtered the full arrays (which
        // meant every one of these got scanned twice per render: once to build the
        // visible list, once again via `.contains` to decide whether to show the
        // upsell banner).
        let cutoff = historyCutoff
        let visibleWeightEntries = cutoff.map { c in weightEntries.filter { $0.date >= c } } ?? weightEntries
        let visibleProteinEntries = cutoff.map { c in proteinEntries.filter { $0.date >= c } } ?? proteinEntries
        let visibleSideEffectLogs = cutoff.map { c in sideEffectLogs.filter { $0.date >= c } } ?? sideEffectLogs
        let visibleDoseLogs = cutoff.map { c in doseLogs.filter { $0.date >= c } } ?? doseLogs
        let visibleLabResults = cutoff.map { c in labResults.filter { $0.date >= c } } ?? labResults
        // `visibleLabResults` was added 2026-08-07 for `VisitReportCard` but never
        // added here — caught in this session's bug sweep. Without it, a free user
        // whose only clipped history was lab results (e.g. logged 40+ days of lab
        // values but nothing else recently) never saw the "Showing your last N
        // days" upsell banner at all, even though real history was actually hidden.
        let hasHiddenHistory = cutoff != nil && (
            visibleWeightEntries.count != weightEntries.count
                || visibleProteinEntries.count != proteinEntries.count
                || visibleSideEffectLogs.count != sideEffectLogs.count
                || visibleLabResults.count != labResults.count
        )

        return NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    if let profile {
                        WeeklySummaryCard(input: ProgressCalculator.weeklySummaryInput(
                            profile: profile,
                            doseLogs: doseLogs,
                            weightEntries: weightEntries,
                            proteinEntries: proteinEntries,
                            sideEffectLogs: sideEffectLogs,
                            isInMaintenanceMode: maintenanceModeEnabled
                        ))
                    }

                    if hasHiddenHistory {
                        historyUpsellCard
                    }

                    // Added 2026-08-07, closing the gap
                    // `Sustain-Subscription-Payer-Features-Report-2026-08.md`
                    // §5 found: competitors export a combined doctor-visit
                    // PDF, Sustain's own export only ever covered side
                    // effects. Placed near the top, right after the weekly
                    // summary, since "get something to show my prescriber"
                    // is a task someone comes to this whole screen to do, not
                    // a footnote on any one chart. Uses the same
                    // entitlement-filtered `visible*` arrays every other card
                    // here already receives, not a fresh unfiltered query.
                    if let profile {
                        VisitReportCard(
                            profile: profile,
                            doseLogs: visibleDoseLogs,
                            weightEntries: visibleWeightEntries,
                            proteinEntries: visibleProteinEntries,
                            proteinGoalGrams: proteinGoal,
                            sideEffectLogs: visibleSideEffectLogs,
                            labResults: visibleLabResults,
                            weightUnit: weightUnit
                        )
                    }

                    WeightChartView(entries: visibleWeightEntries, unit: weightUnit)

                    // Gated behind Sustain+ entirely, not just the 30-day history
                    // window above — matching the Live Activity/widget's own gating
                    // and GLPzy's precedent (per
                    // Sustain-Subscription-Conversion-Report-2026-08.md) that a
                    // differentiated tracking view is reasonable to charge for.
                    if entitlements.isPremium {
                        BodyCompositionChartView(entries: bodyCompositionEntries)

                        // Added 2026-08-08, the buildable slice of the still-
                        // unbuilt full camera body scan (`Sustain-Remaining-
                        // Priorities-Scoping-2026-08.md`,
                        // `Sustain-Subscription-Payer-Features-Report-2026-08.md`
                        // §7 item 6). Placed directly under the chart it feeds,
                        // not as its own top-level nav-link card like Progress
                        // Photos/Lab Results — this is a quick "add a data point"
                        // action for the chart just above, not its own destination
                        // screen with a list to browse.
                        Button {
                            showingBodyScan = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "camera.viewfinder")
                                    .foregroundStyle(Theme.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Estimate with two photos")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("No smart scale? Get a rough AI estimate instead")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .cardStyle()
                    } else {
                        bodyCompositionUpsellCard
                    }

                    // Added 2026-08-07, closing
                    // `Sustain-Subscription-Payer-Features-Report-2026-08.md`
                    // §4's highest-priority new finding (Oura's GLP-1
                    // Insights precedent). Gated behind Sustain+ like body
                    // composition just above, matching the same
                    // "differentiated tracking view is reasonable to charge
                    // for" precedent.
                    if entitlements.isPremium {
                        RecoveryChartView(
                            entries: recoveryEntries,
                            doseDates: visibleDoseLogs.filter { !$0.skipped }.map(\.date),
                            // Added 2026-08-08, closing the rest of §4: the
                            // "simple observation" comparison that shipped
                            // without on 2026-08-07.
                            sideEffectDates: visibleSideEffectLogs.map(\.date)
                        )
                    } else {
                        recoveryUpsellCard
                    }

                    // Added 2026-08-03, comp-deep-dive §3b: a nav link rather than an
                    // inline card, since a photo grid (plus the compare flow) is its own
                    // whole screen, not a glanceable chart like everything else here.
                    NavigationLink {
                        ProgressPhotosView()
                    } label: {
                        HStack {
                            Image(systemName: "camera.on.rectangle.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Progress photos")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(entitlements.isPremium ? "Compare any two side by side" : "Sustain+ feature")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .cardStyle()
                    }
                    .buttonStyle(.plain)

                    // Added 2026-08-03, comp-deep-dive §6 — same nav-link pattern as
                    // the progress-photos card just above, for the same reason (its
                    // own list/import/trend screen, not a glanceable inline chart).
                    NavigationLink {
                        LabResultsView()
                    } label: {
                        HStack {
                            Image(systemName: "cross.case.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Lab results")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(entitlements.isPremium ? "Photograph a report, Sustain reads the values" : "Sustain+ feature")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .cardStyle()
                    }
                    .buttonStyle(.plain)

                    if let plateauMessage = ProgressCalculator.plateauMessage(weightEntries: weightEntries) {
                        PlateauInsightCard(message: plateauMessage)
                    }

                    // Only meaningful once someone has a real medication and at least
                    // one logged dose — `hasStartedMedication` guards the "haven't
                    // started yet" onboarding path, where `profile.medication` is a
                    // placeholder value, not a real answer.
                    if let profile, profile.hasStartedMedication {
                        MedicationLevelCard(
                            medication: profile.medication,
                            doseLogs: visibleDoseLogs,
                            days: cutoff != nil ? EntitlementManager.freeHistoryWindowDays : 42,
                            displayName: profile.displayMedicationName,
                            customHalfLifeHours: profile.customHalfLifeHours,
                            weightEntries: visibleWeightEntries,
                            // Added 2026-08-03 for the forward-projection feature — reuses
                            // the exact same "next due date" computation the Dashboard's
                            // countdown and Live Activity already rely on
                            // (`ProgressCalculator.nextDoseDate`), so the projection's
                            // assumed next dose can never silently disagree with what's
                            // shown as the next dose everywhere else in the app.
                            upcomingDose: (
                                date: ProgressCalculator.nextDoseDate(profile: profile, logs: doseLogs),
                                doseMg: profile.currentDoseMg
                            )
                        )
                    }

                    ProteinChartView(entries: visibleProteinEntries, goalGrams: proteinGoal, windowDays: 14)
                    SideEffectSummaryCard(logs: visibleSideEffectLogs)
                    doseHistorySection(visibleDoseLogs)
                }
                .padding()
                .readableContentWidth()
            }
            .background(Theme.screenBackground)
            .navigationTitle("Trends")
            .sheet(isPresented: $showingPaywall) {
                PaywallView(trigger: paywallTrigger)
            }
            .sheet(isPresented: $showingBodyScan) {
                BodyScanView()
            }
            // Same "stuck in light mode" fix as `ChatCoachView` — see that
            // file's comment for the full explanation.
            .preferredColorScheme(nil)
        }
    }

    private var historyUpsellCard: some View {
        Button {
            paywallTrigger = .historyWall
            showingPaywall = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Showing your last \(EntitlementManager.freeHistoryWindowDays) days")
                        .font(.subheadline.weight(.semibold))
                    Text("Unlock full history with Sustain+")
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

    private var bodyCompositionUpsellCard: some View {
        Button {
            paywallTrigger = .bodyComposition
            showingPaywall = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(Theme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Body composition tracking")
                        .font(.subheadline.weight(.semibold))
                    Text("See body fat % and lean mass trends with Sustain+")
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

    private var recoveryUpsellCard: some View {
        Button {
            paywallTrigger = .recovery
            showingPaywall = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bed.double.fill")
                    .foregroundStyle(Theme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sleep & recovery")
                        .font(.subheadline.weight(.semibold))
                    Text("See sleep and HRV trends alongside your dose days with Sustain+")
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

    private func doseHistorySection(_ visibleDoseLogs: [DoseLog]) -> some View {
        let recentDoseLogs = Array(visibleDoseLogs.prefix(10))

        return VStack(alignment: .leading, spacing: 12) {
            Text("Dose history")
                .font(.headline)

            if recentDoseLogs.isEmpty {
                Text("No doses logged yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentDoseLogs) { log in
                    doseRow(log)
                    if log.id != recentDoseLogs.last?.id {
                        Divider()
                    }
                }
            }
        }
        .cardStyle()
    }

    private func doseRow(_ log: DoseLog) -> some View {
        HStack {
            Image(systemName: log.skipped ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(log.skipped ? Theme.danger : Theme.success)

            VStack(alignment: .leading, spacing: 2) {
                Text(log.skipped ? "Skipped" : "\(log.doseMg.formatted(.number.precision(.fractionLength(0...2)))) mg")
                    .font(.subheadline.weight(.medium))
                if let site = log.injectionSite {
                    Text(site.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(log.date, format: .dateTime.month(.abbreviated).day())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    TrendsView()
        .modelContainer(for: [
            MedicationProfile.self, DoseLog.self, WeightEntry.self, ProteinEntry.self, SideEffectLog.self,
            BodyCompositionEntry.self, LabResultEntry.self, RecoveryEntry.self,
        ], inMemory: true)
}
