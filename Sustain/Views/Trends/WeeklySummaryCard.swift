import SwiftData
import SwiftUI

/// The report's named "your week on 5mg" recap. Gated behind Sustain+, same
/// hard-paywall-on-tap pattern as the Dashboard's AI photo card (free users go
/// straight to the paywall, no soft "learn more" state — see Decision 13 in
/// the project handoff for why that convention exists).
///
/// Placed as the first card in Trends: this is a subscriber-value feature, so
/// like the AI photo card on Dashboard, it gets the most visible spot on its
/// tab rather than being buried under the charts.
struct WeeklySummaryCard: View {
    let input: WeeklySummaryInput

    // Added 2026-08-03: this card previously had no access to lab results at
    // all — see `WeeklySummaryGenerator.buildPrompt(_:labResults:)`'s doc
    // comment for the guardrails that came with wiring it in. Queried here,
    // not passed in via `input`, since `WeeklySummaryInput` is shared with
    // `AIChatCoachService` and deliberately kept free of this feature's own
    // concerns (see that struct's and `buildPrompt`'s comments).
    @Query(sort: \LabResultEntry.date, order: .reverse) private var labResults: [LabResultEntry]

    // Stored as JSON-encoded [WeeklyInsight] rather than plain text now that
    // the recap is 3 titled findings instead of one sentence pair — see
    // WeeklySummaryGenerator's header comment for why the format changed.
    @AppStorage("weeklySummaryInsightsJSON") private var insightsJSON: String = ""
    @AppStorage("weeklySummaryGeneratedAt") private var generatedAtRaw: Double = 0

