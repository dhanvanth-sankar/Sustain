import SwiftData
import SwiftUI

/// The medication/dose/goals setup wizard — "the normal setup page" from
/// older versions, per the explicit request that reintroduced it as the
/// step after sign-in for a first-time-or-no-history account.
///
/// **2026-07-31 design decision**: this now runs for *every* device, not
/// just genuinely first-time accounts. Reasoning through the alternative
/// (silently skipping this screen whenever the signed-in account already
/// has data, so a returning user on a new device goes straight to
/// `MainTabView`) surfaced a real downside — the person never gets a chance
/// to actually see/confirm what synced down before it's already driving
/// their Dashboard, and a partially-failed sync would be invisible until
/// something looked wrong later. Always showing this screen, but
/// pre-filling it from whatever `MedicationProfile`/`WeightEntry` already
/// exists (via `viewModel.prefill`, called from `.task` below) turns it into
/// a quick review-and-confirm step for returning users instead of either
/// re-asking from scratch or skipping silently — each pre-filled field is
/// marked with a small "Saved value" note (see the three step views) so
/// it's clear at a glance what's already on record versus what's still a
/// default. A genuinely first-time account (no existing profile) sees empty
/// fields exactly as before; nothing changes for that case.
///
/// **2026-08-01 refinement**: reported directly, clicking through every
/// pre-filled step just to confirm nothing changed felt like friction rather
/// than reassurance, for someone who already has a real started plan on
/// record. Rather than reversing the decision above outright (silently
/// skipping straight to `MainTabView`, which loses the "see what synced down
/// before it's live" safety property this was built for), a device that
/// prefills from an already-*started* profile now sees `SyncedProfileReviewView`
/// first — a single glance at a summary with two choices: keep it as-is
/// (finishes immediately, same underlying data), or edit (drops into the
/// exact multi-step wizard below, unchanged). A first-time account, or one
/// that only ever skipped medication setup, still goes straight into the
/// normal wizard with empty fields, same as before this existed.
///
/// **2026-08-01, second refinement**: reported directly — tapping "Edit
/// values" from that review screen dropped into the wizard starting at
/// `.welcome`, the generic marketing/intro step ("Welcome to Sustain," an SF
/// Symbol and a tagline). For someone who already swiped through the actual
/// marketing carousel before signing in, *and* just read a "we found your
/// saved plan" summary, a second welcome screen has nothing left to
/// introduce — it's not reviewing anything, just a redundant tap before the
/// fields they actually asked to edit. `enteredWizardFromReview` tracks this
/// one case so `.welcome` is skipped only on this specific path — a
/// genuinely first-time account (which never sees the review screen at all)
/// still starts at `.welcome` exactly as before, since that screen is a real
/// first impression for that person, not a redundant one.
struct OnboardingFlow: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var viewModel = OnboardingViewModel()
    @State private var showingReviewChoice = false
    @State private var enteredWizardFromReview = false

    var body: some View {
        VStack(spacing: 0) {
            if showingReviewChoice {
                SyncedProfileReviewView(
                    viewModel: viewModel,
                    onKeep: completeOnboarding,
                    onEdit: {
                        withAnimation {
                            enteredWizardFromReview = true
                            viewModel.step = .medication
                            showingReviewChoice = false
                        }
                    }
                )
            } else {
                if viewModel.step != .welcome {
                    ProgressView(value: viewModel.progress)
                        .tint(Theme.primary)
                        .padding(.horizontal)
                        .padding(.top, 12)
                }

                Group {
                    switch viewModel.step {
                    case .welcome:
                        OnboardingWelcomeView()
                    case .medication:
                        OnboardingMedicationView(viewModel: viewModel)
                    case .dose:
                        OnboardingDoseView(viewModel: viewModel)
                    case .goals:
                        OnboardingGoalsView(viewModel: viewModel)
                    case .projection:
                        OnboardingProjectionView(viewModel: viewModel)
                    }
                }
                .frame(maxHeight: .infinity)

                navigationBar
            }
        }
        .background(Theme.screenBackground)
        .task {
            let profile = try? modelContext.fetch(
                FetchDescriptor<MedicationProfile>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            ).first
            let latestWeight = try? modelContext.fetch(
                FetchDescriptor<WeightEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
            ).first
            viewModel.prefill(from: profile, latestWeight: latestWeight)
            showingReviewChoice = profile?.hasStartedMedication == true
            // `goNext()` covers every step reached *after* this screen first
            // appears — this covers the one step that isn't reached via
            // `goNext()` at all: whichever step is on screen the instant
            // this view loads (`.welcome` for a genuinely first-time
            // account). The review-screen path (`showingReviewChoice`) is
            // deliberately not tracked here — see AnalyticsManager.Event's
            // doc comment: this funnel is specifically the first-time,
            // 4-step wizard, not the separate returning-user review flow.
            if !showingReviewChoice {
                AnalyticsManager.track(.onboardingStepReached(viewModel.step))
            }
        }
    }

    @ViewBuilder
    private var navigationBar: some View {
        HStack(spacing: 12) {
            if viewModel.step != .welcome {
                Button("Back") {
                    withAnimation {
                        // Backing out of the first real step on this
                        // particular path should return to the review
                        // screen it actually came from, not fall through to
                        // `.welcome` — a screen this path deliberately never
                        // showed in the first place.
                        if enteredWizardFromReview, viewModel.step == .medication {
                            showingReviewChoice = true
                        } else {
                            viewModel.goBack()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if viewModel.isLastStep {
                // 2026-08-01, real usability issue reported directly: this
                // finishing button used to sit inline at the bottom of
                // `OnboardingGoalsView`'s scrollable content, below the
                // protein-target and permissions cards — reachable only by
                // scrolling, with nothing on screen hinting that was
                // necessary. Moved here, into the fixed bar every other step
                // already uses for its own primary action, so it's visible
                // and reachable the instant this step appears, same as
                // "Continue" is on every step before it.
                Button(viewModel.weightWasPrefilled || viewModel.medicationWasPrefilled ? "Confirm and continue" : "Start using Sustain") {
                    Task { @MainActor in
                        viewModel.isRequestingPermissions = true
                        await NotificationManager.shared.requestAuthorization()
                        await HealthKitManager.shared.requestAuthorization()
                        viewModel.isRequestingPermissions = false
                        completeOnboarding()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(viewModel.isRequestingPermissions || !viewModel.canGoNext)
            } else {
                Button(viewModel.step == .welcome ? "Get started" : "Continue") {
                    withAnimation { viewModel.goNext() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canGoNext)
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .readableContentWidth()
    }

    private func completeOnboarding() {
        // `startingWeightLbs`/`targetWeightLbs` on the view model are entered in
        // whatever unit the user picked on this screen (`viewModel.weightUnit`), not
        // necessarily pounds — `poundsValue(_:)` converts to pounds for storage,
        // matching every other save path in the app (LogWeightView,
        // MedicationProfileEditView). This used to be skipped entirely here, so a kg
        // user's real body weight was saved verbatim as if it were already pounds.
        let startingWeightLbs = viewModel.poundsValue(viewModel.startingWeightLbs)
        let targetWeightLbs = viewModel.hasTargetWeight ? viewModel.poundsValue(viewModel.targetWeightLbs) : nil

        // A skipped "not started yet" onboarding still has *some* value sitting in
        // `viewModel.currentDoseMg` (whatever the dose slider's default was) even
        // though that step was never shown — store 0 instead of that leftover
        // value so nothing downstream mistakes it for a real dose.
        let currentDoseMg = viewModel.hasStartedMedication ? viewModel.currentDoseMg : 0

        // 2026-07-31: this screen now runs for returning users too, pre-filled
        // from `viewModel.existingProfile` (set by `prefill`, called from
        // `.task` above). Finishing it should *update* that same profile, not
        // insert a second one alongside it — a real duplication risk this
        // function didn't previously have to guard against, since it used to
        // only ever run once, on a genuinely empty device.
        // Only meaningful when `viewModel.medication == .custom` — `nil`/empty
        // otherwise, matching `MedicationProfile.customMedicationName`'s own
        // "nil for every non-custom case" convention. Converted from days
        // (what `OnboardingMedicationView`'s field actually collects) to hours
        // (what `customHalfLifeHours` and every other half-life value store).
        let customName: String? = viewModel.medication == .custom && !viewModel.customMedicationName.isEmpty
            ? viewModel.customMedicationName : nil
        let customHalfLifeHours: Double? = viewModel.medication == .custom
            ? viewModel.customHalfLifeDays.map { $0 * 24 } : nil

        let profile: MedicationProfile
        if let existing = viewModel.existingProfile {
            existing.medication = viewModel.medication
            existing.form = viewModel.form
            existing.frequency = viewModel.frequency
            existing.scheduledWeekdays = viewModel.scheduledWeekdays
            existing.startDate = viewModel.startDate
            existing.currentDoseMg = currentDoseMg
            existing.startingWeightLbs = startingWeightLbs
            existing.targetWeightLbs = targetWeightLbs
            existing.hasStartedMedication = viewModel.hasStartedMedication
            existing.customMedicationName = customName
            existing.customHalfLifeHours = customHalfLifeHours
            existing.updatedAt = Date()
            profile = existing
        } else {
            profile = MedicationProfile(
                medication: viewModel.medication,
                form: viewModel.form,
                frequency: viewModel.frequency,
                startDate: viewModel.startDate,
                currentDoseMg: currentDoseMg,
                startingWeightLbs: startingWeightLbs,
                targetWeightLbs: targetWeightLbs,
                hasStartedMedication: viewModel.hasStartedMedication,
                scheduledWeekdays: viewModel.scheduledWeekdays,
                customMedicationName: customName,
                customHalfLifeHours: customHalfLifeHours
            )
            modelContext.insert(profile)
        }

        // Same duplication concern for the starting-weight log entry: only
        // insert a new `WeightEntry` if there either wasn't one to prefill
        // from, or the user actually changed the number on screen — someone
        // just confirming their already-synced weight shouldn't end up with
        // two near-identical entries for the same reading.
        if !viewModel.weightWasPrefilled || !viewModel.startingWeightUnchangedFromPrefill {
            let weightEntry = WeightEntry(date: viewModel.startDate, weightLbs: startingWeightLbs)
            modelContext.insert(weightEntry)
        }

        try? modelContext.save()

        // Nothing to remind about yet if they haven't started — scheduling this
        // now would be a reminder for a dose that isn't real.
        if profile.hasStartedMedication {
            NotificationManager.shared.scheduleDoseReminder(
                at: profile.frequency.nextDueDate(after: profile.startDate, scheduledWeekdays: profile.scheduledWeekdays),
                medicationName: profile.displayMedicationName
            )
        }

        // Persist the unit chosen on this screen — previously it was only ever used
        // to label this screen's own fields and was discarded afterward, so the rest
        // of the app (Dashboard, Trends, Settings) silently reverted to displaying
        // pounds regardless of what was picked here.
        UserDefaults.standard.set(viewModel.weightUnit.rawValue, forKey: "weightUnitRaw")

        hasCompletedOnboarding = true
        // Records which account this completion belongs to — read by
        // `CloudSyncManager.checkOnboardingFlagForAccountSwitch()` the next
        // time someone signs in on this device, so switching to a
        // *different* account correctly re-triggers this screen instead of
        // skipping straight to `MainTabView` on a previous account's
        // completed setup.
        UserDefaults.standard.set(AuthManager.shared.session?.userId.uuidString, forKey: "onboardingCompletedForUserID")
        CloudSyncManager.shared.syncSoon(context: modelContext)
        AnalyticsManager.track(.onboardingCompleted)
    }
}

#Preview {
    OnboardingFlow()
        .modelContainer(for: [MedicationProfile.self, WeightEntry.self], inMemory: true)
}
