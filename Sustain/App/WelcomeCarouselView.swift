import SwiftUI

/// The very first thing a brand-new install sees — a swipeable, page-style
/// carousel introducing Sustain's key features, ending in a sign-in page
/// (added 2026-07-31, per explicit request: "greeted through slides by
/// swiping right... the last slide should have the sign in page").
///
/// This sits in front of `MandatorySignInView`, not instead of it —
/// `MandatorySignInView` is embedded verbatim as this carousel's final page
/// (see `body` below), so the sign-in UI and its 3D button treatment are
/// defined in exactly one place and just get reused here rather than
/// duplicated. `MandatorySignInView` is still shown
/// on its own (no feature slides in front of it) for every *later* return to
/// the sign-in gate — sign out, delete account, or a session that expired —
/// since someone who's already used the app doesn't need the marketing tour
/// again. `ContentView` is what decides which of the two to show, based on
/// the `hasCompletedWelcomeCarousel` flag this view sets the moment sign-in
/// actually succeeds.
///
/// Swiping is the primary way through (native `TabView(.page)` paging,
/// exactly as asked for), but a "Skip" button in the top-right jumps
/// straight to the sign-in page for anyone who doesn't want to swipe
/// through four slides first — sign-in itself is still mandatory either way,
/// only the feature tour in front of it is skippable.
struct WelcomeCarouselView: View {
    @AppStorage("hasCompletedWelcomeCarousel") private var hasCompletedWelcomeCarousel = false
    @State private var page = 0

    private let lastPageIndex = 4

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $page) {
                // 2026-08-01: each slide below now carries a framed preview of
                // the actual feature it describes, not just an icon and two
                // lines of text — see `FeatureSlide`'s header comment for why
                // and how "screenshot-like" these previews really are.
                FeatureSlide(
                    icon: "leaf.circle.fill",
                    title: "Welcome to Sustain",
                    subtitle: "The GLP-1 companion built to protect your muscle, not just track your weight."
                ) {
                    HStack(spacing: 10) {
                        MiniStatChip(icon: "syringe.fill", value: "5 mg", caption: "Next dose Wed")
                        MiniStatChip(icon: "flame.fill", value: "62g", caption: "Protein today")
                        MiniStatChip(icon: "arrow.down.right", value: "-4.2 lb", caption: "This month")
                    }
                }
                .tag(0)

                FeatureSlide(
                    icon: "syringe.fill",
                    title: "Never miss a dose",
                    subtitle: "Log injections or pills right on schedule, with reminders that fit your titration plan."
                ) {
                    // The real Dashboard component, not a redrawn copy — same
                    // reasoning as `WeightChartView` on the last slide.
                    NextDoseCard(
                        profile: MedicationProfile(
                            medication: .zepbound, form: .injection, frequency: .weekly,
                            startDate: .now, currentDoseMg: 5
                        ),
                        nextDoseDate: Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now,
                        onLogDose: {}
                    )
                }
                .tag(1)

                FeatureSlide(
                    icon: "camera.viewfinder",
                    title: "Snap a photo, get your protein",
                    subtitle: "Point your camera at a meal for an instant protein estimate, no manual lookup needed."
                ) {
                    PhotoEstimateMockup()
                }
                .tag(2)

                FeatureSlide(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "See the full picture",
                    subtitle: "Track weight, protein, and side-effect trends over time, all in one place."
                ) {
                    // Real chart component fed sample data purely for display —
                    // nothing here is persisted or queried live. Using the
                    // actual `WeightChartView` (rather than a hand-drawn
                    // lookalike) means this preview can never visually drift
                    // out of sync with what the real Trends tab looks like.
                    WeightChartView(
                        // `.reversed()` first: the entries are built newest-first
                        // (i = 0 is today), but `WeightChartView` expects
                        // ascending-by-date, same as its real call site
                        // (`TrendsView`'s `@Query(sort: \WeightEntry.date)`).
                        entries: Array((0..<10).map { i in
                            WeightEntry(
                                date: Calendar.current.date(byAdding: .day, value: -i * 4, to: .now) ?? .now,
                                weightLbs: 212 - Double(i) * 1.8
                            )
                        }.reversed()),
                        unit: .pounds
                    )
                }
                .tag(3)

                MandatorySignInView(onSignedIn: { hasCompletedWelcomeCarousel = true })
                    .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: page == lastPageIndex ? .never : .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .tint(Theme.primary)
            .animation(.easeInOut(duration: 0.3), value: page)

            if page < lastPageIndex {
                Button("Skip") {
                    withAnimation { page = lastPageIndex }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding()
            }
        }
        .background(Theme.screenBackground)
    }
}

