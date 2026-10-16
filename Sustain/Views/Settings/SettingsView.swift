import SwiftData
import SwiftUI

struct SettingsView: View {
    @Query private var profiles: [MedicationProfile]
    @Query private var doseLogs: [DoseLog]
    @Query private var weightEntries: [WeightEntry]
    @Query private var proteinEntries: [ProteinEntry]
    @Query private var sideEffectLogs: [SideEffectLog]

    @AppStorage("weightUnitRaw") private var weightUnitRaw: String = WeightUnit.pounds.rawValue
    @State private var entitlements = EntitlementManager.shared
    @State private var auth = AuthManager.shared
    @State private var syncManager = CloudSyncManager.shared
    @State private var showingEditProfile = false
    @State private var showingPaywall = false

    private var profile: MedicationProfile? { profiles.first }
    private var weightUnit: Binding<WeightUnit> {
        Binding(
            get: { WeightUnit(rawValue: weightUnitRaw) ?? .pounds },
            set: { weightUnitRaw = $0.rawValue }
        )
    }

    /// Summary row for the top-of-Settings link into `AccountSettingsView` —
    /// enough at a glance (signed in vs. not, a sync failure if there is one)
    /// that someone doesn't have to actually open the screen just to check
    /// whether anything needs attention, matching how the plan/upgrade row
    /// right below it already works.
    private var accountRow: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Account & Sync")
                    .font(.subheadline.weight(.semibold))
                if let lastSyncError = syncManager.lastSyncError {
                    Text("Sync failed, tap to view")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Last sync failed: \(lastSyncError)")
                } else {
                    Text(auth.session?.email ?? (auth.isSignedIn ? "Signed in" : "Not signed in"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        NavigationStack {
            Form {
                // 2026-08-01, explicit request: account settings (sign-in
                // status, sync, sign out, delete account) used to be an
                // inline Section mixed in among weight units and reminders —
                // moved to its own screen, `AccountSettingsView`, and this
                // row pinned to the very top of Settings as the single entry
                // point into it, since it's arguably the most consequential
                // section here (it's where "delete account" lives) and
                // deserves to be easy to find rather than one Section among
                // several.
                Section {
                    NavigationLink {
                        AccountSettingsView()
                    } label: {
                        accountRow
                    }
                }

                Section {
                    HStack {
                        Image(systemName: entitlements.isPremium ? "leaf.circle.fill" : "leaf.circle")
                            .font(.title2)
                            .foregroundStyle(Theme.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entitlements.isPremium ? "Sustain+ member" : "Free plan")
                                .font(.subheadline.weight(.semibold))
                            Text(entitlements.isPremium ? "Full history & reporting unlocked" : "See only the last \(EntitlementManager.freeHistoryWindowDays) days of history")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(entitlements.isPremium ? "Manage" : "Upgrade") {
                            showingPaywall = true
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.primary)
                    }
                    .padding(.vertical, 4)

                    // Placed directly under the plan/subscription row, not
                    // buried in Preferences — see `ReferralView.swift`'s
                    // header comment for why this is one of the highest-
                    // value, best-quantified levers this project's growth
                    // research found, worth the same visibility as the
                    // subscription status itself.
                    NavigationLink {
                        ReferralView()
                    } label: {
                        Label("Invite a friend, get a free month", systemImage: "gift.fill")
                    }
                }

                if let profile {
                    Section("Your plan") {
                        if profile.hasStartedMedication {
                            LabeledContent("Medication", value: profile.displayMedicationName)
                            LabeledContent("Form", value: profile.form.displayName)
                            LabeledContent("Frequency", value: profile.frequency.displayName)
                            LabeledContent("Current dose", value: "\(profile.currentDoseMg.formatted(.number.precision(.fractionLength(0...2)))) mg")

                            Button("Edit plan") { showingEditProfile = true }
                        } else {
                            Text("You haven't started a medication yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Button("Add medication") { showingEditProfile = true }
                        }
                    }
                }

                Section("Preferences") {
                    Picker("Weight unit", selection: weightUnit) {
                        ForEach(WeightUnit.allCases) { unit in
                            Text(unit == .pounds ? "Pounds (lb)" : "Kilograms (kg)").tag(unit)
                        }
                    }

                    NavigationLink("Reminders & Health") {
                        ReminderSettingsView()
                    }

                    if entitlements.hasMaintenanceProgram {
                        NavigationLink("Maintenance Guide") {
                            MaintenanceGuideView()
                        }
                    }
                }

                // "Reset all data" (a local-only wipe) lived here until
                // 2026-08-01 — removed, not just relabeled, after a direct
                // "there's no point of the reset all data button now."
                // Real reasoning: it never touched the cloud copy (sync is
                // additive-only, a disclosed limitation — see
                // `CloudSyncManager`'s header comment), so tapping it while
                // still signed in and online had a real chance of quietly
                // undoing itself the next time the Dashboard's normal
                // sync-on-appear pulled the untouched cloud data straight
                // back down. Both of the two things someone reaching for
                // this button actually wants now have a correct, real
                // implementation elsewhere: "start over, same account" is
                // `MedicationProfileEditView`'s per-field editing plus
                // deleting individual log entries; "erase everything,
                // completely" is Account & sync's "Delete account" — which,
                // as of the same day, genuinely deletes the cloud copy too,
                // not just the local one. See `CloudSyncManager
                // .eraseLocalData`'s doc comment for where the underlying
                // wipe logic still lives (still used by sign-out).
                Section("Data") {
                    LabeledContent("Doses logged", value: "\(doseLogs.count)")
                    LabeledContent("Weight entries", value: "\(weightEntries.count)")
                    LabeledContent("Protein entries", value: "\(proteinEntries.count)")
                    LabeledContent("Side effects logged", value: "\(sideEffectLogs.count)")
                }

                // Guideline 1.4.1 requires the citations behind the app's health
                // calculations to be easy to find. They're surfaced contextually next
                // to each number (Dashboard, onboarding, medication plan, maintenance
                // guide) and also collected here, so there's one predictable place to
                // look that doesn't depend on knowing which screen shows which number.
                Section("Medical information") {
                    NavigationLink("Sources & citations") {
                        MedicalSourcesView()
                    }

                    Text(MedicalSources.disclaimer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Legal") {
                    Link(destination: LegalLinks.termsOfUse) {
                        LabeledContent("Terms of Use (EULA)") {
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                    Link(destination: LegalLinks.privacyPolicy) {
                        LabeledContent("Privacy Policy") {
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.appVersionString)
                    // Corrected: the previous wording ("Sustain doesn't send it
                    // anywhere") was simply untrue once the AI features shipped —
                    // the photo estimate uploads the food photo, and the weekly
                    // recap uploads summary figures, both to an Anthropic-backed
                    // service through Sustain's proxy. Leaving that claim in place
                    // would have been both a real privacy misstatement to users and
                    // an avoidable Guideline 5.1.1 problem, since the App Privacy
                    // details must match what the app actually does.
                    // Rewritten 2026-07-30 when Sign in with Apple became required to
                    // use Sustain at all (previously this whole section described a
                    // purely local, no-account app — see PROJECT_HANDOFF.md's "Local-
                    // first, privacy as a selling point" section for that history).
                    // The claim below has to actually be true now, not the old "stored
                    // on this device and not uploaded" line, which stopped being
                    // accurate the moment sign-in stopped being optional.
                    Text("Your medication, weight, protein, and side-effect entries are stored on this device and synced to your account (an account is required to use Sustain), so they're available if you switch phones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Updated 2026-08-06 for 2.1: this used to say "two further
                    // features," which stopped being true the moment lab result
                    // import shipped — it also sends a user-chosen photo (the lab
                    // report) off-device to transcribe, the same category of data
                    // flow as the photo estimate. Leaving it at "two" would have
                    // been exactly the kind of disclosed-vs-actual mismatch this
                    // app's real App Review rejection history warns about (see
                    // APP_REVIEW_NOTES.md). Progress photos, this version's other
                    // new feature, correctly isn't mentioned here — it's on-device
                    // only and never transmitted, so it isn't one of these.
                    //
                    // Found stale again in the pre-2.2-submission audit: this still
                    // said "Three further features" and didn't mention two AI
                    // features that shipped since it was last updated — the AI chat
                    // coach (comp-022) sends the user's typed question plus that
                    // week's aggregated dose/protein/weight figures, and the AI body
                    // scan (`BodyScanEstimator`) sends the two body-composition
                    // photos taken for it. Both are the exact same category of
                    // off-device AI data flow already disclosed for the other three,
                    // just never added to this count — precisely the kind of
                    // disclosed-vs-actual drift this file's own comment history keeps
                    // warning about. Now names all five.
                    Text("Five further features are optional on top of that: the AI photo estimate sends the food photo you choose, lab result import sends the lab report photo you choose (to transcribe its values, never to interpret them), the weekly recap sends that week's dose, protein, and weight figures, the AI chat coach sends your typed question plus that same weekly summary, and the AI body scan sends the two photos you take for it, all to our AI provider to generate a result. None is used to train models, and none runs unless you tap it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Rewritten 2026-08-01: sign-out and delete-account both now
                    // always back up (sign-out only) and clear this device's local
                    // copy — see `AccountSectionView`'s confirmation-dialog header
                    // comment for the full reasoning. The previous version of this
                    // text (accurate as of 2026-07-31) described a "keep data on
                    // this device" choice that no longer exists for either action.
                    Text("Signing out or deleting your account clears this device's copy of your data: signing out backs it up to your account first, so it comes back the next time you sign in. Deleting your account removes it from the cloud permanently first, which can't be undone. Either way, you'll be asked to sign in again right away, since an account is required to keep using Sustain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Support") {
                    Link(destination: URL(string: "mailto:support@hearthlyapps.com")!) {
                        LabeledContent("Contact support", value: "support@hearthlyapps.com")
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingEditProfile) {
                if let profile {
                    MedicationProfileEditView(profile: profile)
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(trigger: .settingsMenu)
            }
            // Same "stuck in light mode" fix as `ChatCoachView` — see that
            // file's comment for the full explanation.
            .preferredColorScheme(nil)
            // Without this, SwiftUI can render confirmationDialog as a small
            // anchored popover (with the odd floating-bubble-and-arrow look)
            // instead of a full-width bottom sheet whenever the size class
            // reads as regular-width — Sustain is iPhone-only, so it should
            // never actually be in that size class, but forcing the sheet
            // style here removes any doubt regardless of simulator window
            // sizing quirks.
            .presentationCompactAdaptation(.sheet)
        }
    }
}

private extension Bundle {
    var appVersionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [
            MedicationProfile.self, DoseLog.self, WeightEntry.self, ProteinEntry.self, SideEffectLog.self,
        ], inMemory: true)
}
