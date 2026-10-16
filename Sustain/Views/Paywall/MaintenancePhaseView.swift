import SwiftUI

/// The "what now?" upsell moment from the report's revenue model: a one-time
/// purchase offered when a user reaches their goal weight, separate from the
/// Sustain+ subscription. Follows the same trust-first, light-forced,
/// single-colored-CTA pattern as PaywallView — see that file's header comment for
/// the research this is based on.
struct MaintenancePhaseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entitlements = EntitlementManager.shared
    @State private var isPurchasing = false
    @State private var purchaseErrorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    header
                    benefitList
                }
                .padding()
                .padding(.bottom, 8)
                .readableContentWidth()
            }
            .background(Theme.screenBackground)
            .safeAreaInset(edge: .bottom) {
                purchaseSection
                    .padding()
                    .readableContentWidth()
                    .background(.thinMaterial)
            }
            .navigationTitle("Maintenance Program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert(
                "Couldn't complete purchase",
                isPresented: Binding(
                    get: { purchaseErrorMessage != nil },
                    set: { if !$0 { purchaseErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(purchaseErrorMessage ?? "")
            }
        }
        .preferredColorScheme(.light)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.success)
            Text("You reached your goal")
                .font(.title.bold())
            Text("Losing the weight was phase one. Keeping it off, without losing the muscle you worked to protect, is phase two.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefitRow(
                icon: "arrow.left.and.right",
                title: "A maintenance range, not a falling number",
                detail: "Your goal becomes a healthy range instead of a target to keep chasing downward"
            )
            benefitRow(
                icon: "text.bubble.fill",
                title: "A prescriber conversation guide",
                detail: "Questions worth asking about tapering or maintenance dosing at your next appointment"
            )
            benefitRow(
                icon: "checkmark.seal.fill",
                title: "One-time purchase",
                detail: "No added subscription, this unlocks permanently, on top of Sustain+"
            )
        }
        .cardStyle()
    }

    private func benefitRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var purchaseSection: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    isPurchasing = true
                    do {
                        try await entitlements.purchaseMaintenanceProgram()
                        dismiss()
                    } catch EntitlementManager.PurchaseError.userCancelled {
                        // Deliberate cancel — no error to show.
                    } catch {
                        purchaseErrorMessage = error.localizedDescription
                    }
                    isPurchasing = false
                }
            } label: {
                if isPurchasing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                } else {
                    Text("Unlock for \(EntitlementManager.maintenanceProgramPriceDisplay)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.primary)
            .controlSize(.large)
            .disabled(isPurchasing)

            Text("A one-time purchase, billed through your Apple ID. Doesn't renew or expire.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // This is a non-consumable, not an auto-renewable subscription, so
            // Guideline 3.1.2(c)'s subscription-specific disclosures don't strictly
            // apply here. The legal links are included anyway: it is still a purchase
            // surface, the cost of including them is a single row, and the cost of a
            // reviewer deciding otherwise is another rejection cycle.
            LegalLinksFooter()
        }
    }
}

#Preview {
    MaintenancePhaseView()
}
