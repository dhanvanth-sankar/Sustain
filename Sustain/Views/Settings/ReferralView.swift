import SwiftUI

/// Sustain's referral program — see `Sustain-In-Product-Growth-Loops-Research-2026-08.md`
/// for the reasoning (give-a-month-get-a-month is the best-quantified,
/// cheapest-per-install growth lever this project's research found, and
/// referred users retain and convert measurably better than any other
/// acquisition path) and `ReferralManager.swift` for the client logic /
/// `supabase/functions/referrals/index.ts` for the server side.
///
/// Two halves, both on one screen since they're the same feature from two
/// directions: share your own code (top), or redeem someone else's
/// (bottom). Deliberately doesn't hide the redeem field behind a second tap
/// — someone arriving here via a friend's link is exactly as important an
/// audience as someone about to share their own code.
struct ReferralView: View {
    @State private var referralManager = ReferralManager.shared
    @State private var redeemCodeText = ""
    @State private var isRedeeming = false
    @State private var redeemErrorMessage: String?
    @State private var redeemSucceeded = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Give a free month, get a free month")
                        .font(.headline)
                    Text("Share your code with a friend. When they use it, you both get a free month of Sustain+.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                if let code = referralManager.code {
                    HStack {
                        Text(code)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .kerning(2)
                        Spacer()
                        ShareLink(item: referralManager.shareText(for: code)) {
                            // Real bug, reported from a device screenshot: a
                            // `Label`'s icon inside a `ShareLink` sometimes
                            // fails to render on this button style while
                            // still reserving its layout space, leaving
                            // "Share" visibly off-center to the right inside
                            // the pill. Plain `Text` sidesteps the whole
                            // issue rather than fighting the icon rendering.
                            Text("Share")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.primary)
                    }
                    .padding(.vertical, 4)
                } else if referralManager.isLoadingCode {
                    HStack {
                        ProgressView()
                        Text("Getting your code…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Couldn't load your referral code. Check your connection and reopen this screen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Your code")
            }

            // A person can only ever redeem one code, ever (enforced
            // server-side) — once `hasRedeemed` is true, showing the field
            // again would just produce a confusing "already redeemed" error
            // on every attempt, so it's replaced with a plain confirmation
            // instead.
            Section {
                if referralManager.hasRedeemed || redeemSucceeded {
                    Label("You've already redeemed a referral code.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                } else {
                    TextField("Friend's code", text: $redeemCodeText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    Button("Redeem") {
                        Task { await redeem() }
                    }
                    .disabled(redeemCodeText.trimmingCharacters(in: .whitespaces).isEmpty || isRedeeming)

                    if isRedeeming {
                        HStack {
                            ProgressView()
                            Text("Redeeming…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let redeemErrorMessage {
                        Text(redeemErrorMessage)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                }
            } header: {
                Text("Have a friend's code?")
            }
        }
        .navigationTitle("Invite a friend")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await referralManager.loadCodeIfNeeded()
        }
    }

    private func redeem() async {
        isRedeeming = true
        redeemErrorMessage = nil
        defer { isRedeeming = false }
        do {
            try await referralManager.redeem(code: redeemCodeText)
            redeemSucceeded = true
        } catch {
            redeemErrorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        ReferralView()
    }
}
