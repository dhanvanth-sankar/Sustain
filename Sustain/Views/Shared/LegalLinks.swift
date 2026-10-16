import SwiftUI

/// Terms of Use (EULA) and Privacy Policy links, in one place.
///
/// Required by App Store **Guideline 3.1.2(c)**, which rejected v1.0(2): apps with
/// auto-renewable subscriptions must show, *inside the app's own purchase flow*, the
/// subscription title, its length, its price (and price per unit where relevant), and
/// **functional links to both the Terms of Use (EULA) and the privacy policy**. The
/// previous submission only had those links in App Store Connect metadata, not in the
/// app itself, which is what the second rejection was about.
///
/// `termsOfUse` points at Apple's own standard EULA rather than a hearthlyapps-hosted
/// terms page on purpose: the app uses Apple's standard licence (no custom EULA is
/// configured in App Store Connect), so this is the licence that actually governs the
/// app, and it is guaranteed to stay reachable. If a custom EULA is ever added in App
/// Store Connect, change this URL to match it — the two must agree, or the mismatch
/// becomes its own rejection reason.
enum LegalLinks {
    static let privacyPolicy = URL(string: "https://hearthlyapps.com/privacy/")!
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let support = URL(string: "https://hearthlyapps.com/support/")!
}

/// The compact legal row that must appear on every purchase surface.
///
/// Both links are real `Link`s (not styled text), so a reviewer tapping either one
/// lands on the actual document — "functional links" in 3.1.2(c) means exactly that,
/// and a decorative label that goes nowhere reads as a failed requirement rather than
/// a cosmetic slip.
struct LegalLinksFooter: View {
    var body: some View {
        HStack(spacing: 6) {
            Link("Terms of Use (EULA)", destination: LegalLinks.termsOfUse)
            Text("·")
                .foregroundStyle(.secondary)
            Link("Privacy Policy", destination: LegalLinks.privacyPolicy)
        }
        .font(.caption2)
        .tint(Theme.primary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

#Preview {
    LegalLinksFooter()
        .padding()
}
