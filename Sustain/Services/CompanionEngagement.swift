import Foundation

/// Drives the mood of `CompanionCharacterView`, Sustain's on-dashboard companion
/// character ("Pip"). See `Sustain-Companion-Character-Research-2026-08.md` for
/// the full research behind this feature — the one-line version: reactive
/// companion characters are a proven, well-studied engagement mechanic
/// (Duolingo's owl, the Tamagotchi effect), but the research is equally clear
/// that reacting to a health *outcome* (weight, dose adherence) rather than to
/// whether someone simply showed up and logged something carries a real,
/// documented eating-disorder/body-dysmorphia risk in exactly this app's user
/// base, and would directly contradict the self-compassion-over-self-criticism
/// framing this app already committed to and cited in `StreakResetView.swift`
/// (`MedicalSourceTopic.consistency`: Lally 2010, Larimer/Palmer/Marlatt 1999,
/// Thøgersen-Ntoumani 2021).
///
/// So `CompanionMood` is deliberately computed from **engagement only** — the
/// most recent date across every kind of log a user can make (dose, protein,
/// weight, side effect) — and never looks at a weight number, a dose amount,
/// or whether a goal was hit. It is also deliberately a small, ordered scale
/// with no state below `.waiting`: the worst thing Pip is ever allowed to look
/// like is "waiting for you," matching Finch's explicit non-punitive design
/// principle ("no penalty for an off day, only a small companion glad to see
/// you back"), not a sad, disappointed, or scolding state. `CompanionMood`
/// intentionally has no `.sad` or `.disappointed` case at all — that's not an
/// oversight, it's the whole point.
enum CompanionMood: Equatable {
    /// No logs of any kind exist yet — a fresh install, or a fresh profile that
    /// hasn't been used yet. Distinct from `.waiting` so the copy can say
    /// "let's get started" instead of implying a lapse that never happened.
    case new
    /// Something was logged today (dose, protein, weight, or a side effect).
    case active
    /// Nothing logged today, but something was logged in the last few days —
    /// still well within a normal, unremarkable gap.
    case resting
    /// Nothing logged in a while. Still framed warmly — see
    /// `CompanionCharacterView.caption` — never as a failure.
    case waiting
}

enum CompanionEngagement {
    /// Days since the most recent log before `.resting` gives way to
    /// `.waiting`. Matches the same "a missed day or two is unremarkable, a
    /// longer gap deserves a gentler nudge back" spirit as
    /// `DashboardView.checkForStreakReset()`'s own threshold, just for a much
    /// lower-stakes, always-visible signal rather than a one-time sheet.
    private static let restingWindowDays = 3

    static func mood(
        doseLogs: [DoseLog],
        proteinEntries: [ProteinEntry],
        weightEntries: [WeightEntry],
        sideEffectLogs: [SideEffectLog],
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> CompanionMood {
        let mostRecentLogDate = [
            doseLogs.map(\.date).max(),
            proteinEntries.map(\.date).max(),
            weightEntries.map(\.date).max(),
            sideEffectLogs.map(\.date).max(),
        ]
        .compactMap { $0 }
        .max()

        guard let mostRecentLogDate else { return .new }

        let daysSince = max(
            0,
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: mostRecentLogDate),
                to: calendar.startOfDay(for: asOf)
            ).day ?? 0
        )

        switch daysSince {
        case 0: return .active
        case 1...restingWindowDays: return .resting
        default: return .waiting
        }
    }
}
