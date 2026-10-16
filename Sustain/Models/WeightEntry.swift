import Foundation
import SwiftData

@Model
final class WeightEntry {
    var id: UUID
    var date: Date
    var weightLbs: Double
    var sourceRaw: String

    init(date: Date = .now, weightLbs: Double, source: EntrySource = .manual) {
        self.id = UUID()
        self.date = date
        self.weightLbs = weightLbs
        self.sourceRaw = source.rawValue
    }

    var source: EntrySource {
        get { EntrySource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}
