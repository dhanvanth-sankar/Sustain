import SwiftUI

/// Sustain's mascot: "Pip," a small otter drawn entirely from SwiftUI shapes
/// (no image assets, so it's crisp at any size and free to restyle later).
///
/// **Why an otter, and why teal.** Chosen after a short design pass alongside
/// the research in `Sustain-Companion-Character-Research-2026-08.md`:
/// - Round head, oversized eyes, and a stubby body are a deliberate "baby
///   schema" silhouette (Duolingo's owl and Finch's bird both lean on the same
///   proportions) — the shape itself is what reads as friendly, not the
///   species.
/// - An otter fits Sustain specifically better than a generic round animal:
///   otters are widely known for holding hands/paws in a raft while resting
///   so they don't drift apart — a small, real piece of animal behavior that
///   maps naturally onto "staying connected/consistent," without needing to
///   invent a forced metaphor.
/// - Color deliberately reuses `Theme.primary` (the app's one accent teal)
///   rather than introducing a new brand color — color-psychology research on
///   health apps consistently points to blue/teal for calm and trust, and a
///   mascot in an unrelated color (e.g. a purple or orange creature) would
///   read as a bolted-on gimmick against Sustain's existing, deliberately
///   restrained palette (see `Theme.swift`'s own header comment). A cream
///   belly gives it a second, warm tone without leaving the existing palette.
/// - No competitor in this specific space (GLP-1 tracking) has a reactive
///   character at all — see the research doc's §4 — so there was no direct
///   precedent to match or avoid here, only the adjacent-category reasoning
///   above.
///
/// Mood is driven entirely by `CompanionMood` (engagement/consistency only,
/// never a weight or dose number) — see `CompanionEngagement.swift`'s header
/// comment for why that boundary is load-bearing, not a style choice.
struct CompanionCharacterView: View {
    let mood: CompanionMood
    /// `false` for the one call site that isn't a live, displayed-and-later-
    /// dismissed view: `ShareCardView`'s use of Pip inside `ImageRenderer`.
    /// Found in a pre-submission audit, not from a crash — `ImageRenderer`
    /// renders this view offscreen just long enough to rasterize it, but
    /// `.onAppear` still fires during that pass, which used to kick off
    /// `scheduleNextBlink()`'s self-rescheduling `DispatchQueue.main
    /// .asyncAfter` chain. Nothing in an `ImageRenderer` pass ever calls
    /// `.onDisappear` to cancel it (there's no real view lifecycle to tear
    /// down), so every rendered share card was leaking one indefinitely-
    /// recurring blink timer, each holding a copy of this view's `@State`
    /// alive forever. Harmless in the sense that nothing crashes, but a real
    /// resource leak that would grow by one live timer per share card
    /// rendered over a long session. Defaults to `true` so the Dashboard's
    /// actual on-screen Pip (which does have a normal lifecycle) is
    /// unaffected.
    var animatesOnAppear: Bool = true

    @State private var isBlinking = false
    @State private var breathe = false

