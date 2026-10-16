import Foundation
import SwiftData

enum SyncError: LocalizedError {
    case missingConfig
    case notSignedIn
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Account sync isn't set up yet."
        case .notSignedIn:
            return "Sign in to sync your data."
        case .requestFailed(let message):
            return message
        }
    }
}

enum DataLinkingStrategy {
    /// Push whatever's on this device up (non-destructively), then pull
    /// everything the account has — local and cloud data both survive.
    /// Documented, disclosed tradeoff: this can produce duplicate entries if
    /// the exact same real-world event (e.g. the same dose) was logged
    /// independently on two devices before they were ever linked, since
    /// there's no way to tell that apart from two genuinely different doses
    /// logged close together. See this file's header comment.
    case merge
    /// Discard every local record on this device and replace it with
    /// whatever the account already has in the cloud. Destructive on this
    /// device only — never touches the cloud copy.
    case replace
}

/// The repository layer `PROJECT_HANDOFF.md` §17 flagged as a prerequisite
/// for cloud sync — "SwiftData remains the offline cache rather than the
/// source of truth" — implemented here as the one place that talks to
/// Supabase's Postgres tables via its built-in PostgREST API
/// (`/rest/v1/...`), instead of scattering network calls across every view
/// that touches a `@Model` type. SwiftData/`ModelContext` stays exactly what
/// it already was for every other feature in this app (the only thing views
/// query directly, via `@Query`); this class is additive, not a rewrite of
/// how local data works.
///
/// Talks to PostgREST directly over `URLSession`, no Supabase SDK — same
/// "REST + anon key, no new SPM dependency" choice `AuthManager` and
/// `AIProteinEstimator` both already made. Row-level security on every table
/// (`supabase/schema/account_sync.sql`) means the *user's* access token, not
/// just the anon key, has to be sent as the `Authorization` bearer on every
/// call: PostgREST resolves `auth.uid()` from that JWT's claims, and each
/// table's policies only allow a user to read/write rows where
/// `user_id = auth.uid()`. A request bearing only the anon key (as
/// `AIProteinEstimator`'s calls correctly do, since the Edge Function is
/// deliberately not user-scoped) would be rejected by every policy here —
/// this distinction is the reason sync needed `AuthManager` to exist first.
///
/// **Known, disclosed limitation**: this is additive-only sync. A record
/// deleted on one device does not (yet) get deleted from the cloud or from
/// other devices — `pushLocalData`/`pullRemoteData` only ever upsert, never
/// delete, because tracking deletions (tombstones, or a "deleted_at" column
/// and permanent-delete-after-N-days policy) is real additional design scope
/// beyond what this pass covers. This is exactly what made `SettingsView`'s
/// old "Reset all data" button pointless enough to remove outright
/// (2026-08-01, direct feedback: "there's no point of the reset all data
/// button now") rather than just relabel: it only ever cleared the local
/// SwiftData store, never the cloud copy, so tapping it while still signed
/// in and online had a real chance of quietly undoing itself the next time
/// something (Dashboard appearing, "Sync now") pulled the still-intact cloud
/// data back down. "Delete account" is now the one real, complete wipe
/// (deletes the cloud copy first via the Edge Function, then this device's
/// copy — see `AccountSectionView.performDeleteAccount()`); this class's
/// deletion-sync gap itself is unchanged and still worth revisiting someday,
/// but changing it piecemeal just to keep a redundant button working would
/// have been solving the wrong problem.
// Added 2026-08-06, deployment-readiness pass: found while investigating a
// real SIGABRT/malloc-corruption crash (`context.save()` aborting with
// "pointer being freed was not allocated") reproduced by temporarily
// disabling `SCREENSHOT_MODE` and letting a real signed-in account's launch
// sync run for real. This is a *different*, more serious bug than the
// already-documented screenshot-mode/seeder race in
// `DashboardView.syncCloudIfSignedIn`'s comment — it can hit any real user,
// screenshot mode never involved.
//
// Root cause: every caller of this class (`DashboardView`,
// `MandatorySignInView`, six logging views, ...) is a SwiftUI view holding
// the environment `ModelContext`, which is only safe to touch from the main
// actor. But none of this class's `async` functions were themselves
// actor-isolated, so once an `await` (a network call, or `syncSoon`'s own
// unstructured `Task { }`) suspended and resumed, Swift was free to resume
// execution on a background thread — and did resume there, `context.fetch`/
// `context.save()` and all. That raced against the main thread's own
// concurrent use of the *same* `ModelContext` (a `@Query`-driven view
// re-rendering, another screen's `modelContext.save()`), which is exactly
// the kind of same-context concurrent access SwiftData's storage isn't
// built to survive — the same failure mode the screenshot-mode comment
// above independently describes ("presumably from the merge conflicting
// with objects ... on the same context"), just triggered by ordinary thread
// scheduling instead of the seeder.
//
// Fix: pin the whole class to the main actor. Every real call site was
// already on the main actor to begin with (SwiftUI view bodies/methods), so
// this changes nothing about how or when sync runs — it just makes the
// `await` suspension points hop back to the main actor on resume instead of
// landing wherever the concurrency runtime felt like, closing the race
// without adding any new locking or restructuring the sync logic itself.
@Observable
@MainActor
final class CloudSyncManager {
    static let shared = CloudSyncManager()

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?