    private var insights: [WeeklyInsight] {
        guard let data = insightsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WeeklyInsight].self, from: data)) ?? []
    }

    @State private var entitlements = EntitlementManager.shared
    @State private var showingPaywall = false
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var generatedAt: Date? {
        generatedAtRaw > 0 ? Date(timeIntervalSince1970: generatedAtRaw) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your week")
                    .font(.headline)
                Spacer()
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

            content

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
            }
        }
        .cardStyle()
        .sheet(isPresented: $showingPaywall) {
            PaywallView(trigger: .aiWeeklyRecap)
        }
        // Same "stuck in light mode" fix as `ChatCoachView` — see that
        // file's comment for the full explanation.
        .preferredColorScheme(nil)
    }

    @ViewBuilder
    private var content: some View {
        if !entitlements.isPremium {
            Text("Get a short weekly recap of your dose adherence, protein, and weight trend.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Unlock with Sustain+") { showingPaywall = true }
                .buttonStyle(.bordered)
                .tint(Theme.primary)
        } else if isGenerating {
            HStack(spacing: 8) {
                ProgressView()
                Text("Writing your recap…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if !insights.isEmpty {
            // The numbers themselves are computed client-side and always accurate,
            // so they're rendered directly as a scannable table rather than asked of
            // the AI in prose — a full paragraph restating every figure was hard to
            // skim. The insights below are the actual AI output.
            statsGrid

            // Explicit "AI-generated" label directly on the content itself, not just
            // in marketing copy elsewhere — this is the actual AI output Apple expects
            // to be disclosed as such, distinct from the separate "non-diagnostic"
            // medical disclaimer below.
            Label("AI-generated insights", systemImage: "sparkles")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            // 3 titled findings rather than one sentence pair — a plain-text
            // recap with a hard word cap read as thin for a paid feature; a
            // short titled list reads as an actual analysis. See
            // WeeklySummaryGenerator for the full rationale.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(insights) { insight in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.primary)
                        Text(insight.detail)
                            .font(.subheadline)
                    }
                }
            }
            // The disclaimer the comment above has always referred to as "below"
            // did not actually exist in this file — the AI-generated label was
            // present but the medical disclaimer next to the AI's health commentary
            // was not. Added here because Guideline 1.4.1 scrutiny applies most
            // directly to exactly this: model-written interpretation of a user's
            // own health data, shown without a visible non-diagnostic caveat.
            Text("These findings describe your own logged data. They are not a diagnosis and not medical advice. Talk to your prescriber before changing anything about your treatment.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            MedicalSourcesLink(topic: .muscleLoss, label: "Our sources & citations")

            HStack {
                if let generatedAt {
                    Text("Generated \(generatedAt, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await generate() } }
                    .font(.caption)
            }
        } else {
            Text("A scannable recap of your last 7 days: dose adherence, protein average, and weight trend, plus 3 non-diagnostic AI findings on what it means.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Get your week in review") { Task { await generate() } }
                .buttonStyle(.bordered)
                .tint(Theme.primary)
        }
    }

    /// The week's actual figures, laid out as an aligned two-column table rather
    /// than left to the AI to narrate in prose. This data is all deterministic
    /// (pre-computed by `ProgressCalculator.weeklySummaryInput`), so showing it
    /// directly is both easier to skim and can never be misstated by the model.
    private var statsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Doses").foregroundStyle(.secondary)
                Text(input.dosesSkipped > 0
                     ? "\(input.dosesLogged)/\(input.dosesExpected) taken (\(input.dosesSkipped) skipped)"
                     : "\(input.dosesLogged)/\(input.dosesExpected) taken")
            }
            GridRow {
                Text("Protein").foregroundStyle(.secondary)
                Text("\(Int(input.averageDailyProteinGrams.rounded()))g avg / \(Int(input.proteinGoalGrams.rounded()))g goal")
            }
            GridRow {
                Text("Weight").foregroundStyle(.secondary)
                if let change = input.weightChangeLbs {
                    let sign = change > 0 ? "+" : ""
                    Text("\(sign)\(change.formatted(.number.precision(.fractionLength(0...1)))) lb")
                } else {
                    Text("Not enough weigh-ins")
                }
            }
            if !input.topSideEffects.isEmpty {
                GridRow {
                    Text("Side effects").foregroundStyle(.secondary)
                    Text(input.topSideEffects.map { "\($0.symptom) (\($0.count)x)" }.joined(separator: ", "))
                }
            }
        }
        .font(.subheadline)
    }

    private func generate() async {
        // A trialing user can still be `isPremium` but have exhausted the trial's
        // combined AI call cap (shared with the photo estimate — see
        // EntitlementManager.canUseAIFeature). A full paying subscriber outside a
        // trial is never blocked here. Reuses the existing inline `errorMessage`
        // display rather than a separate alert — this card lives inline in a
        // scroll view, not a full sheet, so a caption reads more naturally here.
        guard entitlements.canUseAIFeature else {
            errorMessage = "You've used all \(EntitlementManager.trialAICallLimit) AI calls included in your trial. Subscribe to keep getting weekly recaps and photo estimates."
            AnalyticsManager.track(.aiScanBlockedTrialLimit(feature: .weeklyRecap))
            return
        }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            let result = try await WeeklySummaryGenerator.generateSummary(for: input, labResults: labResults)
            let data = try JSONEncoder().encode(result)
            insightsJSON = String(data: data, encoding: .utf8) ?? ""
            entitlements.recordAIUsage()
            AIFeatureEngagementTracker.recordUse(.weeklyRecap)
            AnalyticsManager.track(.aiScanCompleted(feature: .weeklyRecap))
            generatedAtRaw = Date.now.timeIntervalSince1970
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    WeeklySummaryCard(input: WeeklySummaryInput(
        medicationName: "Rybelsus",
        currentDoseMg: 7,
        dosesLogged: 6,
        dosesSkipped: 1,
        dosesExpected: 7,
        averageDailyProteinGrams: 118,
        proteinGoalGrams: 128,
        weightChangeLbs: -1.4,
        topSideEffects: [(symptom: "Nausea", count: 2)],
        previousWeekAverageDailyProteinGrams: 132,
        previousWeekWeightChangeLbs: -1.0,
        proteinGoalStreakDays: 2,
        isPlateaued: false
    ))
    .padding()
    // Added for the new `@Query` above — this view previously had none, so
    // the preview never needed a model container at all.
    .modelContainer(for: [LabResultEntry.self], inMemory: true)
}
