import SwiftUI

/// Named tiers over `ProgressCalculator.proteinGoalStreak`'s existing day count.
///
/// Added 2026-08-02 in response to a specific gap flagged in
/// `Sustain-Subscription-Conversion-Report-2026-08.md`: the streak number was
/// already computed and already fed into the weekly AI recap, but on-screen it
/// was only ever a small caption next to the protein ring — never a first-class,
/// celebrated moment. The retention evidence cited there (Fitbit's leaderboard:
/// +15% daily steps; Calm's daily-reminder nudge: 3x retention) is specifically
/// about *visible* milestones and reminders, not the underlying number existing
/// quietly in a data model, which is exactly the gap this closes.
///
/// Deliberately a small, fixed set of round-number thresholds rather than a
/// badge for every single day — a badge that fires too often stops feeling like
/// an achievement. 7/14/30/60/100/180/365 mirror the same kind of milestones
/// Headspace and Duolingo use for exactly this reason (round numbers people
/// already think in terms of, spaced far enough apart to stay meaningful).
enum StreakMilestone: Int, CaseIterable, Identifiable {
    case week = 7
    case twoWeeks = 14
    case month = 30
    case twoMonths = 60
    case quarter = 100
    case halfYear = 180
    case year = 365

    var id: Int { rawValue }

    /// The highest milestone reached by a given streak length, or `nil` if the
    /// streak hasn't reached the first one yet. `AppStorage`-backed callers use
    /// this to decide whether today's streak count just crossed a *new* one.
    static func highestReached(forStreakDays days: Int) -> StreakMilestone? {
        allCases.filter { $0.rawValue <= days }.max { $0.rawValue < $1.rawValue }
    }

    var title: String {
        switch self {
        case .week: return "1-week streak"
        case .twoWeeks: return "2-week streak"
        case .month: return "1-month streak"
        case .twoMonths: return "2-month streak"
        case .quarter: return "100-day streak"
        case .halfYear: return "6-month streak"
        case .year: return "1-year streak"
        }
    }

    var celebrationDetail: String {
        switch self {
        case .week:
            return "Seven days in a row hitting your protein goal. That's a real habit forming, not luck."
        case .twoWeeks:
            return "Two straight weeks of hitting your protein goal. This is exactly the kind of consistency that preserves muscle during weight loss."
        case .month:
            return "A full month of hitting your protein goal, every single day. That's not a streak anymore, that's just how you eat now."
        case .twoMonths:
            return "Two months of daily protein goals hit. Most people don't make it this far. You have."
        case .quarter:
            return "100 days in a row. Triple digits. Whatever you're doing, it's working."
        case .halfYear:
            return "Half a year of daily protein goals, every single day. This is genuinely rare."
        case .year:
            return "A full year. 365 days of hitting your protein goal without a miss. This is one of the most consistent habits a person can build."
        }
    }

    /// Icon tier follows the same "the badge itself should look like an
    /// achievement" idea as the milestone spacing: a plain flame reads as
    /// "in progress," a filled star as "notable," a rosette as "exceptional" —
    /// matching how most habit apps visually escalate badge weight over time
    /// rather than reusing one icon at every tier.
    var iconName: String {
        switch self {
        case .week, .twoWeeks: return "flame.fill"
        case .month, .twoMonths: return "star.fill"
        case .quarter, .halfYear: return "rosette"
        case .year: return "crown.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .week, .twoWeeks: return Theme.warning
        case .month, .twoMonths: return Theme.primary
        case .quarter, .halfYear: return .purple
        case .year: return .yellow
        }
    }
}

/// One-time congratulatory sheet shown the moment a streak crosses a new
/// milestone — see `StreakMilestone`'s header comment for why this exists as
/// its own presented moment rather than only a slightly bigger badge. Which
/// milestones have already been shown is tracked by the caller (`DashboardView`)
/// via `@AppStorage`, not here, since this view has no reason to know about
/// persistence.
struct StreakMilestoneCelebrationView: View {
    let milestone: StreakMilestone
    let onDismiss: () -> Void

    // Rendered once, lazily, when the sheet appears — see
    // `ShareCardView.swift`'s header comment for why this is exactly the
    // moment (a milestone just crossed) the growth research names as the
    // right place for a share prompt, and why it's a real rendered image,
    // not a screenshot. `nil` until `.task` finishes; `ShareLink` simply
    // doesn't appear for the brief window before that, rather than
    // appearing disabled.
    @State private var shareCardImage: Image?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: milestone.iconName)
                .font(.system(size: 56))
                .foregroundStyle(milestone.tintColor)
                .padding(.top, 12)

            Text(milestone.title)
                .font(.title2.bold())

            Text(milestone.celebrationDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            if let shareCardImage {
                // `Image` conforms to `Transferable`, but real-device testing
                // of the plain `subject:`/`message:` initializer used here
                // originally failed to compile ("No exact matches in call to
                // initializer") — an `Image` item needs an explicit
                // `SharePreview` so the share sheet has something to render
                // as its own preview thumbnail, unlike `URL`/`Data`/`String`
                // items which don't need one.
                ShareLink(
                    item: shareCardImage,
                    preview: SharePreview(milestone.title, image: shareCardImage)
                ) {
                    Label("Share this milestone", systemImage: "square.and.arrow.up")
                }
                .font(.subheadline.weight(.medium))
            }

            Button("Keep going", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .tint(milestone.tintColor)
                .controlSize(.large)
                .padding(.horizontal, 40)
                .padding(.top, 8)
        }
        .padding(.vertical, 32)
        .presentationDetents([.medium])
        .task {
            shareCardImage = ShareCardRenderer.render(title: milestone.title, subtitle: milestone.celebrationDetail)
        }
    }
}

#Preview {
    StreakMilestoneCelebrationView(milestone: .month) {}
}
