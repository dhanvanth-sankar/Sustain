import SwiftUI

/// A branded, shareable image generated from the user's own data at the
/// moment something worth celebrating happens — see
/// `Sustain-In-Product-Growth-Loops-Research-2026-08.md` §2 for why this
/// specific mechanic (Strava's activities, Whoop's streaks, Duolingo's own
/// fix for achievements that "used to be buried in the profile page and
/// hard to celebrate") is worth building, and why it's the user's own
/// device share sheet doing the posting rather than a brand account.
///
/// Deliberately reuses `CompanionCharacterView` (Pip) rather than a plain
/// logo — the card should look like it came from Sustain specifically, and
/// Pip is now the most recognizable, personality-carrying visual asset this
/// app has. Rendered via `ImageRenderer` (see `ShareCardRenderer` below),
/// not screenshotted from a live screen, so it looks identical regardless
/// of what the user was actually looking at when they tapped Share.
struct ShareCardView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 4)

            // `animatesOnAppear: false` — see `CompanionCharacterView`'s own
            // doc comment on that parameter: this view is rendered offscreen
            // by `ImageRenderer` for a single static frame, and without this
            // it would leak a recursive blink-scheduling timer every time a
            // share card is generated.
            CompanionCharacterView(mood: .active, animatesOnAppear: false)
                .scaleEffect(1.4)
                .frame(height: 150)

            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Image(systemName: "leaf.circle.fill")
                    .foregroundStyle(Theme.primary)
                Text("Sustain — GLP-1 Companion")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 420, height: 520)
        .background(
            LinearGradient(
                colors: [Theme.primaryLight, Color(uiColor: .systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

/// Renders `ShareCardView` to a plain SwiftUI `Image` so it can be handed
/// directly to `ShareLink(item:)` — `Image` has its own `ShareLink`
/// overload (no `Transferable` conformance needed), which is why this
/// returns `Image` rather than `UIImage`/`Data`.
///
/// Synchronous and main-thread-only (`ImageRenderer` requires both), which
/// is fine here: every call site renders a small, static view with no
/// network dependency, so this never blocks for long enough to need to be
/// async.
@MainActor
enum ShareCardRenderer {
    static func render(title: String, subtitle: String) -> Image? {
        let renderer = ImageRenderer(content: ShareCardView(title: title, subtitle: subtitle))
        renderer.scale = UIScreen.main.scale
        guard let uiImage = renderer.uiImage else { return nil }
        return Image(uiImage: uiImage)
    }
}

#Preview {
    ShareCardView(
        title: "30-day streak!",
        subtitle: "A full month of hitting your protein goal, every single day."
    )
}
