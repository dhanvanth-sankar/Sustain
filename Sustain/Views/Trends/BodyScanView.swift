import SwiftData
import SwiftUI

/// The capture/review flow for `BodyScanEstimator` — see that file's header
/// comment for the full reasoning behind this feature's scope and its
/// deliberate departures from the validated study's own protocol.
///
/// Driven by `Step` for the non-camera screens (consent, loading, result,
/// error) plus two independent `Bool`s (`showingFrontCapture`/
/// `showingSideCapture`) for the two sequential `CameraCaptureView`
/// captures — see those properties' doc comments for why the camera steps
/// are deliberately NOT part of `Step` and not inlined as switch-case
/// content the way the rest of this view is. The review screen shows the
/// range plainly, cites `MedicalSourceTopic.bodyScanEstimate`, and only
/// writes anything to SwiftData if the person explicitly taps Save — same
/// "review before save" discipline as `LabResultReviewView`.
///
/// Entitlement gating matches `LabResultsView.handleAddTap`: `isPremium` is
/// checked before this view is ever presented (see `TrendsView`'s call
/// site), and the trial AI-call budget is checked again here before opening
/// the camera, since a trialing user's budget can be exhausted between when
/// the button rendered and when it's tapped.
struct BodyScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private enum Step: Equatable {
        case consent
        case estimating(front: UIImage, side: UIImage)
        case result(BodyScanEstimator.BodyScanResult)
        case error(String)

