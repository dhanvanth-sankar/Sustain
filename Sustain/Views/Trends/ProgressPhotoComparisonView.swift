import SwiftUI
import UIKit

/// The actual "before/after" moment `ProgressPhotosView` builds toward — see
/// that file's header comment for the feature's full rationale. `photos` is
/// always exactly 2 elements, pre-sorted ascending by date by the caller
/// (earlier photo first, so "before" always reads as the left/top image).
///
/// Every competitor reviewed that does this (WeightSnap, MacroFactor) leads
/// with "no manual entry required" — the whole point is pulling numbers
/// that are already logged elsewhere in the app rather than asking the user
/// to remember or re-type them. `nearestWeight(to:)` below is what makes
/// that true here: it looks up the closest real `WeightEntry` to each
/// photo's date rather than requiring a weight to be logged on the exact
/// same day a photo was taken, which is unrealistic to expect.
struct ProgressPhotoComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [ProgressPhotoEntry]
    let weightEntries: [WeightEntry]
    let weightUnit: WeightUnit

    @State private var shareImage: UIImage?

    private var before: ProgressPhotoEntry? { photos.first }
    private var after: ProgressPhotoEntry? { photos.count > 1 ? photos[1] : nil }

    private func nearestWeight(to date: Date) -> WeightEntry? {
        weightEntries.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    private var daysBetween: Int? {
        guard let before, let after else { return nil }
        return Calendar.current.dateComponents([.day], from: before.date, to: after.date).day
    }

    private var weightDeltaText: String? {
        guard let before, let after,
              let beforeWeight = nearestWeight(to: before.date),
              let afterWeight = nearestWeight(to: after.date) else { return nil }
        let deltaLbs = afterWeight.weightLbs - beforeWeight.weightLbs
        let deltaDisplay = WeightUnit.pounds.convert(abs(deltaLbs), to: weightUnit)
        let formatted = deltaDisplay.formatted(.number.precision(.fractionLength(0...1)))
        if deltaLbs < -0.05 {
            return "\(formatted) \(weightUnit.abbreviation) lost"
        } else if deltaLbs > 0.05 {
            return "\(formatted) \(weightUnit.abbreviation) gained"
        } else {
            return "About the same weight"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        photoColumn(before, label: "Before")
                        photoColumn(after, label: "After")
                    }
                    .padding(.horizontal)

                    VStack(spacing: 8) {
                        if let daysBetween {
                            statRow(icon: "calendar", text: "\(daysBetween) day\(daysBetween == 1 ? "" : "s") apart")
                        }
                        if let weightDeltaText {
                            statRow(icon: "scalemass", text: weightDeltaText)
                        } else {
                            statRow(icon: "scalemass", text: "Log a weigh-in near each photo to see a weight comparison here")
                        }
                    }
                    .padding()
                    .cardStyle()
                    .padding(.horizontal)

                    // Auto-generates a single shareable image (both photos
                    // plus the stats above) rather than only supporting
                    // "screenshot it yourself" — the same "auto-generated
                    // before/after image, ready to share" mechanic
                    // MacroFactor's own photo feature leads with.
                    //
                    // Rendered once into `@State` from `.task`, NOT computed
                    // inline in `body`. Caught in pre-test audit: the first
                    // version called `renderShareImage()` directly in `body`,
                    // which rasterized a full 3x offscreen image on every
                    // single body evaluation (guaranteed scroll hitching), and
                    // constructing + mutating an `ImageRenderer` during view
                    // update is exactly the "modifying state during view
                    // update" pattern that can cause re-render churn.
                    if let shareImage {
                        ShareLink(
                            item: Image(uiImage: shareImage),
                            preview: SharePreview("My Sustain progress", image: Image(uiImage: shareImage))
                        ) {
                            Label("Share this comparison", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.primary)
                        .padding(.horizontal)
                    }

                    Text("Weight shown is your closest logged weigh-in to each photo's date, not necessarily the same day.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.vertical)
            }
            .navigationTitle("Compare photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                shareImage = renderShareImage()
            }
        }
    }

    private func photoColumn(_ photo: ProgressPhotoEntry?, label: String) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let photo, let uiImage = UIImage(data: photo.imageData) {
                // `.fit`, not `.fill`. Caught in pre-test audit: `.fill` with
                // `.frame(maxWidth: .infinity)` and no height constraint,
                // inside a vertical ScrollView (which proposes unbounded
                // height), produces degenerate or wildly oversized layout and
                // leaves the two columns at mismatched heights.
                //
                // Second real bug, reported live (2026-08-06): this used to
                // pass an explicit `3 / 4` ratio here instead of `nil` — same
                // root cause as `ProgressPhotosView.thumbnail`'s distortion
                // bug, a photo that wasn't already exactly 3:4 rendered
                // visibly stretched/squished. Switching straight to
                // `.scaledToFit()` fixed the distortion but silently
                // reintroduced the *first* bug this comment already
                // describes: two photos with different real aspect ratios,
                // each "fit" within the same column width, land at two
                // different heights again, so "Before" and "After" stop
                // lining up. Both constraints have to hold at once —
                // matching heights *and* no distortion — which is exactly
                // what `GeometryReader` + `scaledToFill` + `.clipped()`
                // gives: `.aspectRatio(3 / 4, contentMode: .fit)` on the
                // `GeometryReader` pins both columns to the identical 3:4
                // box (same fixed shape regardless of either photo's real
                // proportions, so heights always match), and inside that
                // box the `Image` uses its own real aspect ratio to cover
                // it, cropping instead of warping.
                GeometryReader { geo in
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(photo.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Theme.primary)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }

    /// Renders the two photos and the stat lines into one flat image for
    /// `ShareLink` — the same "one saved/shareable image" pattern
    /// MacroFactor's progress-photo feature and GLPzy's before/after montage
    /// both use, rather than expecting someone to screenshot this screen
    /// (which would also capture the nav bar and Share button themselves).
    private func renderShareImage() -> UIImage? {
        guard let before, let after,
              let beforeImage = UIImage(data: before.imageData),
              let afterImage = UIImage(data: after.imageData) else { return nil }

        // Same explicit-ratio distortion bug as `photoColumn` above and
        // `ProgressPhotosView.thumbnail` — `.scaledToFill()` instead of
        // `.aspectRatio(3 / 4, contentMode: .fill)` uses each photo's own
        // real proportions, cropped (not stretched) to the fixed 160x213
        // frame via the `.clipShape` right after.
        let renderer = ImageRenderer(content:
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(uiImage: beforeImage).resizable().scaledToFill().frame(width: 160, height: 213).clipShape(RoundedRectangle(cornerRadius: 10))
                    Image(uiImage: afterImage).resizable().scaledToFill().frame(width: 160, height: 213).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if let weightDeltaText {
                    Text(weightDeltaText).font(.headline)
                }
                if let daysBetween {
                    Text("\(daysBetween) days apart").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(Color.white)
        )
        renderer.scale = 3
        return renderer.uiImage
    }
}

#Preview {
    // Solid-color fixtures rather than an empty array — an empty `photos`
    // renders an essentially blank screen, which makes the preview useless
    // for checking the layout this file exists to get right.
    let fixture: (UIColor) -> Data = { color in
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }.jpegData(compressionQuality: 0.8) ?? Data()
    }
    let calendar = Calendar.current
    return ProgressPhotoComparisonView(
        photos: [
            ProgressPhotoEntry(date: calendar.date(byAdding: .day, value: -60, to: .now) ?? .now, imageData: fixture(.systemTeal)),
            ProgressPhotoEntry(date: .now, imageData: fixture(.systemGreen)),
        ],
        weightEntries: [
            WeightEntry(date: calendar.date(byAdding: .day, value: -60, to: .now) ?? .now, weightLbs: 210),
            WeightEntry(date: .now, weightLbs: 194),
        ],
        weightUnit: .pounds
    )
}
