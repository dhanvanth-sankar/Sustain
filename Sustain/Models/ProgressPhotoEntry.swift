import Foundation
import SwiftData

/// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §3b: every
/// dedicated progress-photo app reviewed (Snapsie, Evolve, WeightSnap,
/// MacroFactor's photo feature) monetizes around the same mechanic — store
/// two photos from different dates, auto-populate a comparison with stats
/// already on record, let the user save/share it. Sustain had zero photo
/// storage of any kind before this.
///
/// `imageData` uses `@Attribute(.externalStorage)`, same reasoning as any
/// photo-backed SwiftData model: full-resolution JPEGs stored inline in the
/// SQLite row would bloat the database file and slow down every unrelated
/// query against it. External storage keeps the row itself small (SwiftData
/// transparently manages the actual file on disk) while this model's API
/// still reads like a normal in-memory `Data` property.
@Model
final class ProgressPhotoEntry {
    var id: UUID
    var date: Date
    @Attribute(.externalStorage) var imageData: Data
    var notes: String

    init(date: Date = .now, imageData: Data, notes: String = "") {
        self.id = UUID()
        self.date = date
        self.imageData = imageData
        self.notes = notes
    }
}