/// One feature-highlight page. **Redesigned 2026-08-01**, reported directly:
/// the original layout (one big SF Symbol, a title, a subtitle, lots of empty
/// space) read as *too* simple for a marketing tour — nothing to actually
/// look at besides text. Each slide now leads with a framed preview of the
/// real feature it's describing, with the icon/title/subtitle demoted to a
/// short caption underneath rather than the whole page.
///
/// The previews aren't screenshots in the literal file-on-disk sense — this
/// project has no simulator or device access from where these are built, so
/// there's no way to capture and drop in an actual `.png`. Two of the four
/// (`NextDoseCard` on the dose slide, `WeightChartView` on the trends slide)
/// sidestep that entirely by embedding the *real, live* Dashboard/Trends
/// components with representative sample data — that's not a redrawn
/// lookalike, it's the exact same SwiftUI these features render with in the
/// app itself, so it can never visually drift out of sync with the real
/// thing. The other two (the mini stat row and the photo/protein mockup)
/// don't have a single existing component that fits, so they're built from
/// the same design tokens (`Theme`) the rest of the app uses, styled to read
/// as a plausible in-app moment rather than a generic marketing graphic.
///
/// The frame around each preview is deliberately `Theme.screenBackground`
/// behind a `Theme.cardBackground` card — the exact same two-tone the real
/// app uses for every screen with cards on it, which is what sells the
/// "this is a peek at the real app" read rather than a floating icon.
private struct FeatureSlide<Preview: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let preview: Preview

    init(icon: String, title: String, subtitle: String, @ViewBuilder preview: () -> Preview) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.preview = preview()
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)

            preview
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Theme.screenBackground, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
                .padding(.horizontal, 20)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(Theme.primary)
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                }

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical)
        .readableContentWidth(500)
        .background(Theme.screenBackground)
    }
}

/// A single stat tile for the welcome slide's mini-dashboard row — three of
/// these side by side stand in for a real Dashboard glance (dose, protein,
/// weight trend) without pulling in `DashboardView` itself, which needs a
/// live `ModelContext` and real queries this marketing page has neither of.
private struct MiniStatChip: View {
    let icon: String
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.primary)
            Text(value)
                .font(.subheadline.bold())
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Stand-in for the photo → protein-estimate moment (`LogProteinView`'s AI
/// photo path) — not the real capture flow, which needs the camera, network
/// access, and a live AI call this static marketing page shouldn't trigger.
/// Built to read as a plausible result screen: a real sample meal photo plus
/// the same floating result badge shape `LogProteinView` itself uses once an
/// estimate comes back.
///
/// `"GrilledChickenSample"` (2026-08-01) — a free-to-use, no-attribution-
/// required stock photo (Pexels license), added to `Assets.xcassets` as its
/// own imageset specifically for this slide. Previously this was a fork/
/// knife SF Symbol on a gradient, which read clearly as a placeholder rather
/// than a photo once seen on a real device — swapped for an actual photo
/// once one was available, same badge overlay as before.
private struct PhotoEstimateMockup: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image("GrilledChickenSample")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 170)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Label("35g protein · Grilled chicken", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(12)
        }
    }
}

#Preview {
    WelcomeCarouselView()
        .modelContainer(for: [
            MedicationProfile.self, DoseLog.self, WeightEntry.self, ProteinEntry.self, SideEffectLog.self,
        ], inMemory: true)
}
