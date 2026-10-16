import SwiftData
import SwiftUI

/// The conversational counterpart to `WeeklySummaryCard`'s passive recap —
/// see `AIChatCoachService.swift`'s header comment for the full feature
/// rationale (comp-022) and its scope cuts (no persisted history, no sync).
///
/// Gated behind Sustain+ and the same trial AI-call budget as the photo
/// estimate and weekly recap (`EntitlementManager.canUseAIFeature`/
/// `recordAIUsage()`) — one call recorded per user message sent, matching
/// how the photo estimate records one call per estimate.
struct ChatCoachView: View {
    @Environment(\.dismiss) private var dismiss

    let profile: MedicationProfile

    @Query(sort: \DoseLog.date, order: .reverse) private var doseLogs: [DoseLog]
    @Query(sort: \WeightEntry.date, order: .reverse) private var weightEntries: [WeightEntry]
    @Query(sort: \ProteinEntry.date, order: .reverse) private var proteinEntries: [ProteinEntry]
    @Query(sort: \SideEffectLog.date, order: .reverse) private var sideEffectLogs: [SideEffectLog]
    // Added 2026-08-03: previously this view had no access to lab results at
    // all, so a question like "how are my lab results?" correctly (if
    // unhelpfully) got "I don't have access to that data." See
    // `AIChatCoachService.systemPrompt(for:labResults:)`'s doc comment for
    // the guardrails that came with actually wiring this in.
    @Query(sort: \LabResultEntry.date, order: .reverse) private var labResults: [LabResultEntry]

    @State private var entitlements = EntitlementManager.shared
    @State private var showingPaywall = false
    @State private var showingTrialLimitAlert = false

    @State private var messages: [ChatMessage] = []
    @State private var draftText = ""
    @State private var isSending = false
    @State private var errorMessage = ""
    @State private var showingError = false

    // Triage item 3 — see `MaintenanceGuideView.swift`'s header comment on
    // the same key. Kept in sync here so a maintenance-mode user asking the
    // chat coach about their week gets the same "staying in range" framing
    // as the passive weekly recap, not the active-weight-loss framing.
    @AppStorage("maintenanceGraduationModeEnabled") private var maintenanceModeEnabled = false

    private var weeklyInput: WeeklySummaryInput {
        ProgressCalculator.weeklySummaryInput(
            profile: profile,
            doseLogs: doseLogs,
            weightEntries: weightEntries,
            proteinEntries: proteinEntries,
            sideEffectLogs: sideEffectLogs,
            isInMaintenanceMode: maintenanceModeEnabled
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            introCard

                            ForEach(messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }

                            if isSending {
                                HStack(spacing: 6) {
                                    ProgressView()
                                    Text("Thinking…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 4)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages) { _, _ in
                        guard let last = messages.last else { return }
                        withAnimation {
                            scrollProxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                Divider()
                composer
            }
            .navigationTitle("Ask Sustain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(trigger: .aiChatCoach)
            }
            // Caught during manual testing (2026-08-03): `PaywallView` forces
            // `.preferredColorScheme(.light)` for its acquisition pitch (see
            // that file's header comment — it's deliberate, evidence-based).
            // Because this view never asserted a scheme of its own, it was
            // passively "inheriting" the system setting rather than actively
            // holding it — and dismissing a nested sheet that forced a scheme
            // doesn't reliably hand control back to a parent that never
            // claimed it, a known SwiftUI/UIKit quirk with
            // `overrideUserInterfaceStyle` on stacked sheets. The result: this
            // whole chat sheet stayed stuck in light mode after backing out
            // of the paywall, only correcting itself once the chat sheet
            // itself was torn down. Explicitly asserting `nil` here (i.e.
            // "actively follow the system setting") makes this view reclaim
            // its own scheme the moment the paywall sheet is gone, instead of
            // leaving that decision unclaimed.
            .preferredColorScheme(nil)
            .alert("You've used all your trial AI questions", isPresented: $showingTrialLimitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Subscribe to Sustain+ for unlimited questions.")
            }
            .alert("Couldn't send that", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about your own logged data: dose timing, protein trends, side-effect patterns, and any lab results you've logged. This isn't medical advice, and it never suggests a dose, evaluates a lab value, or diagnoses anything.")
                .font(.caption)
                .foregroundStyle(.secondary)
            MedicalSourcesLink(topic: .dosing, label: "What Sustain can and can't tell you")
        }
        .padding()
        .cardStyle()
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Real bug, found reviewing 2.1 screenshots: assistant bubbles
                // used `Theme.cardBackground` (`.secondarySystemGroupedBackground`,
                // white in light mode), but this screen's `ScrollView` never
                // sets a `Theme.screenBackground`/grouped background the way
                // most other screens do — it's the plain white system
                // background. White-on-white made every assistant reply look
                // like un-bubbled plain text floating on the screen, with only
                // the user's teal bubble visibly a "message." Switched to a
                // fixed `.systemGray5`, a standard messaging-app gray that's
                // visible regardless of this screen's background, rather than
                // also touching the screen's background color (a larger,
                // riskier change for a one-screen visual fix).
                .background(message.role == .user ? Theme.primary : Color(uiColor: .systemGray5))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        // Explicit `.bottom` alignment, added 2026-08-03 — raised during
        // manual testing as "recognition works, but there's no way to stop
        // recording." The button itself always worked (a second tap calls
        // `stopTranscribing()`), but this HStack had no alignment specified,
        // which defaults to `.center`. `draftText`'s `TextField` grows with
        // `axis: .vertical` as dictation fills it in, and live dictation
        // updates the bound text on nearly every word — so under center
        // alignment, the mic button's vertical position shifted continuously
        // while recording, making it a moving target exactly when someone
        // was trying to tap it to stop. Pinning to the bottom, matching the
        // TextField's own growth direction (new lines appear below the
        // first), keeps the button's position stable throughout.
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask a question…", text: $draftText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            // comp-027: voice chat is one of Vita AI's marketed features
            // alongside its AI chat coach — pairs naturally with this screen.
            VoiceInputButton(text: $draftText)
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding()
    }

    private func send() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard entitlements.isPremium else {
            showingPaywall = true
            return
        }
        guard entitlements.canUseAIFeature else {
            showingTrialLimitAlert = true
            AnalyticsManager.track(.aiScanBlockedTrialLimit(feature: .chatCoach))
            return
        }

        draftText = ""
        let userMessage = ChatMessage(role: .user, text: text)
        messages.append(userMessage)

        isSending = true
        Task {
            defer { isSending = false }
            do {
                let reply = try await AIChatCoachService.reply(
                    history: messages,
                    input: weeklyInput,
                    labResults: labResults
                )
                entitlements.recordAIUsage()
                AIFeatureEngagementTracker.recordUse(.chatCoach)
                AnalyticsManager.track(.aiScanCompleted(feature: .chatCoach))
                messages.append(ChatMessage(role: .assistant, text: reply))
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
                // Failed sends don't count against the trial budget or leave a
                // dangling user turn with no reply — removing it means retyping
                // is the retry path, same as a failed message in any chat app.
                messages.removeAll { $0.id == userMessage.id }
            }
        }
    }
}

#Preview {
    ChatCoachView(
        profile: MedicationProfile(
            medication: .zepbound, form: .injection, frequency: .weekly, startDate: .now, currentDoseMg: 5
        )
    )
    .modelContainer(for: [MedicationProfile.self, DoseLog.self, WeightEntry.self, ProteinEntry.self, SideEffectLog.self, LabResultEntry.self], inMemory: true)
}
