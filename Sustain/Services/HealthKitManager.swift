import Foundation
import HealthKit
import Observation

/// Thin wrapper around HealthKit for the two data types Sustain cares about:
/// body weight and dietary protein. Kept isolated behind this type so the rest
/// of the app never touches HKHealthStore directly.
@Observable
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    // These two identifiers are guaranteed present on every OS version we target,
    // so force-unwrapping here is the standard, safe pattern for HealthKit code.
    private let weightType = HKQuantityType.quantityType(forIdentifier: .bodyMass)!
    private let proteinType = HKQuantityType.quantityType(forIdentifier: .dietaryProtein)!
    // Read-only additions for `BodyCompositionEntry` (added 2026-08-02) — Sustain
    // never writes these, only imports whatever a smart scale (Withings, Renpho,
    // etc.) or another app already wrote to Health. See that model's header
    // comment for why this replaces a camera-based body scan for now.
    private let bodyFatType = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)!
    private let leanMassType = HKQuantityType.quantityType(forIdentifier: .leanBodyMass)!
    // Read-only additions for `RecoveryEntry` (added 2026-08-07) — same
    // "never write, only import whatever a wearable already wrote" posture
    // as body fat/lean mass above. Sleep analysis is a *category* type, not
    // a quantity type (HealthKit models it as time-ranged sleep-stage
    // samples, not a single number), so it needs its own fetch path — see
    // `fetchExternalSleepSamples` below.
    private let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
    private let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
    private let restingHeartRateType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!

    private(set) var isAuthorized = false
    private(set) var authorizationError: String?

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    @MainActor
    func requestAuthorization() async {
        guard isHealthDataAvailable else {
            authorizationError = "Health data isn't available on this device."
            return
        }
        // Body fat / lean mass are read-only — Sustain never writes them, so they
        // belong in `readTypes` only, not `shareTypes`.
        let shareTypes: Set<HKSampleType> = [weightType, proteinType]
        let readTypes: Set<HKObjectType> = [
            weightType, proteinType, bodyFatType, leanMassType,
            sleepType, hrvType, restingHeartRateType,
        ]
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            isAuthorized = true
            authorizationError = nil
        } catch {
            authorizationError = error.localizedDescription
        }
    }

    func saveWeight(pounds: Double, date: Date) async {
        let kilograms = WeightUnit.pounds.convert(pounds, to: .kilograms)
        let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kilograms)
        let sample = HKQuantitySample(type: weightType, quantity: quantity, start: date, end: date)
        try? await store.save(sample)
    }

    func saveProtein(grams: Double, date: Date) async {
        let quantity = HKQuantity(unit: .gram(), doubleValue: grams)
        let sample = HKQuantitySample(type: proteinType, quantity: quantity, start: date, end: date)
        try? await store.save(sample)
    }

    /// Read authorization was requested from day one but nothing ever queried
    /// HealthKit back — `saveWeight`/`saveProtein` only ever pushed Sustain's own
    /// entries *out*, so a weight logged on a smart scale (or protein logged in a
    /// different app) never showed up here, contradicting the app's own
    /// `NSHealthShareUsageDescription` promise of "without double entry." These two
    /// fetch the samples HealthKit has that did *not* come from Sustain itself —
    /// filtered by source bundle ID — so importing them can't just re-ingest what
    /// `saveWeight`/`saveProtein` already wrote.
    func fetchExternalWeightSamples(since: Date) async -> [(date: Date, pounds: Double)] {
        await fetchExternalSamples(type: weightType, since: since).map { sample in
            let kilograms = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
            return (sample.startDate, WeightUnit.kilograms.convert(kilograms, to: .pounds))
        }
    }

    func fetchExternalProteinSamples(since: Date) async -> [(date: Date, grams: Double)] {
        await fetchExternalSamples(type: proteinType, since: since).map { sample in
            (sample.startDate, sample.quantity.doubleValue(for: .gram()))
        }
    }

    /// HKQuantity's percentage unit stores 0...1, not 0...100 — this returns the
    /// familiar 0...100 scale so callers (and the SwiftData model) never have to
    /// remember which convention is in play.
    func fetchExternalBodyFatSamples(since: Date) async -> [(date: Date, percent: Double)] {
        await fetchExternalSamples(type: bodyFatType, since: since).map { sample in
            (sample.startDate, sample.quantity.doubleValue(for: .percent()) * 100)
        }
    }

    func fetchExternalLeanMassSamples(since: Date) async -> [(date: Date, pounds: Double)] {
        await fetchExternalSamples(type: leanMassType, since: since).map { sample in
            let kilograms = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
            return (sample.startDate, WeightUnit.kilograms.convert(kilograms, to: .pounds))
        }
    }

    /// SDNN is HealthKit's standard HRV metric, stored in seconds but
    /// conventionally displayed in milliseconds (the unit every wearable's
    /// own app — Oura, Whoop, the Health app itself — shows it in), hence
    /// the explicit `.milli` unit conversion here rather than leaving it in
    /// HealthKit's native seconds.
    func fetchExternalHRVSamples(since: Date) async -> [(date: Date, milliseconds: Double)] {
        await fetchExternalSamples(type: hrvType, since: since).map { sample in
            (sample.startDate, sample.quantity.doubleValue(for: .secondUnit(with: .milli)))
        }
    }

    func fetchExternalRestingHeartRateSamples(since: Date) async -> [(date: Date, bpm: Double)] {
        await fetchExternalSamples(type: restingHeartRateType, since: since).map { sample in
            (sample.startDate, sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
        }
    }

    /// Sleep analysis is HealthKit's one category (not quantity) type here —
    /// each sample is a time range tagged with a stage (`.asleepCore`,
    /// `.asleepDeep`, `.asleepREM`, `.asleepUnspecified`, or `.inBed`, which
    /// isn't necessarily asleep and is deliberately excluded below). This
    /// sums every *asleep* stage's duration, grouped by the calendar day the
    /// sleep session *ended* on (a night that starts before midnight and
    /// ends after it reads as "last night's sleep" that way, matching how
    /// every sleep-tracking app — Health, Oura, Whoop — attributes a night's
    /// sleep to the morning it ended, not the evening it started), into one
    /// total-hours-asleep figure per night.
    func fetchExternalSleepSamples(since: Date) async -> [(date: Date, hours: Double)] {
        guard isHealthDataAvailable else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: .now, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, _ in
                let externalSamples = (samples as? [HKCategorySample] ?? []).filter {
                    $0.sourceRevision.source.bundleIdentifier != Bundle.main.bundleIdentifier
                }
                continuation.resume(returning: externalSamples)
            }
            store.execute(query)
        }

        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let asleepSamples = samples.filter { asleepValues.contains($0.value) }

        let calendar = Calendar.current
        let byNight = Dictionary(grouping: asleepSamples) { calendar.startOfDay(for: $0.endDate) }
        return byNight.map { night, samples in
            let totalSeconds = samples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            return (night, totalSeconds / 3600)
        }
    }

    private func fetchExternalSamples(type: HKQuantityType, since: Date) async -> [HKQuantitySample] {
        guard isHealthDataAvailable else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: .now, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, _ in
                let externalSamples = (samples as? [HKQuantitySample] ?? []).filter {
                    $0.sourceRevision.source.bundleIdentifier != Bundle.main.bundleIdentifier
                }
                continuation.resume(returning: externalSamples)
            }
            store.execute(query)
        }
    }
}
