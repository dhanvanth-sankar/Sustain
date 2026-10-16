import ImageIO
import Photos
import SwiftUI
import UIKit

/// Local Identifiable wrapper so `.fullScreenCover(item:)` can drive picker
/// presentation — deliberately not extending UIImagePickerController.SourceType
/// itself with Identifiable, since retroactively conforming a type you don't own
/// risks silently conflicting if Apple adds that conformance later.
struct ImagePickerSource: Identifiable {
    let sourceType: UIImagePickerController.SourceType
    var id: Int { sourceType.rawValue }
}

/// Thin wrapper around UIImagePickerController — SwiftUI's PhotosPicker can't
/// present the camera, so this covers both camera and library with one implementation.
struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    /// Real bug, reported directly: a progress photo picked from the library
    /// always showed today's date, even for a photo taken weeks earlier.
    /// Root cause was in `ProgressPhotosView.save(_:)`, not here — it always
    /// constructed `ProgressPhotoEntry()` with its default `date: .now`,
    /// never reading the picked photo's actual date.
    ///
    /// **First fix attempt (2026-08-09, same day) didn't actually work**:
    /// read `(info[.phAsset] as? PHAsset)?.creationDate`, which is nil in
    /// practice for this app specifically. `info[.phAsset]` is only
    /// populated once the app has explicit `PHPhotoLibrary` authorization —
    /// and per Apple's own documented behavior, it's `nil` even when
    /// authorized if that authorization is "Limited" (a common state), which
    /// this app has never requested at all anywhere in the codebase (grep
    /// for `PHPhotoLibrary`/`requestAuthorization` turns up nothing). So the
    /// first fix silently no-op'd every single time, always falling through
    /// to the `nil` branch and reproducing the exact original bug.
    ///
    /// **Real fix**: read the photo's EXIF/TIFF creation date directly from
    /// `info[.imageURL]` (the temp file URL `UIImagePickerController`
    /// already hands back for a library pick) via `ImageIO`, which needs
    /// zero Photos-library authorization of any kind — it's reading tag
    /// data out of a file this app was already given a URL to, the same
    /// access level as reading any other file. Falls back to
    /// `info[.phAsset]?.creationDate` first in case a future change ever
    /// does request Photos authorization (harmless to try), then to the
    /// EXIF read, then to `nil` (camera captures, or a library photo with
    /// neither available) — `ProgressPhotosView` treats `nil` as "no real
    /// date available," not an error.
    ///
    /// Added as a second closure parameter rather than a breaking change to
    /// `onImagePicked`'s existing single-image callers: every call site
    /// other than `ProgressPhotosView` (`DashboardView`, `LabResultsView`,
    /// `LogProteinView`) intentionally wants "now" — a food or lab photo's
    /// log date is when it was logged, not when the underlying photo
    /// happened to be taken — so those three ignore this parameter with
    /// `{ image, _ in ... }`.
    let onImagePicked: (UIImage, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                let assetDate = (info[.phAsset] as? PHAsset)?.creationDate
                    ?? (info[.imageURL] as? URL).flatMap(Self.exifCreationDate(at:))
                parent.onImagePicked(image, assetDate)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        /// Reads the picked photo's own EXIF `DateTimeOriginal` (falling
        /// back to the TIFF `DateTime` tag some photos use instead) straight
        /// out of the file at `url` — see `ImagePicker.onImagePicked`'s doc
        /// comment for why this, not `PHAsset`, is the real fix. Returns
        /// `nil` for a photo with neither tag (e.g. a screenshot, or an
        /// image that's had its metadata stripped), which
        /// `ProgressPhotosView` already treats as "fall back to today," the
        /// same as it always did before this fix existed.
        private static func exifCreationDate(at url: URL) -> Date? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                return nil
            }
            let exifDate = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String
            let tiffDate = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFDateTime] as? String
            guard let raw = exifDate ?? tiffDate else { return nil }
            return exifDateFormatter.date(from: raw)
        }

        // EXIF/TIFF date tags are always this exact "yyyy:MM:dd HH:mm:ss"
        // format (colons, not dashes, in the date portion) per the TIFF/EXIF
        // spec — this is parsing that fixed format back, not attempting to
        // handle arbitrary date strings.
        private static let exifDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }()
    }
}
