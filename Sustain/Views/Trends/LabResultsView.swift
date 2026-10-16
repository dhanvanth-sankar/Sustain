import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §6 — see
/// `LabResultEntry`'s and `LabResultExtractor`'s header comments for the
/// full rationale and the transcription-only, never-interpretation design
/// constraint held throughout this feature.
///
/// Same local-only scope cut as `ProgressPhotosView`: lab values are not
/// synced to Supabase in this first pass. Unlike photos, this is small
/// structured data that *could* piggyback on the existing DTO sync pattern
/// relatively easily — but bloodwork is a more sensitive category of health
/// data than anything else already synced, and extending the existing
/// cross-device sync surface to it deserves its own explicit decision
/// rather than inheriting one made for dose logs and weight entries.
struct LabResultsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LabResultEntry.date, order: .reverse) private var allResults: [LabResultEntry]

    @State private var entitlements = EntitlementManager.shared
    @State private var showingPaywall = false
    @State private var showingSourceDialog = false
    @State private var showingFileImporter = false
    @State private var pickerSource: ImagePickerSource?
    @State private var isExtracting = false
    @State private var extractedBiomarkers: [ExtractedBiomarker] = []
    // Added 2026-08-03: previously the review screen's test-date field
    // always defaulted to today, requiring a manual change to match the
    // actual report every time — raised during manual testing. Nil means
    // the extractor couldn't find a legible printed date; `LabResultReviewView`
    // falls back to today in that case, same as before this existed.
    @State private var extractedReportDate: Date?
    @State private var showingReview = false
    @State private var extractionErrorMessage: String?
    @State private var showingExtractionError = false
    @State private var showingTrialLimitAlert = false
    // Added 2026-08-03, requested during manual testing: photographing the
    // same report twice (or the same report photo twice) was silently
    // producing duplicate rows for every biomarker. Shown after a save that
    // actually skipped something, so a duplicate scan isn't a silent no-op —
    // if someone expected N new rows and got fewer, they should know why.
    @State private var duplicatesSkippedCount = 0

    /// Grouped by test date (rounded to the day) so one photo's worth of
    /// biomarkers reads as one panel, not a flat undifferentiated list.
    private var resultsByDate: [(date: Date, entries: [LabResultEntry])] {
        let grouped = Dictionary(grouping: allResults) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { (date: $0, entries: grouped[$0] ?? []) }
    }

    private var trendableBiomarkerNames: [String] {
        Dictionary(grouping: allResults, by: \.biomarkerName)
            .filter { $0.value.count >= 2 }
            .keys
            .sorted()
    }

    var body: some View {
        Group {
            if !entitlements.isPremium {
                upsellCard
            } else if allResults.isEmpty {
                emptyState
            } else {
                List {
                    // Only biomarkers with at least two readings — a "trend"
                    // link that opens onto "add another report to see a trend"
                    // is a dead end, not a feature. (The prior `count >= 1`
                    // check was also always true in this branch.)
                    if !trendableBiomarkerNames.isEmpty {
                        Section("Trends") {
                            ForEach(trendableBiomarkerNames, id: \.self) { name in
                                NavigationLink(name) {
                                    LabResultTrendView(biomarkerName: name)
                                }
                            }
                        }
                    }

                    // Restructured 2026-08-03, requested during manual
                    // testing: showing every biomarker from every report
                    // inline made this list grow unbounded and hard to
                    // scroll through past even a handful of reports. Now one
                    // row per report date (a submenu, in the requester's own
                    // words) pushing to `LabResultDateDetailView` for that
                    // date's actual values — the "Trends" section above is
                    // untouched and still pushes to a full-screen chart
                    // exactly as before.
                    Section("Reports") {
                        ForEach(resultsByDate, id: \.date) { group in
                            NavigationLink {
                                LabResultDateDetailView(
                                    dayStart: group.date,
                                    dayEnd: Calendar.current.date(byAdding: .day, value: 1, to: group.date) ?? group.date,
                                    displayDate: group.date
                                )
                            } label: {
                                HStack {
                                    Text(group.date.formatted(date: .abbreviated, time: .omitted))
                                    Spacer()
                                    Text("\(group.entries.count) value\(group.entries.count == 1 ? "" : "s")")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        // Swiping a date row here deletes the whole report
                        // (every value logged that day) in one motion —
                        // deleting individual values within a report happens
                        // one level in, on `LabResultDateDetailView`.
                        .onDelete { offsets in
                            for index in offsets {
                                for entry in resultsByDate[index].entries {
                                    modelContext.delete(entry)
                                }
                            }
                            try? modelContext.save()
                        }
                    }
                }
            }
        }
        .navigationTitle("Lab results")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            // Guideline 1.4.1's pairing requirement: the explanation of what
            // this feature does and does not do with health values has to be
            // reachable from the feature itself, not only from Settings.
            // `.labResults` cites no studies deliberately (Sustain derives no
            // number from a lab value) — see its entry in MedicalSource.swift.
            if entitlements.isPremium {
                MedicalSourcesLink(topic: .labResults, label: "How Sustain handles these values")
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .toolbar {
            if entitlements.isPremium {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        handleAddTap()
                    } label: {
                        if isExtracting {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .disabled(isExtracting)
                }
            }
        }
        .confirmationDialog("Add a lab report photo", isPresented: $showingSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { pickerSource = ImagePickerSource(sourceType: .camera) }
            }
            Button("Choose from Library") { pickerSource = ImagePickerSource(sourceType: .photoLibrary) }
            // Added 2026-08-03, requested during manual testing: a lab
            // report is one of the more likely things someone already has
            // as a saved file (a scanned PDF page exported as an image, or
            // a photo saved into iCloud Drive/Files from another app) rather
            // than sitting in the Photos library specifically. Reuses
            // SwiftUI's own `.fileImporter`, so no new UIKit wrapper is
            // needed the way `ImagePicker`/`CameraCaptureView` required.
            Button("Choose from Files") { showingFileImporter = true }
            Button("Cancel", role: .cancel) {}
        }
        .presentationCompactAdaptation(.sheet)
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                // Files can hand back a security-scoped URL (iCloud Drive,
                // another app's document provider) — accessing it without
                // this guard would silently fail to read the file's bytes.
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                    extractionErrorMessage = "That file couldn't be read as an image."
                    showingExtractionError = true
                    return
                }
                Task { await extract(from: image) }
            case .failure:
                break
            }
        }
        .fullScreenCover(item: $pickerSource) { source in
            if source.sourceType == .camera {
                // No `.ignoresSafeArea()` here, matching `DashboardView` and
                // `LogProteinView`'s existing call sites — `CameraCaptureView`
                // extends its own background full-bleed internally so its
                // close button can stay inset from the status bar. See that
                // file's header comment.
                // Caught during manual testing (2026-08-03, section 6.7):
                // same fix as `ProgressPhotosView` — the shared default copy
                // ("Point at your plate") is food-estimate wording and reads
                // as wrong when photographing a lab report.
                CameraCaptureView(
                    instructionText: "Point at your lab report",
                    permissionDeniedMessage: "Sustain uses your camera to read values off a lab report photo. Enable camera access in Settings to use this."
                ) { image in
                    Task { await extract(from: image) }
                }
            } else {
                ImagePicker(sourceType: source.sourceType) { image, _ in
                    Task { await extract(from: image) }
                }
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showingReview) {
            LabResultReviewView(biomarkers: extractedBiomarkers, initialTestDate: extractedReportDate) { testDate, confirmed in
                saveConfirmedBiomarkers(confirmed, testDate: testDate)
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(trigger: .aiLabResults)
        }
        // Same "stuck in light mode" fix as `ChatCoachView` — see that
        // file's comment for the full explanation.
        .preferredColorScheme(nil)
        .alert("Couldn't read that report", isPresented: $showingExtractionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(extractionErrorMessage ?? "")
        }
        .alert("Trial AI limit reached", isPresented: $showingTrialLimitAlert) {
            Button("Upgrade") { showingPaywall = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You've used all \(EntitlementManager.trialAICallLimit) AI calls included in your trial. Subscribe to keep using AI features.")
        }
        .alert("Skipped duplicate values", isPresented: Binding(
            get: { duplicatesSkippedCount > 0 },
            set: { if !$0 { duplicatesSkippedCount = 0 } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(duplicatesSkippedCount) value\(duplicatesSkippedCount == 1 ? "" : "s") already saved for this date \(duplicatesSkippedCount == 1 ? "wasn't" : "weren't") added again.")
        }
    }

    /// Added 2026-08-03, requested during manual testing: uploading the same
    /// report photo twice (or re-photographing the same physical report) was
    /// silently producing duplicate rows for every biomarker, since nothing
    /// checked whether an identical value already existed before inserting.
    /// A duplicate is defined as the same biomarker name (case-insensitive),
    /// the same numeric value, the same unit (case-insensitive), on the same
    /// calendar day — deliberately scoped to "same day," not "ever," since a
    /// legitimately repeated test weeks later with an unchanged value (e.g. a
    /// stable TSH) is real data, not a duplicate.
    private func saveConfirmedBiomarkers(_ confirmed: [ExtractedBiomarker], testDate: Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: testDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? testDate
        let existingSameDay = allResults.filter { $0.date >= dayStart && $0.date < dayEnd }

        var skipped = 0
        for biomarker in confirmed {
            let isDuplicate = existingSameDay.contains { existing in
                existing.biomarkerName.caseInsensitiveCompare(biomarker.name) == .orderedSame
                    && abs(existing.value - biomarker.value) < 0.0001
                    && existing.unit.caseInsensitiveCompare(biomarker.unit) == .orderedSame
            }
            guard !isDuplicate else {
                skipped += 1
                continue
            }
            modelContext.insert(LabResultEntry(date: testDate, biomarkerName: biomarker.name, value: biomarker.value, unit: biomarker.unit))
        }
        try? modelContext.save()
        duplicatesSkippedCount = skipped
    }

    /// Both entry points into the import flow (the toolbar `+` and the empty
    /// state's "Add a lab report" button) route through here. Caught in
    /// pre-test audit: the guard originally lived inline on the toolbar
    /// button only, so the empty-state button bypassed the trial AI budget
    /// entirely — and the empty state is exactly what a brand-new trialing
    /// user sees first, making it the *more* likely path, not an edge case.
    private func handleAddTap() {
        guard entitlements.canUseAIFeature else {
            showingTrialLimitAlert = true
            AnalyticsManager.track(.aiScanBlockedTrialLimit(feature: .labResultImport))
            return
        }
        showingSourceDialog = true
    }

    private func extract(from image: UIImage) async {
        isExtracting = true
        defer { isExtracting = false }
        do {
            let result = try await LabResultExtractor.extract(from: image)
            entitlements.recordAIUsage()
            AIFeatureEngagementTracker.recordUse(.labResultImport)
            AnalyticsManager.track(.aiScanCompleted(feature: .labResultImport))
            extractedBiomarkers = result.biomarkers
            extractedReportDate = result.reportDate
            showingReview = true
        } catch {
            extractionErrorMessage = error.localizedDescription
            showingExtractionError = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cross.case.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No lab results yet")
                .font(.headline)
            Text("Take a photo of a lab report and Sustain will read off the values for you to confirm and save.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Add a lab report") { handleAddTap() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .padding(.top, 4)
            Text(MedicalSources.disclaimer)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var upsellCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "cross.case.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.primary)
            Text("Lab results are a Sustain+ feature")
                .font(.headline)
            Text("Photograph a lab report and Sustain reads off the values, so you can see them trend over time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Upgrade to Sustain+") { showingPaywall = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    NavigationStack {
        LabResultsView()
            .modelContainer(for: [LabResultEntry.self], inMemory: true)
    }
}
