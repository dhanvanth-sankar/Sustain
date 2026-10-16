import SwiftData
import SwiftUI
import UIKit

/// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §3b — see
/// `ProgressPhotoEntry`'s header comment for the competitive rationale.
///
/// **Deliberately local-only, not synced to Supabase.** Every other model in
/// this app round-trips through `CloudSyncManager`'s DTO/JSON pattern, which
/// is a reasonable fit for small structured rows but not for binary photo
/// data — storing full-resolution body photos in the same Postgres tables
/// as dose logs is a meaningfully bigger infrastructure and privacy decision
/// (blob storage or object storage, a real retention/deletion policy for
/// what is unambiguously the most sensitive class of content this app could
/// ever store) than this pass is set up to make blind. This mirrors the
/// same scope cut `AIChatCoachService` already made for chat history:
/// ship the feature now, in-memory-or-on-device only, and treat "should
/// this sync across devices" as its own deliberate decision later rather
/// than a default. Concretely: photos taken on one device do not appear on
/// another device signed into the same account, and are not included in
/// whatever account-deletion/export flow exists for synced data today.
struct ProgressPhotosView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProgressPhotoEntry.date, order: .reverse) private var photos: [ProgressPhotoEntry]
    @Query(sort: \WeightEntry.date) private var weightEntries: [WeightEntry]

    @AppStorage("weightUnitRaw") private var weightUnitRaw: String = WeightUnit.pounds.rawValue
    @State private var entitlements = EntitlementManager.shared
    @State private var showingPaywall = false
    @State private var showingSourceDialog = false
    @State private var pickerSource: ImagePickerSource?
    @State private var selectedForCompare: [ProgressPhotoEntry] = []
    @State private var showingComparison = false

    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .pounds }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        Group {
            if !entitlements.isPremium {
                upsellCard
            } else if photos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if selectedForCompare.count == 2 {
                            Button {
                                showingComparison = true
                            } label: {
                                Label("Compare selected photos", systemImage: "square.split.2x1")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.primary)
                        } else {
                            Text("Tap two photos to compare them side by side.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(photos) { photo in
                                thumbnail(for: photo)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Progress photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if entitlements.isPremium {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showingSourceDialog = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .confirmationDialog("Add a progress photo", isPresented: $showingSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { pickerSource = ImagePickerSource(sourceType: .camera) }
            }
            Button("Choose from Library") { pickerSource = ImagePickerSource(sourceType: .photoLibrary) }
            Button("Cancel", role: .cancel) {}
        }
        .presentationCompactAdaptation(.sheet)
        .fullScreenCover(item: $pickerSource) { source in
            if source.sourceType == .camera {
                // No `.ignoresSafeArea()` here, matching `DashboardView` and
                // `LogProteinView`'s existing call sites — see
                // `CameraCaptureView`'s header comment for why applying it at
                // the presentation site pushes its close button into the
                // status bar.
                // Caught during manual testing (2026-08-03, section 6.7):
                // this used to show the shared `CameraCaptureView`'s default
                // "Point at your plate" / food-estimate copy, which makes no
                // sense when photographing yourself for a progress photo.
                CameraCaptureView(
                    instructionText: "Frame yourself in the mirror or at a distance",
                    permissionDeniedMessage: "Sustain uses your camera to take progress photos you can compare side by side. Enable camera access in Settings to use this."
                ) { image in
                    save(image)
                }
            } else {
                // Real bug, reported directly: choosing any existing photo
                // from the library always saved with today's date instead
                // of the photo's own date. `ImagePicker` now hands back the
                // picked asset's real `PHAsset.creationDate` as a second
                // parameter — see that file's header comment. This is the
                // one call site of the four that actually wants it.
                ImagePicker(sourceType: source.sourceType) { image, assetDate in
                    save(image, takenAt: assetDate)
                }
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(trigger: .progressPhotos)
        }
        // Same "stuck in light mode" fix as `ChatCoachView` — see that
        // file's comment for the full explanation.
        .preferredColorScheme(nil)
        .sheet(isPresented: $showingComparison) {
            if selectedForCompare.count == 2 {
                ProgressPhotoComparisonView(
                    photos: [selectedForCompare[0], selectedForCompare[1]].sorted { $0.date < $1.date },
                    weightEntries: weightEntries,
                    weightUnit: weightUnit
                )
            }
        }
    }

    private func thumbnail(for photo: ProgressPhotoEntry) -> some View {
        let isSelected = selectedForCompare.contains(where: { $0.id == photo.id })
        return Button {
            toggleSelection(photo)
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let uiImage = UIImage(data: photo.imageData) {
                    // Second pass at this bug. The first fix (`.scaledToFill()`
                    // plus `.frame(maxWidth: .infinity).frame(height: 130)`)
                    // did stop the distortion, but reported live right after:
                    // it broke the grid itself — inconsistent column widths and
                    // a stray sliver of another cell peeking in from the left
                    // edge. Root cause: `LazyVGrid`'s `.adaptive` columns don't
                    // reliably size a cell that reports `maxWidth: .infinity`
                    // for its ideal width — different rows can end up measured
                    // against different assumed widths, which is exactly the
                    // kind of misalignment/overlap that showed up.
                    //
                    // `GeometryReader` sidesteps this entirely: it always
                    // reports a concrete size (never `.infinity`) equal to
                    // whatever the grid cell actually proposes, so the grid's
                    // own column math is never fed an unbounded value. The
                    // `.aspectRatio(3/4, contentMode: .fit)` below sizes the
                    // *cell itself* (every thumbnail gets the identical 3:4
                    // shape, so rows line up cleanly, same as the original
                    // pre-bug layout) — it's applied to the GeometryReader
                    // container, not to the `Image`, so it only ever shapes the
                    // box, never the photo's own pixels. Inside that box,
                    // `scaledToFill()` uses the photo's real aspect ratio to
                    // cover it, and `.clipped()` crops whatever overflows —
                    // preserving both this grid's stable layout and the actual
                    // no-distortion fix.
                    GeometryReader { geo in
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    .aspectRatio(3 / 4, contentMode: .fit)
                }
                Text(photo.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.primary : .clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
    }

    /// Selecting a third photo drops the oldest selection rather than
    /// refusing the tap — a comparison is always exactly two photos, so
    /// "replace the first pick" is the only sensible behavior for a third
    /// tap, not a no-op that leaves someone wondering why nothing happened.
    private func toggleSelection(_ photo: ProgressPhotoEntry) {
        if let index = selectedForCompare.firstIndex(where: { $0.id == photo.id }) {
            selectedForCompare.remove(at: index)
        } else if selectedForCompare.count < 2 {
            selectedForCompare.append(photo)
        } else {
            selectedForCompare.removeFirst()
            selectedForCompare.append(photo)
        }
    }

    /// Downscales before saving — a full-resolution camera photo (often
    /// 3000+ px wide, several MB as JPEG) is far more than this feature ever
    /// displays (a grid thumbnail and a side-by-side comparison, neither
    /// larger than the screen). Capping the long edge at 1600px keeps
    /// `@Attribute(.externalStorage)`'s on-disk footprint reasonable across
    /// what could become dozens of saved photos over months of use.
    /// `takenAt` is the library-picked photo's real `PHAsset.creationDate`
    /// (`ImagePicker`'s new second parameter — see its header comment), or
    /// `nil` for a camera capture, which genuinely has no earlier date to
    /// use: the photo didn't exist before this moment. `nil` also covers the
    /// rare library case where the system has no creation date attached, so
    /// this still falls back to `ProgressPhotoEntry`'s own `.now` default
    /// rather than leaving `date` unset. A future-dated asset (clock
    /// skew on whatever device/service originally wrote the photo, or an
    /// asset whose metadata was edited) is deliberately left as-is rather
    /// than clamped to today — an odd date is still a real, correctable
    /// value the person can see and fix, where silently overriding it would
    /// just reintroduce a version of the same bug this fixes.
    private func save(_ image: UIImage, takenAt assetDate: Date? = nil) {
        let resized = image.resized(maxDimension: 1600)
        guard let data = resized.jpegData(compressionQuality: 0.8) else { return }
        let entry = ProgressPhotoEntry(imageData: data)
        if let assetDate {
            entry.date = assetDate
        }
        modelContext.insert(entry)
        try? modelContext.save()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No progress photos yet")
                .font(.headline)
            Text("Add one every few weeks to see your progress side by side, alongside your weight and dose history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Add a photo") { showingSourceDialog = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var upsellCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.on.rectangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.primary)
            Text("Progress photos are a Sustain+ feature")
                .font(.headline)
            Text("Save photos over time and compare any two side by side, with your weight and dose context filled in automatically.")
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

private extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxDimension else { return self }
        let scale = maxDimension / longEdge
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

#Preview {
    NavigationStack {
        ProgressPhotosView()
            .modelContainer(for: [ProgressPhotoEntry.self, WeightEntry.self], inMemory: true)
    }
}