    /// True for the duration of `resolveAfterSignIn` — `ContentView` shows a
    /// brief loading state instead of `MainTabView`/`OnboardingFlow` while
    /// this is true. Added 2026-08-01 alongside making sign-out/delete-
    /// account always erase local data: since local now starts genuinely
    /// empty after *every* sign-in (not just some), the initial cloud pull
    /// this function does is no longer a rare case worth skipping past —
    /// without this gate, `ContentView` would show `MainTabView` the
    /// instant `auth.isSignedIn` flips true, with an empty Dashboard, for
    /// however long the network round trip inside this function takes,
    /// which reads exactly like data loss even though nothing is actually
    /// wrong. See `ContentView`'s own comment for how it's consumed.
    private(set) var isRestoringAfterSignIn = false

    private init() {}

    // MARK: - Linking flow (called once, right after sign-in, by
    // resolveAfterSignIn below)

    func hasLocalData(context: ModelContext) -> Bool {
        (try? context.fetchCount(FetchDescriptor<MedicationProfile>())) ?? 0 > 0
            || (try? context.fetchCount(FetchDescriptor<DoseLog>())) ?? 0 > 0
            || (try? context.fetchCount(FetchDescriptor<WeightEntry>())) ?? 0 > 0
            || (try? context.fetchCount(FetchDescriptor<ProteinEntry>())) ?? 0 > 0
            || (try? context.fetchCount(FetchDescriptor<SideEffectLog>())) ?? 0 > 0
    }

    func hasRemoteData() async throws -> Bool {
        !(try await fetchRemoteSnapshot()).isEmpty
    }

    /// Wipes every SwiftData record on this device only — never touches the
    /// cloud copy (same disclosed limitation as the rest of this file).
    ///
    /// Added 2026-07-31 for `SettingsView`'s then-existing "Reset all data"
    /// button (removed 2026-08-01 — see this file's header comment for why;
    /// this function's underlying logic stayed, just with a different set of
    /// callers now). Called today by `AccountSectionView.performSignOut()`
    /// and `.performDeleteAccount()`: sign-out and delete-account both
    /// always clear local data as a standard part of what they do, not
    /// something someone has to separately know to trigger — see
    /// `AccountSectionView`'s confirmation-dialog header comment for the
    /// full reasoning behind that.
    ///
    /// **Deliberately does NOT touch `hasCompletedOnboarding`** — it used to,
    /// which was correct for the old "Reset all data" button (genuinely
    /// starting over should re-show setup) but wrong once this function
    /// started being called on every sign-out too: signing out and back into
    /// the *same* account got wrongly treated as a first-time setup, a real
    /// bug reported directly ("if I log out of an account and log back in, I
    /// don't want to go through the setup screen again"). That decision
    /// already has a correct, account-aware home:
    /// `checkOnboardingFlagForAccountSwitch()`, called from
    /// `resolveAfterSignIn` right when a sign-in actually resolves, which
    /// only resets the flag if the signed-in account's ID differs from
    /// whichever account last completed onboarding on this device — same
    /// account back in, flag stays; different account, flag resets.
    func eraseLocalData(context: ModelContext) throws {
        for profile in try context.fetch(FetchDescriptor<MedicationProfile>()) { context.delete(profile) }
        for log in try context.fetch(FetchDescriptor<DoseLog>()) { context.delete(log) }
        for entry in try context.fetch(FetchDescriptor<WeightEntry>()) { context.delete(entry) }
        for entry in try context.fetch(FetchDescriptor<ProteinEntry>()) { context.delete(entry) }
        for log in try context.fetch(FetchDescriptor<SideEffectLog>()) { context.delete(log) }
        try context.save()

        NotificationManager.shared.cancelDoseReminder()
        NotificationManager.shared.cancelDailyProteinCheckIn()
    }

