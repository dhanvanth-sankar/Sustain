import SwiftData
import SwiftUI

/// comp-013 in `sustain-pros-and-cons.json`: Pokii offers a "relative" check-in
/// (better/same/worse than last time) as a lower-friction alternative to
/// assigning an absolute number — this view now offers both, defaulting to
/// relative whenever there's a prior log for the same symptom to compare
/// against (a first-ever log for a symptom has nothing to be relative to, so
/// the absolute slider is the only option that makes sense there).
private enum SeverityInputMode: String, CaseIterable, Identifiable {
    case relative = "Compare to last time"
    case absolute = "Rate severity"
    var id: String { rawValue }
}

struct LogSideEffectView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Only needed to find the most recent log of whichever symptom is
    // selected, for the relative "better/same/worse" comparison below — this
    // view never displayed or otherwise needed side-effect history before.
    @Query(sort: \SideEffectLog.date, order: .reverse) private var existingLogs: [SideEffectLog]

    @State private var date: Date = .now
    @State private var symptom: SideEffectSymptom?
    @State private var severity: Double = 3
    @State private var notes: String = ""
    @State private var inputMode: SeverityInputMode = .relative
    @State private var relativeChoice: RelativeSeverityChoice?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var canSave: Bool {
        guard symptom != nil else { return false }
        // Relative mode requires an actual choice — unlike the slider, which
        // always has *some* value the instant a symptom is picked, there's no
        // sensible default "better/same/worse" to silently save if nobody taps
        // one.
        return inputMode == .absolute || relativeChoice != nil
    }

    /// The most recent existing log for whichever symptom is currently
    /// selected — `nil` for a symptom being logged for the first time, which
    /// is exactly the signal used to fall back to the absolute slider.
    private var lastLogForSymptom: SideEffectLog? {
        guard let symptom else { return nil }
        return existingLogs.first { $0.symptom == symptom }
    }

    // The slider itself stays continuous (no `step`) so it tracks the finger smoothly —
    // a stepped slider only has 5 possible thumb positions, which combined with a Form's
    // own scroll-gesture recognizer competing for the touch is what read as "buggy" /
    // laggy. The value is only rounded to a whole number here, at the edges (display,
    // haptic, save), so dragging still feels responsive while the stored severity stays
    // an integer 1–5 like before.
    private var severityLevel: Int { Int(severity.rounded()) }

    private var severityLabel: String { SeverityLabel.text(for: severityLevel) }

    /// The severity value actually saved, computed from whichever input mode is
    /// active. In relative mode this is the last log's severity nudged by one
    /// step (clamped to the same 1-5 range the slider already uses) rather than
    /// the "true" 1-5 scale being reinterpreted — "worse" always means one step
    /// up from wherever the symptom was last logged, regardless of the absolute
    /// number that happens to be.
    private var resolvedSeverityLevel: Int {
        guard inputMode == .relative, let relativeChoice, let last = lastLogForSymptom else {
            return severityLevel
        }
        let delta: Int
        switch relativeChoice {
        case .better: delta = -1
        case .same: delta = 0
        case .worse: delta = 1
        }
        return min(5, max(1, last.severity + delta))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Date & time", selection: $date, in: ...Date.now)
                }

                Section("Symptom") {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(SideEffectSymptom.allCases) { option in
                            symptomButton(option)
                        }
                    }
                    .padding(.vertical, 6)
                }

                if symptom != nil {
                    Section("Severity") {
                        if lastLogForSymptom != nil {
                            Picker("How to log", selection: $inputMode) {
                                ForEach(SeverityInputMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        if inputMode == .relative, lastLogForSymptom != nil {
                            relativeSeverityPicker
                        } else {
                            absoluteSeveritySlider
                        }
                    }

                    Section("Notes") {
                        HStack(alignment: .top) {
                            TextField("Optional notes", text: $notes, axis: .vertical)
                                .lineLimit(2...4)
                            // comp-027: hands-free logging option.
                            VoiceInputButton(text: $notes)
                        }
                    }
                }
            }
            .navigationTitle("Log side effect")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: symptom) { _, _ in
                // A fresh symptom selection means a fresh comparison target —
                // clearing this also re-evaluates `lastLogForSymptom`/default
                // mode for whatever was just picked, instead of carrying over
                // a choice that was relative to a *different* symptom's history.
                relativeChoice = nil
                inputMode = lastLogForSymptom != nil ? .relative : .absolute
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func symptomButton(_ option: SideEffectSymptom) -> some View {
        let isSelected = symptom == option
        return Button {
            symptom = option
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.systemImage)
                    .font(.title3)
                Text(option.displayName)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(isSelected ? Theme.warning : Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
    }

    private var absoluteSeveritySlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(severityLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.warning)
                .contentTransition(.opacity)
                .animation(.default, value: severityLevel)

            Slider(value: $severity, in: 1...5)
                .tint(Theme.warning)
                .sensoryFeedback(.selection, trigger: severityLevel)

            HStack {
                Text("Mild")
                Spacer()
                Text("Severe")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var relativeSeverityPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let last = lastLogForSymptom {
                Text("Last logged \(last.date.formatted(.relative(presentation: .named))) as \(SeverityLabel.text(for: last.severity))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach(RelativeSeverityChoice.allCases) { choice in
                    relativeChoiceButton(choice)
                }
            }
        }
    }

    private func relativeChoiceButton(_ choice: RelativeSeverityChoice) -> some View {
        let isSelected = relativeChoice == choice
        return Button {
            relativeChoice = choice
        } label: {
            VStack(spacing: 6) {
                Image(systemName: choice.systemImage)
                    .font(.title3)
                Text(choice.label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(isSelected ? Theme.warning : Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
    }

    private func save() {
        guard let symptom else { return }
        let log = SideEffectLog(date: date, symptom: symptom, severity: resolvedSeverityLevel, notes: notes)
        modelContext.insert(log)
        try? modelContext.save()
        CloudSyncManager.shared.syncSoon(context: modelContext)
        dismiss()
    }
}

/// Shared between the absolute slider's label and the relative picker's "last
/// logged as ___" caption, so the two input modes always describe severity
/// with the same words.
private enum SeverityLabel {
    static func text(for level: Int) -> String {
        switch level {
        case 1: return "Mild"
        case 2: return "Mild–moderate"
        case 3: return "Moderate"
        case 4: return "Moderate–severe"
        default: return "Severe"
        }
    }
}

private enum RelativeSeverityChoice: CaseIterable, Identifiable {
    case better, same, worse
    var id: Self { self }

    var label: String {
        switch self {
        case .better: return "Better"
        case .same: return "Same"
        case .worse: return "Worse"
        }
    }

    var systemImage: String {
        switch self {
        case .better: return "arrow.down.circle.fill"
        case .same: return "equal.circle.fill"
        case .worse: return "arrow.up.circle.fill"
        }
    }
}

#Preview {
    LogSideEffectView()
        .modelContainer(for: [SideEffectLog.self], inMemory: true)
}
