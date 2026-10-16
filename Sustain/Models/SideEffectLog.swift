import Foundation
import SwiftData

@Model
final class SideEffectLog {
    var id: UUID
    var date: Date
    var symptomRaw: String
    var severity: Int
    var notes: String

    init(date: Date = .now, symptom: SideEffectSymptom, severity: Int, notes: String = "") {
        self.id = UUID()
        self.date = date
        self.symptomRaw = symptom.rawValue
        self.severity = severity
        self.notes = notes
    }

    var symptom: SideEffectSymptom {
        get { SideEffectSymptom(rawValue: symptomRaw) ?? .other }
        set { symptomRaw = newValue.rawValue }
    }
}