    private let bodyColor = Theme.primary
    private let bellyColor = Color(red: 0.98, green: 0.95, blue: 0.87)

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                otterBody
                    .scaleEffect(breathe ? 1.0 : 0.97)
                    .animation(
                        .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                        value: breathe
                    )
            }
            .frame(height: 96)

            Text(caption)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .onAppear {
            guard animatesOnAppear else { return }
            breathe = true
            scheduleNextBlink()
        }
    }

    // MARK: - Drawing

    /// Every solid-color shape from the original flat version now goes through
    /// `shaded(_:color:size:)` instead of a plain `.fill(color)` — a top-left
    /// highlight and a bottom-right shadow baked into each shape via gradient,
    /// simulating one consistent light source so the character reads as a
    /// rounded, sculpted form rather than a flat sticker. Ears were also moved
    /// to draw *before* the head (previously they were layered on top of it),
    /// so the head now overlaps their base the way a head actually sits in
    /// front of ears — a small z-order fix that does a lot for depth on its
    /// own. A soft blurred ellipse underneath grounds the whole figure with a
    /// contact shadow, and the head gets its own drop shadow where it
    /// overlaps the body/ears, separating the layers instead of having
    /// everything read as one flat silhouette.
    private var otterBody: some View {
        ZStack {
            // Ground/contact shadow.
            Ellipse()
                .fill(Color.black.opacity(0.14))
                .frame(width: 58, height: 10)
                .blur(radius: 3)
                .offset(y: 58)

            // Tail, drawn behind the body so it just peeks out to one side.
            shaded(Capsule(), color: bodyColor, size: 46)
                .frame(width: 46, height: 16)
                .rotationEffect(.degrees(28))
                .offset(x: 34, y: 30)

            // Body.
            shaded(Ellipse(), color: bodyColor, size: 74)
                .frame(width: 74, height: 58)
                .offset(y: 26)

            // Belly.
            shaded(Ellipse(), color: bellyColor, size: 44)
                .frame(width: 44, height: 34)
                .offset(y: 32)

            // Ears — behind the head, so the head's own shadow (below) reads
            // as sitting in front of them.
            HStack(spacing: 46) {
                shaded(Circle(), color: bodyColor, size: 18).frame(width: 18, height: 18)
                shaded(Circle(), color: bodyColor, size: 18).frame(width: 18, height: 18)
            }
            .offset(y: -50)

            // Head.
            shaded(Circle(), color: bodyColor, size: 72)
                .frame(width: 72, height: 72)
                .offset(y: -18)
                .shadow(color: .black.opacity(0.16), radius: 3, y: 2)

            // Cheeks (a soft blush, not tied to mood — always present).
            HStack(spacing: 50) {
                Circle().fill(Color.pink.opacity(0.25)).frame(width: 14, height: 14)
                Circle().fill(Color.pink.opacity(0.25)).frame(width: 14, height: 14)
            }
            .offset(y: -6)

            eyes
                .offset(y: -18)

            // Nose, with its own tiny glint for the same glossy-highlight look
            // as the eyes.
            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 8, height: 6)
                Circle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 2, height: 2)
                    .offset(x: -1.5, y: -1)
            }
            .offset(y: -2)
        }
        .compositingGroup()
    }

    /// Fills `shape` with a flat base color, then layers a top-left radial
    /// highlight and a bottom-right radial shadow on top (both clipped to the
    /// same shape), which is enough to read as directional lighting on a
    /// rounded form without needing an actual 3D renderer. `size` should be
    /// roughly the shape's largest dimension so the gradients scale
    /// sensibly across the very different sizes used here (the 72pt head vs.
    /// the 18pt ears, for example).
    private func shaded<S: Shape>(_ shape: S, color: Color, size: CGFloat) -> some View {
        ZStack {
            shape.fill(color)
            shape.fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                    center: UnitPoint(x: 0.32, y: 0.26),
                    startRadius: 0,
                    endRadius: size * 0.85
                )
            )
            shape.fill(
                RadialGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.22)],
                    center: UnitPoint(x: 0.8, y: 0.9),
                    startRadius: 0,
                    endRadius: size * 0.85
                )
            )
        }
        .clipShape(shape)
    }

    /// Eyes are the one part of the drawing that changes shape with mood —
    /// deliberately a *small*, warm difference (a gentle closed-eye smile for
    /// `.active`, normal open eyes everywhere else) rather than any kind of
    /// frown, since `.waiting` is meant to read as "patient," not "upset." A
    /// separate, timed blink (see `scheduleNextBlink()`) runs independently of
    /// mood so Pip doesn't look static when idle.
    @ViewBuilder
    private var eyes: some View {
        HStack(spacing: 22) {
            eye
            eye
        }
    }

    @ViewBuilder
    private var eye: some View {
        if mood == .active && !isBlinking {
            // A small upward happy-eye arc instead of a filled circle. Was
            // previously a stroked `Capsule` outline, which rendered as a
            // flat, drooping oval and read as a tired/half-closed eye rather
            // than a smile — fixed by drawing an explicit arc that peaks
            // upward in the middle, the actual shape a "^-eye" needs.
            Path { path in
                path.move(to: CGPoint(x: 0, y: 7))
                path.addQuadCurve(to: CGPoint(x: 12, y: 7), control: CGPoint(x: 6, y: -1))
            }
            .stroke(Color.black.opacity(0.8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 12, height: 8)
        } else if isBlinking {
            Capsule()
                .fill(Color.black.opacity(0.8))
                .frame(width: 12, height: 2)
        } else {
            // A small offset glint turns a flat filled circle into a glossy,
            // rounded-looking eye — same trick as the nose's highlight above.
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 3, height: 3)
                    .offset(x: -2, y: -2.2)
            }
        }
    }

    private func scheduleNextBlink() {
        let delay = Double.random(in: 2.5...5.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeInOut(duration: 0.1)) { isBlinking = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeInOut(duration: 0.1)) { isBlinking = false }
                scheduleNextBlink()
            }
        }
    }

    // MARK: - Copy

    /// Every branch here is neutral-to-warm by design — see this file's header
    /// comment and `CompanionMood`'s own doc comment. There is no case that
    /// reads as disappointed, and none references weight, dose adherence, or
    /// any other outcome.
    private var caption: String {
        switch mood {
        case .new:
            return "Hi, I'm Pip! Log a dose, a meal, or a weigh-in and I'll keep you company."
        case .active:
            return "Good to see you today."
        case .resting:
            return "Whenever you're ready, I'm here."
        case .waiting:
            return "Still here, waiting for you."
        }
    }
}

