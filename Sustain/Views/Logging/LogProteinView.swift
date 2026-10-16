import SwiftData
import SwiftUI
import UIKit

struct LogProteinView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date = .now
    @State private var grams: Double
    @State private var note: String
    @State private var syncToHealth = true

    @State private var entitlements = EntitlementManager.shared
    @State private var showingPaywall = false
    @State private var showingSourceDialog = false
    @State private var pickerSource: ImagePickerSource?
    @State private var isEstimating = false
    @State private var showingEstimateError = false
    @State private var estimateErrorMessage = ""
    @State private var showingTrialLimitAlert = false

    /// One entry per photo estimated this session — replaces the old single
    /// `lastEstimateConfidence: String?`, which could only ever represent the
    /// most recent photo and (via the `note.isEmpty` guard below) silently
    /// dropped every photo after the first one's contribution to both grams and
    /// notes. Each entry is independently removable, the same pattern already
    /// used for quick-add chips.
    @State private var photoEstimates: [PhotoEstimateEntry] = []

    private struct PhotoEstimateEntry: Identifiable {
        let id = UUID()
        let foodDescription: String
        let grams: Double
        let confidence: String
    }

    /// Per-sheet log of quick-add taps, shown as removable chips right under the
    /// buttons. Before this, the only feedback a tap produced was the grams field
    /// ticking up somewhere else on screen — easy to miss, and impossible to tell
    /// "did that tap register?" from the button itself. This gives an explicit,
    /// undoable record of what's been added, plus the tapped button now flashes so
    /// the press itself has visible feedback.
    @State private var recentlyAddedItems: [QuickAddEntry] = []
    @State private var flashingLabel: String?

    private struct QuickAddEntry: Identifiable {
        let id = UUID()
        let label: String
        let grams: Double
    }

    /// `initialConfidence` lets a caller (the Dashboard's own AI-estimate card) hand off
    /// an estimate that was already run, so this screen opens as a review-before-save
    /// step rather than re-running the photo flow from scratch. Seeded as the first
    /// `photoEstimates` entry (rather than tracked separately) so a second photo taken
    /// from within this screen adds to it correctly instead of clobbering it.
    ///
    /// `autoOpenCameraOnAppear` added 2026-09 for the trial-compression change in
    /// `Sustain-Subscription-Conversion-Research-2026-09.md` Part 8, item 3: 55% of
    /// trial cancellations industry-wide happen on Day 0, so proving the AI photo
    /// estimate's value in the very first trial session — immediately after starting
    /// a trial, not whenever the person happens to discover the camera button — is the
    /// single highest-confidence, lowest-effort change that research identified. Only
    /// `PaywallView`'s post-trial-start prompt passes `true`; every other call site
    /// keeps the default, unchanged behavior of opening as a plain manual-entry form.
    init(initialGrams: Double = 0, initialNote: String = "", initialConfidence: String? = nil, autoOpenCameraOnAppear: Bool = false) {
        _grams = State(initialValue: initialGrams)
        _note = State(initialValue: initialNote)
        _autoOpenCameraOnAppear = State(initialValue: autoOpenCameraOnAppear)
        if let initialConfidence {
            _photoEstimates = State(initialValue: [
                PhotoEstimateEntry(foodDescription: initialNote, grams: initialGrams, confidence: initialConfidence)
            ])
        }
    }

    @State private var autoOpenCameraOnAppear: Bool

    private let quickAdds: [(label: String, grams: Double)] = [
        ("Protein shake", 25),
        ("Chicken breast", 35),
        ("Eggs (2)", 12),
        ("Greek yogurt", 17),
    ]

    // Manual entry still requires grams > 0 so an untouched sheet can't be saved by
    // accident — but a completed AI estimate is itself a deliberate action, and the
    // photo genuinely can be ~0g (a drink, a condiment). Blocking Save in that case
    // punishes the AI for being right, which is exactly what the recording caught:
    // a water-bottle photo correctly estimated at 0g left the user unable to save.
    private var canSave: Bool { grams > 0 || !photoEstimates.isEmpty }

    /// The single most cautious confidence across every photo this session — a
    /// two-photo log where one estimate is "low" confidence shouldn't read as an
    /// overall "high" confidence just because the other photo was clear-cut.
    private var aggregateConfidence: String? {
        guard !photoEstimates.isEmpty else { return nil }
        if photoEstimates.contains(where: { $0.confidence == "low" }) { return "low" }
        if photoEstimates.contains(where: { $0.confidence == "medium" }) { return "medium" }
        return "high"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        handlePhotoEstimateTap()
                    } label: {
                        // Label changes once at least one photo's been estimated, so it
                        // reads as "add another" rather than implying only one photo is
                        // supported per log — a plate with a main and a side, or a meal
                        // split across two containers, often needs more than one shot.
                        Label(
                            isEstimating ? "Estimating…" : (photoEstimates.isEmpty ? "Estimate with photo" : "Add another photo"),
                            systemImage: "camera.fill"
                        )
                    }
                    .disabled(isEstimating)

                    if !photoEstimates.isEmpty {
                        ForEach(photoEstimates) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.foodDescription)
                                        .font(.subheadline)
                                    Text("\(Int(entry.grams.rounded()))g protein · \(entry.confidence) confidence")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    removePhotoEstimate(entry)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .transition(.opacity)
                        }
                    }
                } footer: {
                    if let aggregateConfidence {
                        // Explicit "AI-generated" framing, not just "estimate" — Apple
                        // expects a clear disclosure whenever AI-generated content is
                        // shown, distinct from the separate "not a diagnosis" medical
                        // disclaimer used elsewhere in the app.
                        let photoWord = photoEstimates.count == 1 ? "photo" : "photos"
                        Text("AI-generated estimate from \(photoEstimates.count) \(photoWord), confidence: \(aggregateConfidence). Adjust below if it looks off.")
                    } else {
                        Text("Sustain+ feature. Snap a photo of your food for an AI-generated protein estimate. You can add more than one photo per log.")
                    }
                }

                Section("When") {
                    DatePicker("Date & time", selection: $date, in: ...Date.now)
                }

                Section("Amount") {
                    HStack {
                        Text("Protein")
                        Spacer()
                        TextField("0", value: $grams, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("g")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Quick add") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quickAdds, id: \.label) { item in
                                let isFlashing = flashingLabel == item.label
                                Button {
                                    addQuickAdd(item)
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(item.label).font(.caption.weight(.medium))
                                        Text("+\(Int(item.grams))g").font(.caption2)
                                            .foregroundStyle(isFlashing ? .white.opacity(0.85) : .secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(isFlashing ? Theme.primary : Theme.primaryLight)
                                    .foregroundStyle(isFlashing ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .scaleEffect(isFlashing ? 1.08 : 1.0)
                                }
                                .buttonStyle(.plain)
                                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: isFlashing)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .padding(.horizontal)
                    .padding(.vertical, 4)

                    if !recentlyAddedItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Added just now")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(recentlyAddedItems) { entry in
                                        HStack(spacing: 4) {
                                            Text("\(entry.label) +\(Int(entry.grams))g")
                                                .font(.caption2.weight(.medium))
                                            Button {
                                                removeQuickAdd(entry)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.caption2)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Theme.primary.opacity(0.12))
                                        .foregroundStyle(Theme.primary)
                                        .clipShape(Capsule())
                                        .transition(.scale.combined(with: .opacity))
                                    }
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                    }
                }

                Section("Notes") {
                    HStack(alignment: .top) {
                        TextField("What did you eat?", text: $note, axis: .vertical)
                            .lineLimit(2...4)
                        // comp-027: hands-free logging, useful right after a
                        // meal when typing is less convenient than saying it.
                        VoiceInputButton(text: $note)
                    }
                }

                Section {
                    Toggle("Sync to Apple Health", isOn: $syncToHealth)
                }
            }
            .navigationTitle("Log protein")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .keyboardDoneButton()
            .task {
                // Fires once, only when the caller explicitly asked for it — see the
                // `autoOpenCameraOnAppear` doc comment on `init` above. Deliberately a
                // one-shot `.task`, not `.onAppear`, so this can't re-fire if the view
                // re-renders for an unrelated reason while already presented.
                if autoOpenCameraOnAppear {
                    autoOpenCameraOnAppear = false
                    showingSourceDialog = true
                }
            }
            .confirmationDialog("Estimate protein from a photo", isPresented: $showingSourceDialog, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") { pickerSource = ImagePickerSource(sourceType: .camera) }
                }
                Button("Choose from Library") { pickerSource = ImagePickerSource(sourceType: .photoLibrary) }
                Button("Cancel", role: .cancel) {}
            }
            // Same fix as the identical dialog in `DashboardView.swift` and
            // the precedent in `SettingsView.swift` — without this, this
            // exact dialog can render as a small floating popover instead of
            // a full-width bottom sheet. Fixed preemptively here even though
            // this specific call site wasn't the one caught in the
            // screenshot, since it's the same construct and would show the
            // identical bug.
            .presentationCompactAdaptation(.sheet)
            .fullScreenCover(item: $pickerSource) { source in
                if source.sourceType == .camera {
                    // No `.ignoresSafeArea()` here, deliberately (real bug,
                    // reported directly from a device screenshot: the close
                    // button collided with the status bar/Dynamic Island).
                    // `CameraCaptureView` already extends its own background
                    // and camera preview full-bleed internally (see its body
                    // — the `Color.black`/`CameraPreviewLayerView` layers
                    // each call `.ignoresSafeArea()` themselves), specifically
                    // so its close button can stay safely inset from the
                    // status bar. Applying `.ignoresSafeArea()` again out
                    // here at the presentation site overrides that for the
                    // *entire* view, including the close button, which is
                    // what pushed it up into the status bar.
                    CameraCaptureView { image in
                        Task { await estimate(from: image) }
                    }
                } else {
                    ImagePicker(sourceType: source.sourceType) { image, _ in
                        Task { await estimate(from: image) }
                    }
                    .ignoresSafeArea()
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(trigger: .aiPhotoEstimate)
            }
            // Same "stuck in light mode" fix as `ChatCoachView` — see that
            // file's comment for the full explanation.
            .preferredColorScheme(nil)
            .alert("Couldn't estimate protein", isPresented: $showingEstimateError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(estimateErrorMessage)
            }
            .alert("Trial AI limit reached", isPresented: $showingTrialLimitAlert) {
                Button("Upgrade") { showingPaywall = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You've used all \(EntitlementManager.trialAICallLimit) AI estimates included in your trial. Subscribe to keep using photo estimates and weekly recaps.")
            }
        }
    }

    private func addQuickAdd(_ item: (label: String, grams: Double)) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            grams += item.grams
            recentlyAddedItems.append(QuickAddEntry(label: item.label, grams: item.grams))
        }
        appendToNote(item.label)

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Brief color/scale flash on the tapped button itself — the chip above
        // is the durable record, this is the instant "yes, that registered" cue.
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
            flashingLabel = item.label
        }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.easeOut(duration: 0.25)) {
                if flashingLabel == item.label { flashingLabel = nil }
            }
        }
    }

    private func removeQuickAdd(_ entry: QuickAddEntry) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            grams = max(0, grams - entry.grams)
            recentlyAddedItems.removeAll { $0.id == entry.id }
        }
        removeFromNote(entry.label)
    }

    /// Only the first quick-add tap ever touched `note` — every tap after that was
    /// silently dropped because of the `note.isEmpty` guard, so the field visibly
    /// stopped updating after one item. This appends each new item instead, and
    /// skips it if it's already listed (e.g. tapping the same chip twice shouldn't
    /// duplicate its name).
    private func appendToNote(_ label: String) {
        if note.isEmpty {
            note = label
        } else if !note.components(separatedBy: ", ").contains(label) {
            note += ", \(label)"
        }
    }

    /// Mirrors `appendToNote` on removal — but only strips the label if no other
    /// still-active quick-add chip *or* photo estimate shares it, so removing one
    /// of two identical entries doesn't erase the name entirely.
    private func removeFromNote(_ label: String) {
        let stillActive = recentlyAddedItems.contains { $0.label == label }
            || photoEstimates.contains { $0.foodDescription == label }
        guard !stillActive else { return }
        note = note.components(separatedBy: ", ").filter { $0 != label }.joined(separator: ", ")
    }

    private func removePhotoEstimate(_ entry: PhotoEstimateEntry) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            grams = max(0, grams - entry.grams)
            photoEstimates.removeAll { $0.id == entry.id }
        }
        removeFromNote(entry.foodDescription)
    }

    private func handlePhotoEstimateTap() {
        guard entitlements.isPremium else {
            showingPaywall = true
            return
        }
        // A trialing user can still be `isPremium` but have exhausted the trial's
        // combined AI call cap — see EntitlementManager.canUseAIFeature. A full
        // paying subscriber outside a trial is never blocked here.
        guard entitlements.canUseAIFeature else {
            showingTrialLimitAlert = true
            AnalyticsManager.track(.aiScanBlockedTrialLimit(feature: .proteinPhotoEstimate))
            return
        }
        showingSourceDialog = true
    }

    /// Adds this photo's contribution rather than overwriting — the previous
    /// version set `grams = result.grams` unconditionally and only touched `note`
    /// under an `note.isEmpty` guard, so a second photo silently discarded its own
    /// gram estimate's addition to the running total in the note (grams did update,
    /// just the description didn't) and, worse, any note text already present
    /// (from a prior photo, a quick-add, or manual typing) blocked the new food
    /// description from ever appearing. Both grams and note now accumulate per
    /// photo, matching the quick-add chips' additive pattern.
    private func estimate(from image: UIImage) async {
        isEstimating = true
        defer { isEstimating = false }
        do {
            let result = try await AIProteinEstimator.estimateProtein(from: image)
            entitlements.recordAIUsage()
            AIFeatureEngagementTracker.recordUse(.proteinPhotoEstimate)
            AnalyticsManager.track(.aiScanCompleted(feature: .proteinPhotoEstimate))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                grams += result.grams
                photoEstimates.append(
                    PhotoEstimateEntry(foodDescription: result.foodDescription, grams: result.grams, confidence: result.confidence)
                )
            }
            appendToNote(result.foodDescription)
        } catch {
            estimateErrorMessage = error.localizedDescription
            showingEstimateError = true
        }
    }

    private func save() {
        let entry = ProteinEntry(
            date: date, grams: grams, note: note,
            source: !photoEstimates.isEmpty ? .photoEstimate : .manual
        )
        modelContext.insert(entry)
        try? modelContext.save()
        CloudSyncManager.shared.syncSoon(context: modelContext)

        if syncToHealth {
            Task {
                await HealthKitManager.shared.saveProtein(grams: grams, date: date)
            }
        }

        dismiss()
    }
}

#Preview {
    LogProteinView()
        .modelContainer(for: [ProteinEntry.self], inMemory: true)
}
