import SwiftUI

/// Shown only when `ProgressCalculator.plateauMessage` detects a stall. Deliberately
/// separate from `WeeklySummaryCard`'s AI-generated insight: this is a fully
/// deterministic, always-available signal that shouldn't depend on an AI call
/// succeeding, a trial cap having room left, or the weekly recap having been
/// generated at all.
struct PlateauInsightCard: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "figure.mind.and.body")
                .font(.title3)
                .foregroundStyle(Theme.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("Holding steady")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }
}

#Preview {
    PlateauInsightCard(
        message: "Your weight has held steady over the last few weeks. Plateaus like "
            + "this are a normal part of GLP-1 treatment, often reflecting water "
            + "retention or a temporary metabolic adjustment rather than treatment no "
            + "longer working."
    )
    .padding()
}
