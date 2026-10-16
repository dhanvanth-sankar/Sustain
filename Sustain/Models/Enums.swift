import Foundation

/// Oral pill is declared first (and therefore listed first wherever `.allCases`
/// drives a picker) deliberately — oral GLP-1 formulations are the 2026 growth
/// wave and the product is positioned oral-first rather than injection-first.
enum MedicationForm: String, Codable, CaseIterable, Identifiable {
    case oralPill
    case injection

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .injection: return "Injection"
        case .oralPill: return "Oral pill"
        }
    }

    var systemImage: String {
        switch self {
        case .injection: return "syringe.fill"
        case .oralPill: return "pills.fill"
        }
    }
}

enum DoseFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly
    case daily
    /// Added 2026-08-01, explicit request: every currently-approved GLP-1 is
    /// actually once-daily or once-weekly, but a compounded/custom program
    /// can prescribe a specific-days schedule (e.g. Mon/Wed/Fri) that
    /// neither of those two cases can represent. Which days are actually
    /// scheduled lives on `MedicationProfile.scheduledWeekdays`, not here —
    /// this enum only marks *that* a profile uses a specific-days schedule
    /// at all; `nextDueDate(after:scheduledWeekdays:)` needs the profile's
    /// own set of days to compute anything for this case.
    case specificDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: return "Once a week"
        case .daily: return "Once a day"
        case .specificDays: return "Specific days"
        }
    }

    /// The next scheduled dose date after `lastDose`. `scheduledWeekdays`
    /// (Calendar's own weekday numbering: 1 = Sunday ... 7 = Saturday) is
    /// only consulted for `.specificDays` — every other case ignores it, so
    /// existing call sites that don't pass one keep working unchanged.
    func nextDueDate(after lastDose: Date, scheduledWeekdays: Set<Int> = [], calendar: Calendar = .current) -> Date {
        switch self {
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: lastDose) ?? lastDose
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: lastDose) ?? lastDose
        case .specificDays:
            // No days actually selected (a profile mid-setup, or migrated
            // from an old build with nothing to backfill) — fall back to
            // "tomorrow" rather than never surfacing a reminder at all.
            guard !scheduledWeekdays.isEmpty else {
                return calendar.date(byAdding: .day, value: 1, to: lastDose) ?? lastDose
            }
            var candidate = calendar.date(byAdding: .day, value: 1, to: lastDose) ?? lastDose
            // At most 7 days ahead is guaranteed to hit a scheduled weekday
            // if the set is non-empty; the extra +1 is just a defensive
            // bound against a calendar edge case, never actually needed.
            for _ in 0...7 {
                if scheduledWeekdays.contains(calendar.component(.weekday, from: candidate)) {
                    return candidate
                }
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return candidate
        }
    }
}

enum MedicationOption: String, Codable, CaseIterable, Identifiable {
    case wegovy = "Wegovy"
    case ozempic = "Ozempic"
    case zepbound = "Zepbound"
    case mounjaro = "Mounjaro"
    case rybelsus = "Rybelsus"
    case saxenda = "Saxenda"
    case compounded = "Compounded semaglutide/tirzepatide"
    case other = "Other"
    /// Added 2026-08-02 for comp-010 in `sustain-pros-and-cons.json`: Pokii lets
    /// users add a fully custom medication with its own name and half-life, one
    /// of its most-requested and most-loved features per its own reviews.
    /// Distinct from `.other` (which has no way to attach a name or half-life at
    /// all) — a profile with this case is expected to also have
    /// `MedicationProfile.customMedicationName`/`customHalfLifeHours` set. See
    /// that model's header comment for the full storage design.
    case custom = "Custom"

    var id: String { rawValue }

    /// Whether this brand is conventionally an oral pill.
    var defaultForm: MedicationForm {
        switch self {
        case .rybelsus: return .oralPill
        default: return .injection
        }
    }

    var defaultFrequency: DoseFrequency {
        switch self {
        case .rybelsus, .compounded: return .daily
        default: return .weekly
        }
    }

    /// Published elimination half-life in hours, used only to draw the relative
    /// medication-level chart in Trends (`MedicationLevelCalculator`) — never used
    /// for any dosing math or titration logic. Sourced from each drug's own FDA
    /// prescribing information, Clinical Pharmacology §12.3 (see
    /// `MedicalSourceTopic.medicationLevel`'s citations). `nil` for `.compounded`/
    /// `.other`/`.custom`: compounded formulations vary by pharmacy/prescriber
    /// with no single published value, "Other" is unspecified by definition, and
    /// a custom entry's half-life (if any) lives on `MedicationProfile` instead
    /// of here, since it's per-profile user input, not a fixed published fact
    /// about a named case — the chart simply doesn't render from this property
    /// for any of the three, the same safe-nil pattern `TitrationSchedule`
    /// already uses.
    var eliminationHalfLifeHours: Double? {
        switch self {
        case .wegovy, .ozempic, .rybelsus: return 168   // semaglutide, ~7 days
        case .zepbound, .mounjaro: return 120            // tirzepatide, ~5 days
        case .saxenda: return 13                          // liraglutide, ~13 hours
        case .compounded, .other, .custom: return nil
        }
    }
}

