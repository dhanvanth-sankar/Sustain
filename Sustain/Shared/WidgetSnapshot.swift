import Foundation

/// The App Group both the main app and `SustainWidgetExtension` are entitled
/// for (see `project.yml`). Note that adding the entitlement here alone is not
/// sufficient — the "App Groups" capability also has to be enabled for both
/// App IDs in the Apple Developer portal, the same manual step already flagged
/// for Sign In with Apple in `project.yml`'s own comments. Until that portal
/// step is done, `defaults` below will simply be `nil` at runtime and every
/// read/write becomes a harmless no-op rather than a crash.
enum SharedAppGroup {
    static let identifier = "group.com.sustainapp.glp1"
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}

/// A small, denormalized snapshot of "what the widget and Live Activity need
/// to show right now," written by the main app and read by the widget
/// extension process.
///
/// Deliberately NOT shared live SwiftData access: `SustainApp.swift`'s
/// `ModelContainer` uses the default (non-App-Group) on-disk store location,
/// and pointing it at a shared container after the fact would risk an
/// unreadable store for people who already have the app installed — the same
/// class of migration risk already flagged in `MedicationProfile.swift`'s
/// comments on its own past schema additions. A denormalized snapshot avoids
/// that risk entirely: the widget extension never opens the real store.
struct WidgetSnapshot: Codable {
    var nextDoseDate: Date
    var medicationName: String
    var doseMg: Double
    var proteinConsumedGrams: Double
    var proteinGoalGrams: Double
    var isPremium: Bool
    var updatedAt: Date

    private static let key = "widgetSnapshot"

    static func write(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        SharedAppGroup.defaults?.set(data, forKey: key)
    }

    static func read() -> WidgetSnapshot? {
        guard let data = SharedAppGroup.defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
