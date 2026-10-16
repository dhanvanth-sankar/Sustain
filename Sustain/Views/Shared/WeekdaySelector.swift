import SwiftUI

/// A row of seven tappable day chips for `DoseFrequency.specificDays`
/// schedules (e.g. Mon/Wed/Fri) — added 2026-08-01, explicit request: every
/// currently-approved GLP-1 is once-daily or once-weekly, but a compounded/
/// custom program can prescribe an exact-days schedule neither of those
/// represents. Bound directly to `MedicationProfile.scheduledWeekdays` (via
/// `OnboardingViewModel`'s own copy during onboarding, or a local draft in
/// `MedicationProfileEditView`), so no separate day-name-to-model mapping
/// exists anywhere else.
///
/// Uses Calendar's own weekday numbering (1 = Sunday ... 7 = Saturday)
/// directly as the `Set<Int>` element type — matching
/// `DoseFrequency.nextDueDate(after:scheduledWeekdays:)` and
/// `MedicationProfile.scheduledWeekdays` exactly, so nothing here needs to
/// convert between a UI-only day representation and the model's. Always
/// shown Sunday-first regardless of the user's locale-preferred first day of
/// week — a deliberate simplification, not a localization gap fix waiting to
/// happen: the important thing is that whichever days are shown map
/// correctly to the same weekdays `nextDueDate` reasons about, and Calendar's
/// own numbering is what guarantees that.
struct WeekdaySelector: View {
    @Binding var selectedWeekdays: Set<Int>

    private static let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { weekday in
                dayButton(weekday)
            }
        }
    }

    private func dayButton(_ weekday: Int) -> some View {
        let isSelected = selectedWeekdays.contains(weekday)
        let symbol = Self.symbols.indices.contains(weekday - 1) ? Self.symbols[weekday - 1] : "?"
        return Button {
            if isSelected {
                selectedWeekdays.remove(weekday)
            } else {
                selectedWeekdays.insert(weekday)
            }
        } label: {
            Text(symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(isSelected ? Theme.primary : Theme.cardBackground)
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.2))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct WeekdaySelectorPreview: View {
    @State private var selected: Set<Int> = [2, 4, 6]
    var body: some View {
        WeekdaySelector(selectedWeekdays: $selected)
            .padding()
    }
}

#Preview {
    WeekdaySelectorPreview()
}