enum InjectionSite: String, Codable, CaseIterable, Identifiable {
    case leftAbdomen
    case rightAbdomen
    case leftThigh
    case rightThigh
    case leftArm
    case rightArm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftAbdomen: return "Left abdomen"
        case .rightAbdomen: return "Right abdomen"
        case .leftThigh: return "Left thigh"
        case .rightThigh: return "Right thigh"
        case .leftArm: return "Left arm"
        case .rightArm: return "Right arm"
        }
    }

    /// Added 2026-08-03 alongside `LogDoseView.recentSiteHistory` — a
    /// abbreviated label short enough to chain several together
    /// ("L. thigh → R. abdomen → L. arm") without wrapping. Previously this
    /// exact abbreviation logic lived only as a private `shortLabel` inside
    /// `InjectionSiteDiagram`; moved onto the enum itself so both that
    /// diagram and the new rotation-history caption share one definition
    /// instead of two copies that could drift.
    var shortDisplayName: String {
        switch self {
        case .leftArm: return "L. arm"
        case .rightArm: return "R. arm"
        case .leftAbdomen: return "L. abdomen"
        case .rightAbdomen: return "R. abdomen"
        case .leftThigh: return "L. thigh"
        case .rightThigh: return "R. thigh"
        }
    }
}

enum EntrySource: String, Codable {
    case manual
    case healthKit
    case photoEstimate
}

/// Added 2026-09-27 alongside `MedicationProfile.isDiscontinued` — see that
/// property's doc comment for the full "Life After GLP-1" reasoning. Entirely
/// optional and never required: someone can mark themselves as having
/// stopped without picking a reason at all (`.preferNotToSay` covers "I don't
/// want to say," a genuine skip is just leaving `discontinuedReasonRaw` nil).
///
/// Deliberately NOT sent to `AnalyticsManager` in any form — see that file's
/// header comment on "what is never sent": a reason for stopping a
/// medication is exactly the kind of health-adjacent detail that stays
/// on-device only, the same boundary already drawn around dose amounts and
/// weight values. Only the fact that a discontinuation happened (not why)
/// reaches analytics, via `.medicationDiscontinuationMarked`.
enum DiscontinuationReason: String, Codable, CaseIterable, Identifiable {
    case cost
    case sideEffects
    case reachedGoalWeight
    case doctorRecommended
    case other
    case preferNotToSay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cost: return "Cost or insurance coverage"
        case .sideEffects: return "Side effects"
        case .reachedGoalWeight: return "Reached my goal"
        case .doctorRecommended: return "My prescriber recommended it"
        case .other: return "Other"
        case .preferNotToSay: return "Prefer not to say"
        }
    }
}

enum SideEffectSymptom: String, Codable, CaseIterable, Identifiable {
    case nausea
    case fatigue
    case constipation
    case diarrhea
    case injectionSiteReaction
    case headache
    case dizziness
    case heartburn
    case lossOfAppetite
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nausea: return "Nausea"
        case .fatigue: return "Fatigue"
        case .constipation: return "Constipation"
        case .diarrhea: return "Diarrhea"
        case .injectionSiteReaction: return "Injection site reaction"
        case .headache: return "Headache"
        case .dizziness: return "Dizziness"
        case .heartburn: return "Heartburn"
        case .lossOfAppetite: return "Loss of appetite"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .nausea: return "waveform.path.ecg"
        case .fatigue: return "battery.25"
        case .constipation, .diarrhea: return "cross.case"
        case .injectionSiteReaction: return "bandage"
        case .headache: return "brain.head.profile"
        case .dizziness: return "arrow.triangle.2.circlepath"
        case .heartburn: return "flame"
        case .lossOfAppetite: return "fork.knife"
        case .other: return "ellipsis.circle"
        }
    }
}

enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case pounds
    case kilograms

    var id: String { rawValue }

    var abbreviation: String {
        switch self {
        case .pounds: return "lb"
        case .kilograms: return "kg"
        }
    }

    func convert(_ value: Double, to unit: WeightUnit) -> Double {
        guard unit != self else { return value }
        switch (self, unit) {
        case (.pounds, .kilograms): return value * 0.45359237
        case (.kilograms, .pounds): return value / 0.45359237
        default: return value
        }
    }
}
