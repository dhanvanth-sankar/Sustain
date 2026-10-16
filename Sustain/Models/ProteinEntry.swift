import Foundation
import SwiftData

@Model
final class ProteinEntry {
    var id: UUID
    var date: Date
    var grams: Double
    var note: String
    var sourceRaw: String

    init(date: Date = .now, grams: Double, note: String = "", source: EntrySource = .manual) {
        self.id = UUID()
        self.date = date
        self.grams = grams
        self.note = note
        self.sourceRaw = source.rawValue
    }

    var source: EntrySource {
        get { EntrySource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}
