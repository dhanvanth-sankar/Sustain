import Foundation
import SwiftData

@Model
final class DoseLog {
    var id: UUID
    var date: Date
    var doseMg: Double
    var formRaw: String
    var injectionSiteRaw: String?
    var skipped: Bool
    var notes: String

    init(
        date: Date = .now,
        doseMg: Double,
        form: MedicationForm,
        injectionSite: InjectionSite? = nil,
        skipped: Bool = false,
        notes: String = ""
    ) {
        self.id = UUID()
        self.date = date
        self.doseMg = doseMg
        self.formRaw = form.rawValue
        self.injectionSiteRaw = injectionSite?.rawValue
        self.skipped = skipped
        self.notes = notes
    }

    var form: MedicationForm {
        get { MedicationForm(rawValue: formRaw) ?? .injection }
        set { formRaw = newValue.rawValue }
    }

    var injectionSite: InjectionSite? {
        get { injectionSiteRaw.flatMap(InjectionSite.init(rawValue:)) }
        set { injectionSiteRaw = newValue?.rawValue }
    }
}
