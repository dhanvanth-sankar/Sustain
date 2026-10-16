import SwiftUI

struct OnboardingMedicationView: View {
    @Bindable var viewModel: OnboardingViewModel

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What are you taking?")
                        .font(.title2.bold())
                    Text(viewModel.medicationWasPrefilled
                        ? "This matches what's already saved to your account: change it if anything's out of date."
                        : "This sets sensible defaults you can adjust on the next screen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Button, not a passive note (2026-08-01): shows the
                    // saved medication and, on tap, restores it — see
                    // `SavedValueButton`'s doc comment for why this replaced
                    // the earlier read-only badge.
                    if let saved = viewModel.savedMedicationDisplay {
                        SavedValueButton(value: saved) {
                            viewModel.restoreMedicationToSaved()
                        }
                    }
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(MedicationOption.allCases) { option in
                        medicationButton(option)
                    }
                }

                // Only meaningful once "Custom" is actually selected — comp-010
                // in `sustain-pros-and-cons.json`: Pokii lets users add a fully
                // custom medication, one of its most-requested features. The
                // half-life field is optional (a custom compound might not have
                // one to enter), matching `.other`'s existing "chart just doesn't
                // render" behavior when left blank.
                if viewModel.hasStartedMedication, viewModel.medication == .custom {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Custom medication")
                            .font(.headline)
                        TextField("Medication name", text: $viewModel.customMedicationName)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Text("Half-life (days)")
                            Spacer()
                            TextField("Optional", value: $viewModel.customHalfLifeDays, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                        Text("Only used for the optional medication-level estimate in Trends. Leave blank if you don't know it.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .cardStyle()
                }

                notStartedButton

                if viewModel.hasStartedMedication {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Form & schedule")
                            .font(.headline)

                        Picker("Form", selection: $viewModel.form) {
                            ForEach(MedicationForm.allCases) { form in
                                Text(form.displayName).tag(form)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Frequency", selection: $viewModel.frequency) {
                            ForEach(DoseFrequency.allCases) { frequency in
                                Text(frequency.displayName).tag(frequency)
                            }
                        }
                        .pickerStyle(.segmented)

                        // Only relevant for a compounded/custom program on an
                        // exact-days schedule (Mon/Wed/Fri, etc.) — every
                        // currently-approved GLP-1 is once-daily or
                        // once-weekly, so this stays hidden for the common
                        // case. See `WeekdaySelector`'s doc comment.
                        if viewModel.frequency == .specificDays {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Which days?")
                                    .font(.subheadline.weight(.medium))
                                WeekdaySelector(selectedWeekdays: $viewModel.scheduledWeekdays)
                            }
                        }

                        // Real gap, reported directly: the combined "Saved:
                        // ___" button above (medication grid) already covers
                        // form/frequency, but that's easy to miss once
                        // you've scrolled down to this separate card — shown
                        // here too, right next to the controls it actually
                        // applies to, matching every other field on this
                        // screen (see `OnboardingViewModel
                        // .savedFormFrequencyDisplay`'s doc comment).
                        if let saved = viewModel.savedFormFrequencyDisplay {
                            SavedValueButton(value: saved) {
                                viewModel.restoreFormFrequencyToSaved()
                            }
                        }
                    }
                    .cardStyle()
                }
            }
            .padding()
            .readableContentWidth()
        }
    }

    /// Lets someone still considering treatment (or waiting on a prescription)
    /// through onboarding without a real medication answer — previously there was
    /// no way past this screen without picking one, even fictitiously.
    private var notStartedButton: some View {
        let isSelected = !viewModel.hasStartedMedication
        return Button {
            withAnimation { viewModel.skipMedication() }
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.primary : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("I haven't started yet")
                        .font(.subheadline.weight(.medium))
                    Text("Track your weight and protein now. Add your medication whenever you begin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Theme.primary : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func medicationButton(_ option: MedicationOption) -> some View {
        // Also requires `hasStartedMedication` so this and "I haven't started yet"
        // are never both shown as selected at once — `medication` keeps whatever
        // value it last had even after skipping, since it's meaningless until
        // `hasStartedMedication` flips back to true.
        let isSelected = viewModel.hasStartedMedication && viewModel.medication == option
        return Button {
            withAnimation { viewModel.selectMedication(option) }
        } label: {
            Text(option.rawValue)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, 8)
                .background(isSelected ? Theme.primary : Theme.cardBackground)
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.2))
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    OnboardingMedicationView(viewModel: OnboardingViewModel())
}
