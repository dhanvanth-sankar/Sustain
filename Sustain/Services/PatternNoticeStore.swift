import Foundation

/// Tracks which `PatternDetectionEngine.DetectedPattern`s have already been shown or
/// dismissed, so the same pattern instance doesn't reappear (in the Dashboard card or as
/// a notification) every single time the app opens.
///
/// **UserDefaults, not a new SwiftData model.** This is a deliberate simplicity choice,
/// consistent with this project's own established "don't over-abstract" discipline (see
/// `PROJECT_HANDOFF.md` §6's "no premature abstraction" note): the only state this needs
/// is a small set of string keys, which is exactly what `@AppStorage`/`UserDefaults`
/// already handles elsewhere in this app (`weightUnitRaw`, the referral/analytics
/// anonymous ID). A new `@Model` would mean a new schema migration and a new
/// `ModelContainer` entry (`SustainApp.makeContainer()`) for something that has no
/// relational shape and nothing to query — pure overhead here, not a real need.
///
/// Per the research doc's own risk section (Part 10): "always give the person an easy
/// way to dismiss or mute a specific pattern type, so the feature reads as attentive, not
/// naggy or gamified." `mute(kind:)` below is that mechanism — a full opt-out per pattern
/// *type*, separate from `markSeen(stableKey:)`'s per-*instance* dismissal.
enum PatternNoticeStore {
    private static let defaults = UserDefaults.standard
    private static let seenKeysKey = "patternNotice_seenStableKeys"
    private static let mutedKindsKey = "patternNotice_mutedKinds"

    /// Every stable key ever shown or dismissed. Capped to the most recent 50 — this is
    /// a "have we already surfaced this exact instance" check, not a permanent log, and
    /// 50 is far more than this app could realistically accumulate given the detectors'
    /// own conservative firing thresholds.
    private static var seenKeys: Set<String> {
        get { Set((defaults.array(forKey: seenKeysKey) as? [String]) ?? []) }
        set { defaults.set(Array(newValue).suffix(50), forKey: seenKeysKey) }
    }

    private static var mutedKinds: Set<String> {
        get { Set((defaults.array(forKey: mutedKindsKey) as? [String]) ?? []) }
        set { defaults.set(Array(newValue), forKey: mutedKindsKey) }
    }

    /// Filters a freshly-detected list down to only what's actually new: not already
    /// seen, and not a muted pattern type. Call this before showing the Dashboard card
    /// or scheduling a notification — `PatternDetectionEngine` itself has no notion of
    /// "already shown," by design (see its own header comment).
    static func unseenPatterns(from patterns: [PatternDetectionEngine.DetectedPattern]) -> [PatternDetectionEngine.DetectedPattern] {
        let seen = seenKeys
        let muted = mutedKinds
        return patterns.filter { !seen.contains($0.stableKey) && !muted.contains($0.kind.rawValue) }
    }

    /// Marks one specific pattern instance as seen — called once the user has actually
    /// been shown the card for it, whether or not they act on it. A later, genuinely new
    /// instance of the same kind (a different dose-increase date, a different plateau
    /// window) still has its own `stableKey` and will still surface normally.
    static func markSeen(_ stableKey: String) {
        var keys = seenKeys
        keys.insert(stableKey)
        seenKeys = keys
    }

    /// Opts out of an entire pattern *type* going forward — the "mute" action from the
    /// card, distinct from the lighter per-instance dismissal above.
    static func mute(kind: PatternDetectionEngine.DetectedPattern.Kind) {
        var kinds = mutedKinds
        kinds.insert(kind.rawValue)
        mutedKinds = kinds
    }

    static func isMuted(_ kind: PatternDetectionEngine.DetectedPattern.Kind) -> Bool {
        mutedKinds.contains(kind.rawValue)
    }
}