    /// **2026-08-01, removed the confirmation prompt this used to gate.**
    /// `needsLinkingChoice`/`linkingChoiceAccountAlreadyHasData` (and the
    /// `DataMergeChoiceView` sheet they drove, in `ContentView`) existed for
    /// the two cases below marked `(true, *)` — real, if increasingly rare
    /// (see the history two paragraphs down). Direct question that prompted
    /// removing it: "can't we just ignore the data that's already on the
    /// phone? What's the point of merging?" The honest answer is that
    /// `.merge` never deletes anything from either side — it's a pure
    /// union, by construction (every log-type record gets its own fresh
    /// UUID, so there's no genuine collision to arbitrate; see this file's
    /// header comment). Asking permission before doing something that can't
    /// lose data was solving a problem that had already been solved
    /// elsewhere: this class of choice only ever needed a confirmation
    /// dialog for the *destructive* alternative ("discard local, use only
    /// the account's data" — `DataMergeChoiceView`'s other button), which
    /// nothing currently exposes as a real user-facing action anymore. So
    /// both non-empty-local cases below now resolve the same way the
    /// `(false, true)` case always has: silently, with `.merge`.
    /// `DataMergeChoiceView.swift` was deleted along with the properties
    /// that drove it, rather than left as dead code no call site reaches.
    ///
    /// Decides what happens to a device's local data right after a
    /// successful sign-in. Shared by both `AccountSectionView` (sign-in from
    /// Settings) and `MandatorySignInView` (the app-wide sign-in gate every
    /// session now starts from — see that file) so this decision logic
    /// exists in exactly one place rather than being duplicated between the
    /// two call sites.
    ///
    /// **History, for context on why this used to be a prompt at all**: a
    /// real user flagged that signing into an unused/new account used to
    /// silently auto-attach whatever local data existed with no chance to
    /// say otherwise ("I should have more control on the data") — that's
    /// what originally introduced the confirmation screen this comment used
    /// to describe in detail. That concern was really about *silent*
    /// attachment of data that might not belong to the signed-in account,
    /// not about merging itself being risky — merging was never the
    /// dangerous half of that decision, discarding data silently was, and
    /// merging can't do that.
    ///
    /// Also resets the per-device `hasCompletedOnboarding` flag whenever the
    /// signed-in account's user ID differs from whichever account last
    /// completed onboarding on this device — see `checkOnboardingFlagFor
    /// AccountSwitch()` below. Without this, switching accounts on a device
    /// that had already completed onboarding for a *previous* account
    /// skipped `OnboardingFlow` entirely for the new one.
    ///
    /// **2026-08-01, separately**: `isRestoringAfterSignIn` wraps the whole
    /// function now, not just an implementation detail — see its own doc
    /// comment. Also, the `(true, *)` cases below are no longer the routine
    /// path they used to be: sign-out and delete-account both now always
    /// erase local data first (see `AccountSectionView`), so local
    /// genuinely has data at sign-in time only in the one remaining case
    /// that was never really about ambiguity between two *accounts* —
    /// someone updating from a version of the app old enough to have real
    /// local data from before an account was even required (or, in
    /// practice during development, a rebuild-over-an-existing-install that
    /// left local storage intact without a real reinstall). Either way,
    /// `.merge` is the correct, safe, non-destructive thing to do
    /// automatically.
    func resolveAfterSignIn(context: ModelContext) async throws {
        isRestoringAfterSignIn = true
        defer { isRestoringAfterSignIn = false }

        checkOnboardingFlagForAccountSwitch()

        let localHasData = hasLocalData(context: context)
        let remoteHasData = try await hasRemoteData()
        switch (localHasData, remoteHasData) {
        case (true, true), (true, false):
            // Both cases: this device has real local data, and merging
            // never deletes anything from either side — push it up, pull
            // down whatever the account already has, done. No prompt
            // needed for an action that can't lose data.
            try await resolveDataLinking(strategy: .merge, context: context)
        case (false, true):
            // Only the account has data, and this device has none of its
            // own to lose or misattribute — pull it down. `.replace` and
            // `.merge` are equivalent here since local is already empty,
            // but `.replace` skips a redundant push-of-nothing call.
            try await resolveDataLinking(strategy: .replace, context: context)
        case (false, false):
            break
        }
    }

    /// `OnboardingFlow.completeOnboarding()` records which account's ID
    /// `hasCompletedOnboarding` was last set true for. If the account now
    /// signed in doesn't match that (including "no record at all," e.g. a
    /// fresh install), the flag is reset so `ContentView` routes back
    /// through `OnboardingFlow` for this account — pre-filled from whatever
    /// data this device has, per that view's own header comment — instead
    /// of skipping straight to `MainTabView` on the strength of a *different*
    /// account's completed setup.
    private func checkOnboardingFlagForAccountSwitch() {
        let defaults = UserDefaults.standard
        let currentUserID = AuthManager.shared.session?.userId.uuidString
        let lastCompletedUserID = defaults.string(forKey: "onboardingCompletedForUserID")
        guard currentUserID != lastCompletedUserID else { return }
        defaults.set(false, forKey: "hasCompletedOnboarding")
    }

