import SwiftData
import SwiftUI

/// The dedicated support surface for someone who has marked that they've stopped
/// their GLP-1 medication — see `MedicationProfile.isDiscontinued`'s doc comment
/// and `Sustain-GLP1-Market-PESTLE-FeatureGap-Report-2026-09.md` §15 for the full
/// reasoning behind why this exists as its own mode rather than nothing at all.
///
/// The report's evidence is blunt: nearly three in four GLP-1 patients discontinue
/// within two years, usually for cost or coverage reasons rather than the
/// medication failing, and every reviewed competitor (Noom, PlateLens, ChatGPT
/// Health, Google Health Coach, the long-tail shot trackers) treats that moment as
/// churn — the user simply leaves the product. This view is Sustain's answer:
/// staying useful, warmly, for the population the whole category currently drops.
///
/// **Deliberately entirely free, not a Sustain+ gate.** Two reasons, both load-
/// bearing: first, cost/insurance loss is the dominant reason people end up here in
/// the first place (per the same report), so putting a paywall in front of the one
/// feature built specifically for a population that's already losing purchasing
/// power would be tone-deaf and directly against `PROJECT_HANDOFF.md` §2's
/// trust-first posture. Second, free + genuinely useful + shareable is itself the
/// growth lever — this view (and the info card below specifically) is built to be
/// the kind of thing someone screenshots and sends to a friend, which is worth more
/// to user acquisition than gating it ever could be. Only the proactive
/// regain-risk *detection* detail/notification (`PatternDetectionEngine
/// .detectPostDiscontinuationRegain`, surfaced via the existing `PatternNoticeCard`)
/// stays behind the same premium gate every other pattern-detection insight already
/// uses — consistent, not a new exception.
struct LifeAfterGLP1View: View {
    let profile: MedicationProfile

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]

    @AppStorage("weightUnitRaw") private var weightUnitRaw: String = WeightUnit.pounds.rawValue
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .pounds }

    @State private var showingResumeConfirmation = false
    @State private var shareCardImage: Image?

    private let conversationPrompts = [
        "Given why I stopped, is restarting an option worth discussing?",
        "Would a taper, rather than stopping outright, make sense for me going forward?",
        "What signs would suggest I should restart sooner rather than later?",
        "How should my protein or calorie targets change now that I'm not on medication?",
    ]

    private var weightChangeSinceStoppingLbs: Double? {
        guard let discontinuedDate = profile.discontinuedDate else { return nil }
        let since = weightEntries.filter { $0.date >= discontinuedDate }.sorted { $0.date < $1.date }
        guard let first = since.first, let last = since.last, first.id != last.id else { return nil }
        return last.weightLbs - first.weightLbs
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                summaryCard
                proteinReminderCard
                whatToExpectCard
                insuranceInfoCard
                conversationGuideCard
                resumeCard
            }
            .padding()
            .readableContentWidth()
        }
        .background(Theme.screenBackground)
        .navigationTitle("Life After GLP-1")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Taking medication again?", isPresented: $showingResumeConfirmation) {
            Button("Yes, I'm taking it again") {
                profile.resumeMedication()
                try? modelContext.save()
                CloudSyncManager.shared.syncSoon(context: modelContext)
                AnalyticsManager.track(.medicationResumedAfterDiscontinuation)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This brings back your dose reminders and titration tracking. You can update your medication plan afterward if anything's changed.")
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Since stopping \(profile.displayMedicationName)")
                .font(.headline)

            if let days = profile.daysSinceDiscontinued {
                Text("\(days) day\(days == 1 ? "" : "s")")
                    .font(.title2.bold())
            }

            if let change = weightChangeSinceStoppingLbs {
                let displayChange = WeightUnit.pounds.convert(abs(change), to: weightUnit)
                Label(
                    change > 0
                        ? "\(displayChange.formatted(.number.precision(.fractionLength(0...1)))) \(weightUnit.abbreviation) since stopping"
                        : "Holding steady or down \(displayChange.formatted(.number.precision(.fractionLength(0...1)))) \(weightUnit.abbreviation)",
                    systemImage: change > 0 ? "arrow.up.circle.fill" : "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(change > 0 ? Theme.warning : Theme.success)
            }

            Text("This isn't a failure state, and Sustain isn't going anywhere now that you've stopped. Protein and weight tracking still help, maybe more than ever.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var proteinReminderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protein still matters")
                .font(.headline)
            Text("Your daily target stays at \(Int(profile.dailyProteinGoalGrams(fallbackWeightLbs: weightEntries.first?.weightLbs ?? 180)))g — muscle preservation doesn't stop mattering just because the medication did, especially in the months right after stopping.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var whatToExpectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What the evidence says")
                .font(.headline)
            Text("Weight regain after stopping a GLP-1 is common and well documented, it's not a sign you did anything wrong.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            MedicalSourcesLink(topic: .discontinuation, label: "See the source")
        }
        .cardStyle()
    }

    /// The report's "quick traction win" — see this file's header comment and
    /// `Sustain-GLP1-Market-PESTLE-FeatureGap-Report-2026-09.md`'s Economic section
    /// for the underlying appeal-success statistics. Framed as "worth knowing," not
    /// as advice to appeal a specific denial (this app gives no legal or insurance
    /// advice), and built to be shared: most people don't know these numbers, and a
    /// surprising, genuinely useful fact is exactly the kind of thing that travels
    /// on its own, which is the whole point of making this free and shareable
    /// rather than another paywalled insight.
    private var insuranceInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(Theme.primary)
                Text("Worth knowing")
                    .font(.headline)
            }

            Text("If cost or coverage played a part in stopping, most people never appeal a coverage denial, but appeals succeed far more often than most people expect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("This isn't insurance or legal advice, just a fact worth knowing before deciding not to appeal.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let shareCardImage {
                ShareLink(
                    item: shareCardImage,
                    preview: SharePreview("Worth knowing about GLP-1 coverage appeals", image: shareCardImage)
                ) {
                    Label("Share this", systemImage: "square.and.arrow.up")
                }
                .font(.subheadline.weight(.medium))
                .simultaneousGesture(TapGesture().onEnded {
                    AnalyticsManager.track(.insuranceInfoCardShared)
                })
            }
        }
        .cardStyle()
        .task {
            if shareCardImage == nil {
                shareCardImage = ShareCardRenderer.render(
                    title: "Appeals succeed more than you'd think",
                    subtitle: "Most people never appeal a GLP-1 coverage denial, but a large share of appeals that are actually filed succeed."
                )
            }
        }
    }

    private var conversationGuideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before your next appointment")
                .font(.headline)

            ForEach(conversationPrompts, id: \.self) { prompt in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bubble.left.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    Text(prompt)
                        .font(.subheadline)
                }
            }

            Text("These are discussion starters, not medical advice. Only your prescriber can guide whether or how to restart.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .cardStyle()
    }

    private var resumeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Taking it again?")
                .font(.headline)
            Text("If you've restarted, or you're about to, update your status here to bring back dose reminders.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("I'm taking medication again") {
                showingResumeConfirmation = true
            }
            .buttonStyle(.bordered)
            .tint(Theme.primary)
        }
        .cardStyle()
    }
}

#Preview {
    NavigationStack {
        LifeAfterGLP1View(profile: {
            let profile = MedicationProfile(medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5)
            profile.markDiscontinued(reason: .cost)
            return profile
        }())
    }
    .modelContainer(for: [MedicationProfile.self, WeightEntry.self], inMemory: true)
}