        // Deliberately partial: only handles the one comparison this file
        // actually makes (`step == .consent`, in the navigation title below).
        // `UIImage` and `BodyScanEstimator.BodyScanResult` aren't `Equatable`,
        // so a real case-by-case `==` isn't free here, and every other step
        // transition in this file is driven by direct assignment. Flagged by
        // an earlier bug sweep as a landmine for whoever adds a
        // `.onChange(of: step)` or another `==` later: this does NOT
        // correctly report two `.error("x")` or two `.result(...)` values as
        // equal. Extend it properly before relying on `==` for anything
        // beyond the `.consent` check below.
        static func == (lhs: Step, rhs: Step) -> Bool {
            switch (lhs, rhs) {
            case (.consent, .consent): return true
            default: return false
            }
        }
    }

    @State private var step: Step = .consent
    @State private var entitlements = EntitlementManager.shared
    @State private var showingTrialLimitAlert = false
    @State private var didSave = false

    // Real bug, reported directly: right after taking the front photo, the
    // whole scanner sheet closed and dropped back to Trends instead of
    // advancing to the side-photo capture. Root cause: `CameraCaptureView`
    // was previously inlined directly as one branch of a `switch step`
    // inside this view's own `NavigationStack` — not presented via its own
    // `.sheet`/`.fullScreenCover` the way every other call site in this app
    // (`LabResultsView`, `ProgressPhotosView`, `LogProteinView`,
    // `DashboardView`) presents it. `CameraCaptureView` calls its own
    // `@Environment(\.dismiss)` internally right after a photo is captured
    // (see that file's `.onChange(of: controller.capturedImage)`), which
    // resolves to the *nearest actual presentation boundary* — with no
    // fullScreenCover/sheet of its own inside `BodyScanView`, that boundary
    // was this whole view's presentation from `TrendsView`'s
    // `.sheet(isPresented: $showingBodyScan)`, so capturing the front photo
    // closed the entire flow rather than just that camera step.
    //
    // Fixed by giving each capture its own real `.fullScreenCover`, so
    // `CameraCaptureView`'s internal `dismiss()` closes only that cover, the
    // same as it does at every other call site. The two covers are chained
    // via `onDismiss` rather than the capture callback directly setting the
    // next cover's flag: setting a new `Bool` to `true` in the same
    // synchronous callback that also triggers `CameraCaptureView`'s own
    // `dismiss()` races against that dismissal (dismiss() would win,
    // silently closing the cover we just tried to open) — sequencing through
    // `onDismiss`, which SwiftUI guarantees runs after the cover has
    // actually finished closing, avoids that race entirely.
    @State private var showingFrontCapture = false
    @State private var showingSideCapture = false
    @State private var frontImage: UIImage?
    @State private var sideImage: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .consent:
                    consentView
                case .estimating(let front, let side):
                    loadingView
                        .task { await runEstimate(front: front, side: side) }
                case .result(let result):
                    resultView(result)
                case .error(let message):
                    errorView(message)
                }
            }
            .navigationTitle(step == .consent ? "Body-fat photo estimate" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showingFrontCapture, onDismiss: {
            // Only chain into the side capture if a photo was actually taken
            // — `CameraCaptureView`'s own close button also triggers this
            // same `onDismiss` on a cancel, and that must land back on the
            // consent screen, not silently pop the side camera open.
            if frontImage != nil {
                showingSideCapture = true
            }
        }) {
            CameraCaptureView(
                instructionText: "Front photo — face the camera",
                permissionDeniedMessage: "Sustain uses your camera to estimate body fat from two photos. Enable camera access in Settings to use this."
            ) { image in
                frontImage = image
            }
        }
        .fullScreenCover(isPresented: $showingSideCapture, onDismiss: {
            guard let frontImage, let sideImage else { return }
            step = .estimating(front: frontImage, side: sideImage)
            // Cleared immediately once handed off to `.estimating` — this
            // view never needs to hold either image any longer than it
            // takes to start the actual estimate call, matching the "no
            // photo is ever stored" promise on the consent screen as
            // literally as possible even for in-memory state.
            self.frontImage = nil
            self.sideImage = nil
        }) {
            CameraCaptureView(
                instructionText: "Side photo — turn 90 degrees",
                permissionDeniedMessage: "Sustain uses your camera to estimate body fat from two photos. Enable camera access in Settings to use this."
            ) { image in
                sideImage = image
            }
        }
        .alert("Trial AI limit reached", isPresented: $showingTrialLimitAlert) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("You've used all \(EntitlementManager.trialAICallLimit) AI calls included in your trial. Subscribe to keep using AI features.")
        }
    }

    private var consentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "figure.stand")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.primary)

                Text("Two quick photos, a rough estimate")
                    .font(.title3.weight(.semibold))

                Text("Sustain can estimate your body fat percentage from a front photo and a side photo, as a free, no-hardware alternative to a smart scale.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    label("For an honest estimate:", systemImage: "camera")
                    bullet("Wear form-fitting athletic clothing (leggings and a fitted top, or similar) — not loose clothing, and not minimal clothing.")
                    bullet("Stand somewhere well-lit, with your full body visible in frame.")
                    bullet("Someone else holding the camera works best, or use a tripod.")
                }

                VStack(alignment: .leading, spacing: 10) {
                    label("Your privacy:", systemImage: "lock")
                    bullet("Neither photo is ever saved, by Sustain or anywhere else. Both are discarded immediately after the estimate comes back.")
                    bullet("This feature is for adults. Don't use it to photograph a minor.")
                }

                Text("This is a rough estimate from a general-purpose AI, not a medical-grade or diagnostic measurement — see \"How Sustain handles this\" after your estimate for the real accuracy caveat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    guard entitlements.canUseAIFeature else {
                        showingTrialLimitAlert = true
                        AnalyticsManager.track(.aiScanBlockedTrialLimit(feature: .bodyScanEstimate))
                        return
                    }
                    showingFrontCapture = true
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .padding(.top, 8)
            }
            .padding()
        }
    }

    private func label(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Estimating from your photos...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultView(_ result: BodyScanEstimator.BodyScanResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Estimated body fat")
                    .font(.headline)

                Text("\(result.lowPercent, specifier: "%.0f")–\(result.highPercent, specifier: "%.0f")%")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primary)

                Text("Shown as a range, not a single number, because that's a more honest reflection of what a photo-based estimate can actually support. Self-reported confidence: \(result.confidence).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                MedicalSourcesLink(topic: .bodyScanEstimate, label: "How Sustain handles this")
                    .padding(.vertical, 4)

                if didSave {
                    Label("Saved to your trends", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.semibold))
                } else {
                    Button {
                        save(result)
                    } label: {
                        Text("Save to trends")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)
                }

                Button("Done") { dismiss() }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button("Try again") { step = .consent }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
            Button("Cancel") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func runEstimate(front: UIImage, side: UIImage) async {
        do {
            let result = try await BodyScanEstimator.estimate(front: front, side: side)
            entitlements.recordAIUsage()
            AIFeatureEngagementTracker.recordUse(.bodyScanEstimate)
            AnalyticsManager.track(.aiScanCompleted(feature: .bodyScanEstimate))
            step = .result(result)
        } catch {
            step = .error(error.localizedDescription)
        }
    }

    private func save(_ result: BodyScanEstimator.BodyScanResult) {
        // Stored as the range's midpoint — `BodyCompositionEntry.bodyFatPercent`
        // is a single `Double`, the same schema the HealthKit-sourced lite
        // version already writes into, and adding a second range-shaped
        // column just for this one source would complicate every reader of
        // that model for a distinction that isn't visible on the chart
        // anyway (`BodyCompositionChartView` plots one point per date
        // regardless of source). The range itself is still shown in full,
        // once, on this review screen, before the person ever chooses to
        // save.
        let entry = BodyCompositionEntry(bodyFatPercent: result.midpoint, source: .photoEstimate)
        modelContext.insert(entry)
        try? modelContext.save()
        didSave = true
    }
}

#Preview {
    BodyScanView()
        .modelContainer(for: [BodyCompositionEntry.self], inMemory: true)
}
