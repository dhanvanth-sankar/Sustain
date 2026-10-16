import SwiftUI

/// The user-facing citations screen required by App Store Guideline 1.4.1.
///
/// Reachable two ways, deliberately:
/// 1. Contextually, via `MedicalSourcesLink` placed directly beside every number the
///    app calculates (protein target, dose suggestions, maintenance range), opening
///    pre-scrolled to just that topic. This is the "easy for the user to find" half
///    of the requirement: the citation is one tap from the claim it supports.
/// 2. Globally, from Settings → "Medical sources & citations", showing every topic.
///
/// Sources themselves live in `MedicalSource.swift`.
struct MedicalSourcesView: View {
    /// When set, only this topic is shown (contextual entry). When nil, all topics
    /// are shown (Settings entry).
    var focusedTopic: MedicalSourceTopic?

    @Environment(\.dismiss) private var dismiss
    /// Only true when presented as a sheet — a pushed navigation entry already has
    /// a system back button and doesn't need a Done button too.
    var showsDoneButton = false

    private var topics: [MedicalSourceTopic] {
        if let focusedTopic { return [focusedTopic] }
        return MedicalSourceTopic.allCases
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                disclaimerCard

                ForEach(topics) { topic in
                    topicCard(topic)
                }

                Text("Links open in your browser. Prescribing information is published by each medication's manufacturer; research citations link to their PubMed records.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .readableContentWidth()
        }
        .background(Theme.screenBackground)
        .navigationTitle(focusedTopic?.rawValue ?? "Sources & citations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var disclaimerCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(MedicalSources.disclaimer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func topicCard(_ topic: MedicalSourceTopic) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(topic.rawValue)
                .font(.headline)

            Text(topic.explainer)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Guarded, not unconditional. `.labResults` (added 2026-08-03) is
            // the first topic with deliberately zero sources — see its entry
            // in `MedicalSource.swift` for why that's correct rather than a
            // gap — and an unconditional Divider left a dangling rule under
            // its explainer with nothing beneath it.
            if !MedicalSources.sources(for: topic).isEmpty {
                Divider()
            }

            ForEach(MedicalSources.sources(for: topic)) { source in
                Link(destination: source.url) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.citation)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 4) {
                            Text(source.supports)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption2)
                                .foregroundStyle(Theme.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if source.id != MedicalSources.sources(for: topic).last?.id {
                    Divider()
                }
            }
        }
        .cardStyle()
    }
}

/// The contextual "why this number?" affordance placed next to every calculated
/// health value. Small and quiet by design — it must be *findable*, not loud, and
/// it should never compete with the primary action on whatever card it sits in.
///
/// Presents as a sheet rather than a push because several of its call sites
/// (Dashboard cards, onboarding) have no navigation stack of their own.
struct MedicalSourcesLink: View {
    let topic: MedicalSourceTopic
    var label: String = "Why this number?"

    @State private var isShowingSources = false

    var body: some View {
        Button {
            isShowingSources = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                Text(label)
            }
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.primary)
        .sheet(isPresented: $isShowingSources) {
            NavigationStack {
                MedicalSourcesView(focusedTopic: topic, showsDoneButton: true)
            }
        }
    }
}

#Preview("All topics") {
    NavigationStack {
        MedicalSourcesView()
    }
}

#Preview("Single topic") {
    NavigationStack {
        MedicalSourcesView(focusedTopic: .proteinTarget)
    }
}