/// Dashboard-ready card wrapper, matching `aiEstimateCard`/`chatCoachCard`'s
/// use of `.cardStyle()` in `DashboardView` so Pip sits visually consistent
/// with the rest of the screen rather than looking like a separate widget.
///
/// **Now Sustain's actual entry point into the AI chat coach**, merged in
/// directly rather than living as its own separate tile below — direct
/// feedback on the first version of this feature: "the figure ... is pretty
/// awkward considering that it has no function. Maybe blending in 'Ask
/// Sustain' and the figure would be a good idea, so it seems like you're
/// interacting with the figure." This is also exactly the "medium-risk"
/// tier the original companion-character research report recommended as a
/// safe way to give the existing chat coach a visual identity
/// (`Sustain-Companion-Character-Research-2026-08.md` §3) — Pip tapping
/// into `ChatCoachView` is that recommendation, not a new idea layered on
/// top of it. The old standalone `chatCoachCard` tile in `DashboardView`
/// was removed, not just duplicated, so there's exactly one entry point
/// into the chat coach instead of two competing ones.
struct CompanionCard: View {
    let mood: CompanionMood
    /// Drives the "SUSTAIN+" badge, same convention every other AI entry
    /// point on Dashboard already uses (`aiEstimateCard`'s own badge).
    var isPremium: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                CompanionCharacterView(mood: mood)

                HStack(spacing: 4) {
                    Text("Ask me anything")
                        .font(.caption.weight(.semibold))
                    if !isPremium {
                        Text("SUSTAIN+")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(Theme.primary)
                .padding(.bottom, 4)
            }
            // Same reasoning as `aiEstimateCard`'s own `.contentShape` —
            // without it, the `Spacer`/padding around the affordance row
            // wouldn't register taps even though it visually spans the
            // card's width.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }
}

#Preview("Active") {
    CompanionCard(mood: .active, isPremium: true) {}
        .padding()
}

#Preview("Resting") {
    CompanionCard(mood: .resting, isPremium: false) {}
        .padding()
}

#Preview("Waiting") {
    CompanionCard(mood: .waiting, isPremium: true) {}
        .padding()
}

#Preview("New") {
    CompanionCard(mood: .new, isPremium: true) {}
        .padding()
}
