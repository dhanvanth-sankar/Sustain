import SwiftUI
import WidgetKit

struct DoseTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct DoseTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoseTimelineEntry {
        DoseTimelineEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (DoseTimelineEntry) -> Void) {
        completion(DoseTimelineEntry(date: .now, snapshot: WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DoseTimelineEntry>) -> Void) {
        let entry = DoseTimelineEntry(date: .now, snapshot: WidgetSnapshot.read())
        // The widget's content (next-dose countdown, today's protein) only
        // changes when the user logs something in the main app, and that save
        // path already calls `WidgetCenter.shared.reloadAllTimelines()` itself
        // (see `LiveActivityManager.refresh(...)`) — so a single-entry timeline
        // with `.never` just waits to be told to reload, rather than polling on
        // a fixed interval that would usually be showing stale data anyway.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct DoseWidgetEntryView: View {
    let entry: DoseTimelineEntry

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.isPremium {
            VStack(alignment: .leading, spacing: 4) {
                Label(snapshot.medicationName, systemImage: "syringe.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(snapshot.nextDoseDate, style: .relative)
                    .font(.headline)
                    .minimumScaleFactor(0.7)
                Text("until next dose")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                Gauge(value: min(snapshot.proteinConsumedGrams / max(snapshot.proteinGoalGrams, 1), 1)) {
                    Text("Protein")
                }
                .gaugeStyle(.linearCapacity)
                .tint(.teal)
                Text("\(Int(snapshot.proteinConsumedGrams.rounded()))g of \(Int(snapshot.proteinGoalGrams.rounded()))g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        } else if entry.snapshot?.isPremium == false {
            // Free-tier user: the widget itself is a Sustain+ feature (matching
            // GLPzy's precedent, per the conversion report), so it shows an
            // upsell rather than real data instead of just being unavailable.
            VStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                Text("Sustain+ feature")
                    .font(.caption.weight(.semibold))
                Text("Subscribe to see your next dose here")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
        } else {
            Text("Open Sustain to set up your widget")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(12)
        }
    }
}

struct DoseWidget: Widget {
    let kind = "DoseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DoseTimelineProvider()) { entry in
            DoseWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Dose & Protein")
        .description("See your next dose countdown and today's protein progress.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    DoseWidget()
} timeline: {
    DoseTimelineEntry(
        date: .now,
        snapshot: WidgetSnapshot(
            nextDoseDate: .now.addingTimeInterval(60 * 60 * 30),
            medicationName: "Semaglutide",
            doseMg: 1.0,
            proteinConsumedGrams: 62,
            proteinGoalGrams: 140,
            isPremium: true,
            updatedAt: .now
        )
    )
}
