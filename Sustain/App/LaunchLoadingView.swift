import SwiftUI

/// Shown for the brief window while the on-disk SwiftData store is being created
/// or opened. Deliberately pixel-matches the launch screen (same background, same
/// icon, no spinner) so there's no visible handoff — the app just appears to open.
struct LaunchLoadingView: View {
    var body: some View {
        Image(systemName: "leaf.circle.fill")
            .font(.system(size: 88))
            .foregroundStyle(Theme.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.screenBackground)
    }
}

#Preview {
    LaunchLoadingView()
}