    /// The one entry point `resolveAfterSignIn` above calls (2026-08-01: the
    /// only caller now — this used to also be called directly from a
    /// confirmation screen a person tapped through; see `resolveAfterSignIn`'s
    /// doc comment for why that screen was removed). Everything else in this
    /// file is a helper for this.
    ///
    /// **2026-07-31 history**: this briefly also force-set the device-local
    /// `hasCompletedOnboarding` flag to `true` whenever data existed after
    /// resolving, so a returning user signing into a new device would skip
    /// straight past the medication/dose/goals setup wizard. Superseded the
    /// same day: rather than silently skipping that screen, `OnboardingFlow`
    /// now always runs once per device and pre-fills itself from whatever
    /// `MedicationProfile`/`WeightEntry` already exists (which this function
    /// is what actually populates, via `.merge`/`.replace` below) — so a
    /// returning user reviews and confirms their real data instead of either
    /// re-entering it from scratch or never seeing it confirmed at all. See
    /// `OnboardingViewModel.prefill(from:latestWeight:)` and
    /// `OnboardingFlow.completeOnboarding()`'s update-in-place logic.
    func resolveDataLinking(strategy: DataLinkingStrategy, context: ModelContext) async throws {
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            switch strategy {
            case .merge:
                // Fetch before push (not after, as this used to) so the
                // last-write-wins comparison in `pushLocalData`/`apply` below
                // has something to compare against — see those functions'
                // doc comments.
                let snapshot = try await fetchRemoteSnapshot()
                try await pushLocalData(context: context, remoteProfiles: snapshot.profiles)
                try apply(snapshot, replacingLocal: false, context: context)
            case .replace:
                let snapshot = try await fetchRemoteSnapshot()
                try apply(snapshot, replacingLocal: true, context: context)
            }
        } catch {
            lastSyncError = error.localizedDescription
            throw error
        }
    }

    /// Ongoing sync for an already-linked account: push anything new/changed
    /// locally, then pull anything new from other devices. Safe to call
    /// often (e.g. on Dashboard appearance, alongside the existing
    /// `HealthKitManager` import-on-appear pattern) — every call is a full
    /// upsert-both-ways, not an incremental diff, which is simple and
    /// correct at this app's realistic data volume (a few thousand rows per
    /// user, not millions) even if it isn't the most bandwidth-efficient
    /// approach possible.
    func syncNow(context: ModelContext) async throws {
        // Real crash found capturing 2.1 App Store screenshots on a signed-in
        // account with real cloud history: `ScreenshotModeSeeder` wipes and
        // fabricates local data on every launch, but this had no awareness of
        // that, so it pulled the real remote data straight back down over the
        // freshly-seeded fake dataset — full root-cause writeup in
        // `DashboardView.syncCloudIfSignedIn`, which is now also guarded, but
        // `syncSoon` below has six other call sites (every logging view) that
        // would otherwise still be able to push fabricated data *up* into a
        // real account. Gating both entry points here, rather than each call
        // site individually, is the single choke point that actually
        // guarantees no network read or write happens while capturing
        // screenshots — never compiled into a Release build, so real users'
        // sync is completely unaffected.
        #if SCREENSHOT_MODE
        throw SyncError.notSignedIn
        #else
        guard AuthManager.shared.isSignedIn else { throw SyncError.notSignedIn }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            // Fetch before push (not after) so the last-write-wins comparison
            // in `pushLocalData`/`apply` below has the cloud's current
            // `updated_at` to compare each local profile against before
            // deciding whether to overwrite it or be overwritten by it.
            let snapshot = try await fetchRemoteSnapshot()
            try await pushLocalData(context: context, remoteProfiles: snapshot.profiles)
            try apply(snapshot, replacingLocal: false, context: context)
        } catch {
            lastSyncError = error.localizedDescription
            throw error
        }
        #endif
    }

    /// Fire-and-forget sync trigger for "the instant something local
    /// changed," meant to be called right after every logging/editing
    /// view's own `modelContext.save()` — this is what makes sync actually
    /// real-time instead of only once-per-app-session (see `DashboardView`'s
    /// `syncCloudIfSignedIn`, which only covers app launch/foreground and
    /// remains the *first* sync of any given session). A no-op if not signed
    /// in, or if a sync is already in flight — rapid-fire logging (quick-add
    /// chips, a multi-photo protein entry) would otherwise queue up several
    /// redundant overlapping syncs; since every sync already does a full
    /// upsert-both-ways rather than an incremental diff, letting an
    /// in-flight sync finish and simply catch the latest local state on its
    /// own is equivalent to also firing a second one back-to-back, at a
    /// fraction of the network cost and with no risk of two concurrent
    /// `ModelContext` operations racing each other. Errors are swallowed
    /// here by design: `lastSyncError` already surfaces the most recent
    /// failure inline in Settings -> Account & sync, and popping a network-
    /// error alert on top of a *successful* local save would misleadingly
    /// read as "your entry didn't save," when only the separate cloud copy
    /// is what's delayed.
    func syncSoon(context: ModelContext) {
        // See `syncNow` above: gated the same way, for the same reason — this
        // is the push-side entry point called from six logging views, and
        // needs the same guarantee that nothing reaches the network while
        // `SCREENSHOT_MODE` is capturing fabricated data.
        #if SCREENSHOT_MODE
        return
        #else
        guard AuthManager.shared.isSignedIn, !isSyncing else { return }
        Task {
            try? await syncNow(context: context)
        }
        #endif
    }

    // MARK: - Push

    /// `remoteProfiles` is the cloud's `medication_profiles` rows as of just
    /// before this push — passed in (rather than fetched here) so callers
    /// fetch the remote snapshot exactly once and use it consistently for
    /// both this decision and the `apply()` pull that follows it.
    ///
    /// **Last-write-wins by timestamp (2026-08-01)**, added for a disclosed
    /// two-device sync gap: unlike the four log types below (each new entry
    /// gets its own fresh `id`, so pushing/pulling both directions is always
    /// correct — nothing to conflict), there's exactly one active
    /// `MedicationProfile` per account. Without this check, this function
    /// used to unconditionally push every local profile row regardless of
    /// whether the cloud's copy was actually newer — so a device that had
    /// been offline, with a stale local edit, could reconnect and silently
    /// clobber a genuinely newer edit made on another device in the
    /// meantime. Now, a local profile only gets uploaded if it's at least as
    /// new as the cloud's current copy of that same profile (`>=`, not `>`,
    /// so a profile that hasn't been touched anywhere still pushes
    /// normally); otherwise it's skipped here and instead picked up by
    /// `apply()`'s matching check, which pulls the newer cloud copy down
    /// over the stale local one. This is a client-side comparison, not a
    /// server-side conditional write, so a narrow race is still possible if
    /// both devices push at nearly the same instant — acceptable for the
    /// common case this was actually reported for (one device offline for a
    /// while, not two simultaneous edits), and it's a strict improvement
    /// over "whichever push happens to land last wins, even if it's older."
    private func pushLocalData(context: ModelContext, remoteProfiles: [MedicationProfileDTO] = []) async throws {
        guard let userId = AuthManager.shared.session?.userId else { throw SyncError.notSignedIn }

        let profiles = (try? context.fetch(FetchDescriptor<MedicationProfile>())) ?? []
        let doseLogs = (try? context.fetch(FetchDescriptor<DoseLog>())) ?? []
        let weightEntries = (try? context.fetch(FetchDescriptor<WeightEntry>())) ?? []
        let proteinEntries = (try? context.fetch(FetchDescriptor<ProteinEntry>())) ?? []
        let sideEffectLogs = (try? context.fetch(FetchDescriptor<SideEffectLog>())) ?? []

        let remoteProfilesById = Dictionary(uniqueKeysWithValues: remoteProfiles.map { ($0.id, $0) })
        let profilesToPush = profiles.filter { local in
            guard let remote = remoteProfilesById[local.id] else { return true }
            return local.updatedAt >= remote.updatedAt
        }

        try await upsert("medication_profiles", rows: profilesToPush.map { MedicationProfileDTO(model: $0, userId: userId) })
        try await upsert("dose_logs", rows: doseLogs.map { DoseLogDTO(model: $0, userId: userId) })
        try await upsert("weight_entries", rows: weightEntries.map { WeightEntryDTO(model: $0, userId: userId) })
        try await upsert("protein_entries", rows: proteinEntries.map { ProteinEntryDTO(model: $0, userId: userId) })
        try await upsert("side_effect_logs", rows: sideEffectLogs.map { SideEffectLogDTO(model: $0, userId: userId) })
    }

    // MARK: - Pull

    private struct RemoteSnapshot {
        let profiles: [MedicationProfileDTO]
        let doseLogs: [DoseLogDTO]
        let weightEntries: [WeightEntryDTO]
        let proteinEntries: [ProteinEntryDTO]
        let sideEffectLogs: [SideEffectLogDTO]

        var isEmpty: Bool {
            profiles.isEmpty && doseLogs.isEmpty && weightEntries.isEmpty
                && proteinEntries.isEmpty && sideEffectLogs.isEmpty
        }
    }

    private func fetchRemoteSnapshot() async throws -> RemoteSnapshot {
        async let profiles: [MedicationProfileDTO] = fetch("medication_profiles")
        async let doseLogs: [DoseLogDTO] = fetch("dose_logs")
        async let weightEntries: [WeightEntryDTO] = fetch("weight_entries")
        async let proteinEntries: [ProteinEntryDTO] = fetch("protein_entries")
        async let sideEffectLogs: [SideEffectLogDTO] = fetch("side_effect_logs")
        return try await RemoteSnapshot(
            profiles: profiles, doseLogs: doseLogs, weightEntries: weightEntries,
            proteinEntries: proteinEntries, sideEffectLogs: sideEffectLogs
        )
    }

    /// Applies a pulled snapshot into the local SwiftData store.
    /// `replacingLocal: true` (the "replace" linking choice) deletes every
    /// existing local row first; `false` (the ongoing-sync / "merge" path)
    /// upserts by `id` instead, so a record already present locally is
    /// updated in place rather than duplicated, and a record that only
    /// exists remotely is inserted new.
    private func apply(_ snapshot: RemoteSnapshot, replacingLocal: Bool, context: ModelContext) throws {
        if replacingLocal {
            for profile in (try? context.fetch(FetchDescriptor<MedicationProfile>())) ?? [] { context.delete(profile) }
            for log in (try? context.fetch(FetchDescriptor<DoseLog>())) ?? [] { context.delete(log) }
            for entry in (try? context.fetch(FetchDescriptor<WeightEntry>())) ?? [] { context.delete(entry) }
            for entry in (try? context.fetch(FetchDescriptor<ProteinEntry>())) ?? [] { context.delete(entry) }
            for log in (try? context.fetch(FetchDescriptor<SideEffectLog>())) ?? [] { context.delete(log) }
        }

        // Last-write-wins: only overwrite an already-existing local profile
        // if the incoming remote copy is actually newer. Without this guard,
        // this snapshot was fetched *before* `pushLocalData` ran (see
        // `syncNow`/`resolveDataLinking`), so a profile this device just won
        // the push for (its local edit was the newer one) would otherwise
        // get immediately overwritten right back with the stale pre-push
        // remote value fetched a moment earlier — silently undoing the push
        // that just happened. See `pushLocalData`'s doc comment for the
        // matching push-side half of this mechanism. `replacingLocal: true`
        // callers never reach this branch for an "existing" row anyway
        // (local was already wiped first), so this only affects ongoing
        // sync, which is exactly where the conflict can occur.
        try upsertLocal(snapshot.profiles, context: context) { dto, existing in
            guard dto.updatedAt > existing.updatedAt else { return }
            dto.apply(to: existing)
        } insert: { $0.makeModel() }
        try upsertLocal(snapshot.doseLogs, context: context) { dto, existing in dto.apply(to: existing) } insert: { $0.makeModel() }
        try upsertLocal(snapshot.weightEntries, context: context) { dto, existing in dto.apply(to: existing) } insert: { $0.makeModel() }
        try upsertLocal(snapshot.proteinEntries, context: context) { dto, existing in dto.apply(to: existing) } insert: { $0.makeModel() }
        try upsertLocal(snapshot.sideEffectLogs, context: context) { dto, existing in dto.apply(to: existing) } insert: { $0.makeModel() }

        try context.save()
    }

    private func upsertLocal<Model: PersistentModel, DTO: SyncDTO>(
        _ dtos: [DTO],
        context: ModelContext,
        update: (DTO, Model) -> Void,
        insert: (DTO) -> Model
    ) throws where DTO.ModelType == Model {
        guard !dtos.isEmpty else { return }
        // Fetch-all-and-match-in-memory rather than a `#Predicate`-based
        // lookup: SwiftData's `#Predicate` macro needs to reference a
        // concrete stored property, and this helper is generic across five
        // unrelated `@Model` types that each separately declare their own
        // `id: UUID` — there's no single predicate expression that works for
        // all of them. Matching in memory is correct at this app's realistic
        // per-user row counts (thousands, not millions) and far simpler than
        // five near-duplicate per-type predicate fetches.
        let existingModels = (try? context.fetch(FetchDescriptor<Model>())) ?? []
        let existingById = Dictionary(uniqueKeysWithValues: existingModels.compactMap { model -> (UUID, Model)? in
            guard let id = (model as? any SyncIdentifiable)?.id else { return nil }
            return (id, model)
        })

        for dto in dtos {
            if let existing = existingById[dto.id] {
                update(dto, existing)
            } else {
                context.insert(insert(dto))
            }
        }
    }

    // MARK: - Low-level PostgREST calls

    private func upsert<T: Encodable>(_ table: String, rows: [T]) async throws {
        guard !rows.isEmpty else { return }
        guard let config = SupabaseConfig.shared else { throw SyncError.missingConfig }
        guard let session = AuthManager.shared.session else { throw SyncError.notSignedIn }
        try await AuthManager.shared.refreshSessionIfNeeded()
        let accessToken = AuthManager.shared.session?.accessToken ?? session.accessToken

        var components = URLComponents(url: config.projectURL.appendingPathComponent("rest/v1/\(table)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
        guard let url = components?.url else { throw SyncError.requestFailed("Invalid sync URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try SupabaseConfig.encoder.encode(rows)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown error"
            throw SyncError.requestFailed("Sync upload failed (\(table)): \(bodyText)")
        }
    }

    private func fetch<T: Decodable>(_ table: String) async throws -> [T] {
        guard let config = SupabaseConfig.shared else { throw SyncError.missingConfig }
        guard let session = AuthManager.shared.session else { throw SyncError.notSignedIn }
        try await AuthManager.shared.refreshSessionIfNeeded()
        let accessToken = AuthManager.shared.session?.accessToken ?? session.accessToken

        var components = URLComponents(url: config.projectURL.appendingPathComponent("rest/v1/\(table)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "select", value: "*")]
        guard let url = components?.url else { throw SyncError.requestFailed("Invalid sync URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown error"
            throw SyncError.requestFailed("Sync download failed (\(table)): \(bodyText)")
        }
        return try SupabaseConfig.decoder.decode([T].self, from: data)
    }
}

// MARK: - DTO <-> SwiftData mapping

/// A tiny shared shape so `CloudSyncManager`'s generic upsert-by-id helper
/// can look up "does a local row with this DTO's id already exist" without
/// each of the five `@Model` types needing to know anything about sync.
private protocol SyncIdentifiable {
    var id: UUID { get }
}
extension MedicationProfile: SyncIdentifiable {}
extension DoseLog: SyncIdentifiable {}
extension WeightEntry: SyncIdentifiable {}
extension ProteinEntry: SyncIdentifiable {}
extension SideEffectLog: SyncIdentifiable {}

private protocol SyncDTO: Codable {
    associatedtype ModelType: PersistentModel
    var id: UUID { get }
    func apply(to model: ModelType)
    func makeModel() -> ModelType
}

private struct MedicationProfileDTO: SyncDTO {
    typealias ModelType = MedicationProfile

    let id: UUID
    let userId: UUID
    let medication: String
    let form: String
    let frequency: String
    let startDate: Date
    let currentDoseMg: Double
    let startingWeightLbs: Double?
    let targetWeightLbs: Double?
    let isActive: Bool
    let createdAt: Date
    let plannedNextDoseMg: Double?
    let plannedDoseChangeDate: Date?
    let hasStartedMedication: Bool
    /// Added 2026-08-01 for last-write-wins conflict resolution — see
    /// `MedicationProfile.updatedAt`'s doc comment and `pushLocalData`'s for
    /// how this field is actually used to decide which side of a two-device
    /// edit wins. Requires a matching `updated_at timestamptz` column on the
    /// `medication_profiles` table (`supabase/schema/account_sync.sql`).
    let updatedAt: Date
    /// Raw comma-joined weekday list for a `.specificDays` schedule — see
    /// `MedicationProfile.scheduledWeekdaysRaw`'s doc comment. Synced as the
    /// same plain string the model stores, not a parsed array/set: simplest
    /// option for seven small integers, and avoids yet another
    /// encode/decode shape to keep in sync between this DTO and the model.
    /// Empty string (never nil) for every profile that isn't on a
    /// specific-days schedule, matching the model's own non-optional
    /// default.
    let scheduledWeekdaysRaw: String
    /// Added 2026-08-02 for comp-010 (`sustain-pros-and-cons.json`, custom
    /// medication entry) — see `MedicationProfile.customMedicationName`'s doc
    /// comment. Both `nil` for every non-`.custom` profile, matching that
    /// property's own convention. Requires two new nullable columns on the
    /// `medication_profiles` Supabase table (`custom_medication_name text`,
    /// `custom_half_life_hours double precision`) — not yet added to
    /// `supabase/schema/account_sync.sql` in this pass; see that file's own
    /// note for the exact `ALTER TABLE` needed before this round-trips through
    /// sync for a real custom medication.
    let customMedicationName: String?
    let customHalfLifeHours: Double?

    enum CodingKeys: String, CodingKey {
        case id, medication, form, frequency, startDate = "start_date", currentDoseMg = "current_dose_mg"
        case startingWeightLbs = "starting_weight_lbs", targetWeightLbs = "target_weight_lbs"
        case isActive = "is_active", createdAt = "created_at", plannedNextDoseMg = "planned_next_dose_mg"
        case plannedDoseChangeDate = "planned_dose_change_date", hasStartedMedication = "has_started_medication"
        case userId = "user_id", updatedAt = "updated_at"
        case scheduledWeekdaysRaw = "scheduled_weekdays"
        case customMedicationName = "custom_medication_name"
        case customHalfLifeHours = "custom_half_life_hours"
    }

    init(model: MedicationProfile, userId: UUID) {
        id = model.id
        self.userId = userId
        medication = model.medicationRaw
        form = model.formRaw
        frequency = model.frequencyRaw
        startDate = model.startDate
        currentDoseMg = model.currentDoseMg
        startingWeightLbs = model.startingWeightLbs
        targetWeightLbs = model.targetWeightLbs
        isActive = model.isActive
        createdAt = model.createdAt
        plannedNextDoseMg = model.plannedNextDoseMg
        plannedDoseChangeDate = model.plannedDoseChangeDate
        hasStartedMedication = model.hasStartedMedication
        updatedAt = model.updatedAt
        scheduledWeekdaysRaw = model.scheduledWeekdaysRaw
        customMedicationName = model.customMedicationName
        customHalfLifeHours = model.customHalfLifeHours
    }

    // A hand-written `encode(to:)` is required here, not just the compiler-
    // synthesized one `Codable` would normally generate for free — this was
    // a real bug caught live (2026-07-30): Swift's synthesized encoding for
    // `Optional` stored properties uses `encodeIfPresent`, which *omits the
    // key entirely* when the value is `nil`, rather than writing `null`. A
    // single row upserts fine either way, but `CloudSyncManager.upsert`
    // sends every row as one JSON *array* in a single POST, and PostgREST
    // requires every object in a batch array to have identical keys — two
    // profiles that differ in which of this type's four optional fields
    // happen to be nil produced objects with different key sets, and
    // PostgREST rejected the whole batch with `PGRST102 "All object keys
    // must match"`. Explicitly calling `encode` (not `encodeIfPresent`) for
    // every optional forces a real `null` into the JSON instead of omitting
    // the key, so every row in a batch always has the same key set
    // regardless of which fields are actually nil. `init(from:)` doesn't
    // need the same treatment — decoding a missing key and decoding an
    // explicit `null` both already resolve to `nil` identically, so only
    // the encode direction was ever broken.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(medication, forKey: .medication)
        try container.encode(form, forKey: .form)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(currentDoseMg, forKey: .currentDoseMg)
        try container.encode(startingWeightLbs, forKey: .startingWeightLbs)
        try container.encode(targetWeightLbs, forKey: .targetWeightLbs)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(plannedNextDoseMg, forKey: .plannedNextDoseMg)
        try container.encode(plannedDoseChangeDate, forKey: .plannedDoseChangeDate)
        try container.encode(hasStartedMedication, forKey: .hasStartedMedication)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(scheduledWeekdaysRaw, forKey: .scheduledWeekdaysRaw)
        try container.encode(customMedicationName, forKey: .customMedicationName)
        try container.encode(customHalfLifeHours, forKey: .customHalfLifeHours)
    }

    func apply(to model: MedicationProfile) {
        model.medicationRaw = medication
        model.formRaw = form
        model.frequencyRaw = frequency
        model.startDate = startDate
        model.currentDoseMg = currentDoseMg
        model.startingWeightLbs = startingWeightLbs
        model.targetWeightLbs = targetWeightLbs
        model.isActive = isActive
        model.plannedNextDoseMg = plannedNextDoseMg
        model.plannedDoseChangeDate = plannedDoseChangeDate
        model.hasStartedMedication = hasStartedMedication
        model.updatedAt = updatedAt
        model.scheduledWeekdaysRaw = scheduledWeekdaysRaw
        model.customMedicationName = customMedicationName
        model.customHalfLifeHours = customHalfLifeHours
    }

    func makeModel() -> MedicationProfile {
        let model = MedicationProfile(
            medication: MedicationOption(rawValue: medication) ?? .other,
            form: MedicationForm(rawValue: form) ?? .injection,
            frequency: DoseFrequency(rawValue: frequency) ?? .weekly,
            startDate: startDate,
            currentDoseMg: currentDoseMg,
            startingWeightLbs: startingWeightLbs,
            targetWeightLbs: targetWeightLbs,
            plannedNextDoseMg: plannedNextDoseMg,
            plannedDoseChangeDate: plannedDoseChangeDate,
            hasStartedMedication: hasStartedMedication,
            updatedAt: updatedAt,
            customMedicationName: customMedicationName,
            customHalfLifeHours: customHalfLifeHours
        )
        model.id = id
        model.isActive = isActive
        model.scheduledWeekdaysRaw = scheduledWeekdaysRaw
        return model
    }
}

private struct DoseLogDTO: SyncDTO {
    typealias ModelType = DoseLog

    let id: UUID
    let userId: UUID
    let date: Date
    let doseMg: Double
    let form: String
    let injectionSite: String?
    let skipped: Bool
    let notes: String

    enum CodingKeys: String, CodingKey {
        case id, date, form, skipped, notes
        case userId = "user_id", doseMg = "dose_mg", injectionSite = "injection_site"
    }

    init(model: DoseLog, userId: UUID) {
        id = model.id
        self.userId = userId
        date = model.date
        doseMg = model.doseMg
        form = model.formRaw
        injectionSite = model.injectionSiteRaw
        skipped = model.skipped
        notes = model.notes
    }

    // Same fix, same reason, as `MedicationProfileDTO.encode(to:)` above —
    // `injectionSite` is this type's one optional field, and the compiler-
    // synthesized encoder would otherwise omit its key on rows where it's
    // nil (a skipped dose, or an oral-pill dose with no injection site),
    // producing batches with inconsistent keys across a multi-row upsert.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(date, forKey: .date)
        try container.encode(doseMg, forKey: .doseMg)
        try container.encode(form, forKey: .form)
        try container.encode(injectionSite, forKey: .injectionSite)
        try container.encode(skipped, forKey: .skipped)
        try container.encode(notes, forKey: .notes)
    }

    func apply(to model: DoseLog) {
        model.date = date
        model.doseMg = doseMg
        model.formRaw = form
        model.injectionSiteRaw = injectionSite
        model.skipped = skipped
        model.notes = notes
    }

    func makeModel() -> DoseLog {
        let model = DoseLog(
            date: date, doseMg: doseMg,
            form: MedicationForm(rawValue: form) ?? .injection,
            injectionSite: injectionSite.flatMap(InjectionSite.init(rawValue:)),
            skipped: skipped, notes: notes
        )
        model.id = id
        return model
    }
}

private struct WeightEntryDTO: SyncDTO {
    typealias ModelType = WeightEntry

    let id: UUID
    let userId: UUID
    let date: Date
    let weightLbs: Double
    let source: String

    enum CodingKeys: String, CodingKey {
        case id, date, source
        case userId = "user_id", weightLbs = "weight_lbs"
    }

    init(model: WeightEntry, userId: UUID) {
        id = model.id
        self.userId = userId
        date = model.date
        weightLbs = model.weightLbs
        source = model.sourceRaw
    }

    func apply(to model: WeightEntry) {
        model.date = date
        model.weightLbs = weightLbs
        model.sourceRaw = source
    }

    func makeModel() -> WeightEntry {
        let model = WeightEntry(date: date, weightLbs: weightLbs, source: EntrySource(rawValue: source) ?? .manual)
        model.id = id
        return model
    }
}

private struct ProteinEntryDTO: SyncDTO {
    typealias ModelType = ProteinEntry

    let id: UUID
    let userId: UUID
    let date: Date
    let grams: Double
    let note: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case id, date, grams, note, source
        case userId = "user_id"
    }

    init(model: ProteinEntry, userId: UUID) {
        id = model.id
        self.userId = userId
        date = model.date
        grams = model.grams
        note = model.note
        source = model.sourceRaw
    }

    func apply(to model: ProteinEntry) {
        model.date = date
        model.grams = grams
        model.note = note
        model.sourceRaw = source
    }

    func makeModel() -> ProteinEntry {
        let model = ProteinEntry(date: date, grams: grams, note: note, source: EntrySource(rawValue: source) ?? .manual)
        model.id = id
        return model
    }
}

private struct SideEffectLogDTO: SyncDTO {
    typealias ModelType = SideEffectLog

    let id: UUID
    let userId: UUID
    let date: Date
    let symptom: String
    let severity: Int
    let notes: String

    enum CodingKeys: String, CodingKey {
        case id, date, symptom, severity, notes
        case userId = "user_id"
    }

    init(model: SideEffectLog, userId: UUID) {
        id = model.id
        self.userId = userId
        date = model.date
        symptom = model.symptomRaw
        severity = model.severity
        notes = model.notes
    }

    func apply(to model: SideEffectLog) {
        model.date = date
        model.symptomRaw = symptom
        model.severity = severity
        model.notes = notes
    }

    func makeModel() -> SideEffectLog {
        let model = SideEffectLog(
            date: date,
            symptom: SideEffectSymptom(rawValue: symptom) ?? .other,
            severity: severity, notes: notes
        )
        model.id = id
        return model
    }
}
