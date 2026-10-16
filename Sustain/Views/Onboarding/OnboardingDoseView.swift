import SwiftUI

struct OnboardingDoseView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your current dose")
                        .font(.title2.bold())
                    Text("You can update this any time your prescriber adjusts your titration.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Button, not a passive note — see `SavedValueButton`'s
                    // doc comment.
                    if let saved = viewModel.savedDoseDisplay {
                        SavedValueButton(value: saved) {
                            viewModel.restoreDoseToSaved()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Dose")
                        Spacer()
                        Text("\(viewModel.currentDoseMg.formatted(.number.precision(.fractionLength(0...2)))) mg")
                            .font(.title3.monospacedDigit().bold())
                            .foregroundStyle(Theme.primary)
                    }

                    Slider(value: $viewModel.currentDoseMg, in: 0.25...15, step: 0.25)
                        .tint(Theme.primary)

                    HStack {
                        Text("0.25 mg")
                        Spacer()
                        Text("15 mg")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Start date")
                        .font(.headline)
                    DatePicker(
                        "First dose date",
                        selection: $viewModel.startDate,
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                }
                .cardStyle()
            }
            .padding()
            .readableContentWidth()
        }
    }
}

#Preview {
    OnboardingDoseView(viewModel: OnboardingViewModel())
}
