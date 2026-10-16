import RevenueCat
import SwiftData
import SwiftUI

@main
struct SustainApp: App {
    @State private var container: ModelContainer?

    /// [ADDED 2026-08-16, pre-2.2.1 audit] Retention (D1/D7/D30) was being
    /// materially undercounted before this. `init()` runs once per *process*
    /// launch, not once per app open — iOS keeps suspended apps resident for
    /// a long time, so someone who opens Sustain from the app switcher every
    /// single morning can easily go a week or more without the process ever
    /// being relaunched, and would have generated exactly one `appOpened`
    /// signal for that whole week. Since "did this person open the app on day
    /// N" is precisely what D1/D7/D30 measures, that gap biased the one
    /// number this instrumentation was built to produce, and biased it
    /// downward, which is the direction most likely to cause a wrong call on
    /// the marketing side.
    @Environment(\.scenePhase) private var scenePhase

    /// Deliberately only fires on a `.background` -> `.active` transition,
    /// not on every `.active`. SwiftUI also reports `.active` after transient
    /// interruptions that are not a real app open (pulling down Notification
    /// Center, the control center sheet, a permission alert), all of which go
    /// `.active` -> `.inactive` -> `.active` without ever reaching
    /// `.background`. Counting those would overstate the same number the gap
    /// above was understating.
    @State private var previousScenePhase: ScenePhase = .active

    /// Must run before any view touches `EntitlementManager.shared` — that type
    /// assumes `Purchases.shared` is already configured, and `Purchases.shared`
    /// force-crashes if accessed pre-configure. `init()` runs before `body` is
    /// ever evaluated, so this is the one place guaranteed to win that race no
    /// matter what SwiftUI decides to construct first.
    init() {
        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        // [FIXED 2026-08-16, found in a pre-2.2.1 audit] This used to be a
        // `guard ... else { assertionFailure(...); return }`, which meant a
        // missing `RevenueCatAPIKey` silently skipped *everything* below it
        // too — analytics configuration, the app-open signal, and the Watch
        // connectivity bridge, none of which have anything to do with
        // RevenueCat. That early `return` quietly defeated the stated intent
        // of both: `AnalyticsManager.configure()`'s own doc comment says it
        // deliberately no-ops rather than asserting on a missing key, but it
        // never got the chance to, and a paired Watch would have gone dead
        // for a reason with no connection to Watch code at all. Scoped to an
        // `if let` so one subsystem's missing config can't take out two
        // unrelated ones.
        if let apiKey = Bundle.main.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String,
           !apiKey.isEmpty {
            Purchases.configure(withAPIKey: apiKey)
        } else {
            // Missing Secrets.xcconfig entry — same "fail loud in debug, don't
            // crash a real user's launch" tradeoff EntitlementManager.swift
            // documents for its own missing-config case.
            assertionFailure("RevenueCatAPIKey missing from Info.plist — check Secrets.xcconfig.")
        }

        // Added 2026-08-12 — see AnalyticsManager.swift for the full
        // reasoning. No `assertionFailure` on a missing key here (unlike
        // RevenueCat's config above): `configure()` itself already handles
        // that gap by silently disabling analytics for the session, since
        // losing analytics is a real but low-stakes gap, not a billing risk.
        AnalyticsManager.configure()
        // D1/D7/D30 retention (growth-strategy item 2) needs a signal on
        // every real app launch, not just first-ever — this is that signal.
        // Placed right after `configure()` rather than deeper in the launch
        // sequence (e.g. after the SwiftData container or first view render)
        // so a crash anywhere later still leaves this one signal sent.
        //
        // This covers *cold* launches only. See `scenePhase` in `body` below
        // for the foreground-return case, which is the more common way people
        // actually open an app day to day.
        AnalyticsManager.track(.appOpened)

        // Activates the phone side of the Watch app's cross-device bridge —
        // see `Services/PhoneConnectivityManager.swift`'s header comment.
        // Safe to call unconditionally even for someone with no paired
        // Watch at all.
        PhoneConnectivityManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    ContentView()
                        .modelContainer(container)
                } else {
                    LaunchLoadingView()
                        .task {
                            let newContainer = await Self.makeContainer()
                            // Replaces whatever's in the store with a fabricated,
                            // internally-consistent dataset every launch — see
                            // ScreenshotModeSeeder's header comment for why this
                            // exists and why it's safe (entirely compiled out
                            // unless SCREENSHOT_MODE is manually set in Debug).
                            #if SCREENSHOT_MODE
                            ScreenshotModeSeeder.seed(in: newContainer.mainContext)
                            #endif
                            container = newContainer
                        }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // See `previousScenePhase`'s doc comment for why this is a
                // background->active check rather than a plain `== .active`.
                if newPhase == .active && previousScenePhase == .background {
                    AnalyticsManager.track(.appOpened)
                }
                previousScenePhase = newPhase
            }
        }
    }

    /// Building the container off the main thread means the first frame renders
    /// immediately even on a fresh install, when SwiftData has to create the
    /// on-disk store from scratch (schema + file) rather than just open an
    /// existing one. This is the only part of first-launch latency that's actually
    /// reachable from app code — the rest (dyld loading the binary, SpringBoard's
    /// launch animation, one-time HealthKit entitlement registration) happens
    /// before any Swift code here runs, and is dramatically worse in the iOS
    /// Simulator than on a physical device.
    private static func makeContainer() async -> ModelContainer {
        await Task.detached(priority: .userInitiated) {
            let schema = Schema([
                MedicationProfile.self,
                DoseLog.self,
                WeightEntry.self,
                ProteinEntry.self,
                SideEffectLog.self,
                // Added 2026-08-02 for the body composition trend feature — a purely
                // additive new model, which SwiftData handles via automatic
                // lightweight migration with no `SchemaMigrationPlan` needed.
                BodyCompositionEntry.self,
                // Added 2026-08-03 for progress photos (see
                // Sustain-Competitor-Deep-Dive-2026-08.md §3b) — same purely
                // additive, automatic-lightweight-migration situation as
                // BodyCompositionEntry above.
                ProgressPhotoEntry.self,
                // Added 2026-08-03 for lab-result tracking (see
                // Sustain-Competitor-Deep-Dive-2026-08.md §6) — same purely
                // additive, automatic-lightweight-migration situation as
                // BodyCompositionEntry above.
                LabResultEntry.self,
                // Added 2026-08-07 for sleep/HRV/resting-heart-rate
                // recovery-correlation tracking (see
                // Sustain-Subscription-Payer-Features-Report-2026-08.md §4)
                // — same purely additive, automatic-lightweight-migration
                // situation as BodyCompositionEntry above.
                RecoveryEntry.self,
            ])
            do {
                let configuration = ModelConfiguration(schema: schema)
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                // A persistent-store failure here is effectively unrecoverable (corrupt
                // on-disk state, out of space, etc.). Fall back to in-memory so the app
                // still opens instead of crashing outright.
                let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try! ModelContainer(for: schema, configurations: [fallback])
            }
        }.value
    }
}
