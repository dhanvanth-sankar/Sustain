import Foundation

/// A one-way queue of dose logs recorded from the Apple Watch app's single
/// "Log dose" button, waiting to be picked up and turned into a real `DoseLog`
/// by the main iOS app the next time it's foregrounded (see
/// `Services/WatchSyncManager.swift`).
///
/// The Watch app deliberately has no SwiftData access of its own — it's a
/// separate process with its own lifecycle, the same reason
/// `SustainWidgetExtension` only ever reads `WidgetSnapshot` rather than
/// sharing a live `ModelContainer` (see that file's header comment). A small
/// App-Group-backed queue is a simpler and much lower-risk bridge than trying
/// to give the Watch its own synced copy of the real store.
///
/// Only carries a timestamp, not a dose amount — the phone always fills in
/// `profile.currentDoseMg` at drain time, which is the freshest value; nothing
/// requires the Watch to know or display the exact dose amount just to log
/// that a dose was taken.
struct PendingDoseLog: Codable, Identifiable {
    let id: UUID
    let date: Date

    init(date: Date = .now) {
        self.id = UUID()
        self.date = date
    }
}

enum PendingDoseLogQueue {
    private static let key = "pendingDoseLogQueue"

    static func enqueue(_ log: PendingDoseLog) {
        var current = readAll()
        current.append(log)
        write(current)
    }

    static func readAll() -> [PendingDoseLog] {
        guard let data = SharedAppGroup.defaults?.data(forKey: key),
              let logs = try? JSONDecoder().decode([PendingDoseLog].self, from: data) else { return [] }
        return logs
    }

    static func clear() {
        SharedAppGroup.defaults?.removeObject(forKey: key)
    }

    private static func write(_ logs: [PendingDoseLog]) {
        guard let data = try? JSONEncoder().encode(logs) else { return }
        SharedAppGroup.defaults?.set(data, forKey: key)
    }
}
