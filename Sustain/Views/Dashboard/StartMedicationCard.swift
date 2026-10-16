import SwiftUI

/// Replaces `NextDoseCard` on the Dashboard when someone came through the
/// "I haven't started yet" onboarding path. There's nothing to count down to
/// without a real dose, so this is a standing prompt instead of a countdown —
/// tapping it opens the same `MedicationProfileEditView` used for routine plan
/// edits, which is also what flips `hasStartedMedication` to true on save.
struct StartMedicationCard: View {
    let onAddMedication: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.primaryLight)
                        .frame(width: 44, height: 44)
                    Image(systemName: "pills.fill")
                        .foregroundStyle(Theme.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Haven't started yet?")
                        .font(.subheadline.weight(.semibold))
                    Text("Track your weight and protein now. Add your medication whenever you begin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button(action: onAddMedication) {
                Label("Add medication", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.primary)
        }
        .cardStyle()
    }
}

#Preview {
    StartMedicationCard(onAddMedication: {})
        .padding()
}
