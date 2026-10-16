import SwiftUI

/// A lightweight, shape-drawn body diagram for picking an injection site.
/// Deliberately abstract rather than a rendered illustration so it ships
/// with zero image assets and stays crisp at any size.
///
/// `lastUsedSite` marks whichever zone was used last dose with a small clock
/// badge. Before this, the diagram was pure site *logging* — nothing in it
/// actually helped a user rotate, despite that being the whole clinical point
/// (repeat-site injections risk lipohypertrophy over time).
struct InjectionSiteDiagram: View {
    @Binding var selection: InjectionSite?
    var lastUsedSite: InjectionSite? = nil

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 18) {
                HStack(spacing: 60) {
                    zone(.leftArm, shape: .capsule, size: CGSize(width: 26, height: 70))
                    zone(.rightArm, shape: .capsule, size: CGSize(width: 26, height: 70))
                }

                HStack(spacing: 4) {
                    zone(.leftAbdomen, shape: .roundedLeft, size: CGSize(width: 60, height: 80))
                    zone(.rightAbdomen, shape: .roundedRight, size: CGSize(width: 60, height: 80))
                }

                HStack(spacing: 30) {
                    zone(.leftThigh, shape: .capsule, size: CGSize(width: 34, height: 90))
                    zone(.rightThigh, shape: .capsule, size: CGSize(width: 34, height: 90))
                }
            }

            if lastUsedSite != nil {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.warning)
                    Text("Used last time, rotating sites helps avoid skin irritation")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private enum ZoneShape {
        case capsule, roundedLeft, roundedRight
    }

    @ViewBuilder
    private func zone(_ site: InjectionSite, shape: ZoneShape, size: CGSize) -> some View {
        let isSelected = selection == site
        let isLastUsed = lastUsedSite == site
        let resolvedShape = zoneShape(shape)
        Button {
            selection = isSelected ? nil : site
        } label: {
            VStack(spacing: 6) {
                resolvedShape
                    .fill(isSelected ? Theme.primary : Theme.primaryLight)
                    .overlay(
                        resolvedShape
                            .stroke(isSelected ? Theme.primary : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if isLastUsed {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Theme.warning)
                                .clipShape(Circle())
                                .offset(x: 5, y: -5)
                        }
                    }
                    .frame(width: size.width, height: size.height)

                Text(site.shortDisplayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Theme.primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        // Never accessibility-audited before this pass (flagged as a real, open
        // gap in PROJECT_HANDOFF.md). Without this, VoiceOver only had the
        // abbreviated caption ("L. arm") to go on, and neither the selection
        // state nor the "used last time" clock badge — both purely visual (a
        // fill-color change and a small icon overlay) — were conveyed at all.
        // `.accessibilityElement(children: .ignore)` collapses the shape + badge
        // + caption into one element with an explicit label, so VoiceOver
        // announces one clear thing per zone instead of three disconnected ones.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(site.displayName)
        .accessibilityValue(isLastUsed ? "Used last time" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func zoneShape(_ shape: ZoneShape) -> AnyShape {
        switch shape {
        case .capsule:
            AnyShape(Capsule())
        case .roundedLeft:
            AnyShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 2, topTrailingRadius: 2))
        case .roundedRight:
            AnyShape(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 16, topTrailingRadius: 16))
        }
    }
}

#Preview {
    InjectionSiteDiagram(selection: .constant(.leftAbdomen), lastUsedSite: .leftAbdomen)
}
