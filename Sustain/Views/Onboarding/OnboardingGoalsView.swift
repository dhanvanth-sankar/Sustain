import SwiftUI

struct OnboardingGoalsView: View {
    @Bindable var viewModel: OnboardingViewModel

    // The 0.8g-per-pound formula (matching MedicationProfile.dailyProteinGoalGrams)
    // is pounds-based, but the two weight fields hold whatever unit is currently
    // selected — converting to pounds here keeps this preview consistent with what
    // completeOnboarding() actually saves. Previously this multiplied the raw
    // on-screen number directly, so switching to kg showed a preview roughly
    // 2.2x too low relative to the value that would actually be stored.
    private var proteinGoalPreview: Double {
        let displayWeight = viewModel.hasTargetWeight ? viewModel.targetWeightLbs : viewModel.startingWeightLbs
        return (viewModel.poundsValue(displayWeight) * 0.8).rounded()
    }

    // The two `WeightWheelPicker`s below are plain numbers with no unit awareness
    // of their own — switching this segmented control used to just relabel them
    // (e.g. "180" while on "lb" would read "180 kg" after tapping "kg", rather
    // than converting to ~81.6), which is misleading on its own and, worse, would
    // silently corrupt the saved weight if the user didn't notice: completeOnboarding()
    // takes whatever's on the wheel at face value in the currently-selected unit.
    // Converting both fields' values here keeps what's displayed numerically
    // accurate through a unit switch.
    private var weightUnitBinding: Binding<WeightUnit> {
        Binding(
            get: { viewModel.weightUnit },
            set: { newUnit in
                let oldUnit = viewModel.weightUnit
                viewModel.startingWeightLbs = oldUnit.convert(viewModel.startingWeightLbs, to: newUnit)
                viewModel.targetWeightLbs = oldUnit.convert(viewModel.targetWeightLbs, to: newUnit)
                viewModel.weightUnit = newUnit
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your starting point")
                        .font(.title2.bold())
                    Text("Used to set your daily protein target, the single best lever for keeping the weight you lose as fat, not muscle.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Picker("Units", selection: weightUnitBinding) {
                        ForEach(WeightUnit.allCases) { unit in
                            Text(unit.abbreviation).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current weight")
                        // Scroll wheel, not a typed number (explicit
                        // request) — see `WeightWheelPicker`'s doc comment.
                        WeightWheelPicker(weight: $viewModel.startingWeightLbs, unit: viewModel.weightUnit)
                            .frame(maxWidth: .infinity)
                        // Button, not a passive note — see
                        // `SavedValueButton`'s doc comment.
                        if let saved = viewModel.savedStartingWeightDisplay {
                            SavedValueButton(value: saved) {
                                viewModel.restoreStartingWeightToSaved()
                            }
                        }
                    }

                    Divider()

                    Toggle("I have a goal weight", isOn: $viewModel.hasTargetWeight.animation())

                    if viewModel.hasTargetWeight {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Goal weight")
                            WeightWheelPicker(weight: $viewModel.targetWeightLbs, unit: viewModel.weightUnit)
                                .frame(maxWidth: .infinity)
                            if let saved = viewModel.savedTargetWeightDisplay {
                                SavedValueButton(value: saved) {
                                    viewModel.restoreTargetWeightToSaved()
                                }
                            }
                        }
                    }
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Daily protein target", systemImage: "fork.knife.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                    Text("\(Int(proteinGoalPreview))g / day")
                        .font(.title.bold())
                    Text("Based on ~0.8g of protein per pound of goal body weight (about 1.8g/kg), within the 1.2–2.0g/kg range recommended for people in an energy deficit. You can fine-tune this later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Guideline 1.4.1 — this is the first place a user ever sees a
                    // calculated protein number, so the citation belongs here too,
                    // not only on the Dashboard card it later appears on.
                    MedicalSourcesLink(topic: .proteinTarget, label: "See the sources for this")
                }
                .cardStyle()

                permissionsSection
            }
            .padding()
            .readableContentWidth()
        }
        .keyboardDoneButton()
        // The fixed Back/Continue bar (OnboardingFlow.navigationBar) sits outside
        // this ScrollView and isn't keyboard-aware itself — dragging to dismiss is
        // the other half of the fix alongside the "Done" button above, so a user
        // can get the keyboard out of the way without hunting for a specific
        // control once it's crowding the screen (PROJECT_HANDOFF.md §17, item 16).
        .scrollDismissesKeyboard(.interactively)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Reminders & Health sync", systemImage: "bell.badge.fill")
                .font(.headline)
            // Reworded 2026-08-03: this screen is no longer the last step (a
            // projection/plan-reveal step now follows it), so its button says
            // "Continue," not "Start," and the permission prompts now fire
            // from that next screen's finishing button instead. Saying
            // "tapping start" here pointed at a button that no longer exists
            // on this screen.
            Text("When you finish setup, Sustain will ask permission to send dose reminders and to sync weight and protein with Apple Health. Both are optional and can be changed later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

#Preview {
    OnboardingGoalsView(viewModel: OnboardingViewModel())
}
