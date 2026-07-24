import SwiftUI
import UnhogCore

/// Shown when the machine as a whole is short on memory. There is no process to
/// blame and no button that fixes it, so the banner's job is to explain rather
/// than to offer an action: without it the app silently reports "all clear"
/// while the Mac is unusable.
struct SystemPressureBanner: View {
    let pressure: SystemPressure
    let hasWorkloadIncidents: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(pressure.summary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(pressure.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(UnhogTheme.subtleText)
                    .fixedSize(horizontal: false, vertical: true)

                if !hasWorkloadIncidents {
                    Text(
                        "No single app is over its limit — it is the total of "
                            + "everything running."
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(
                cornerRadius: UnhogTheme.compactRadius,
                style: .continuous
            )
            .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: UnhogTheme.compactRadius,
                style: .continuous
            )
            .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pressure.summary) \(pressure.detail)")
    }

    private var tint: Color {
        pressure.level == .critical
            ? UnhogTheme.destructive
            : UnhogTheme.warning
    }

    private var symbolName: String {
        pressure.level == .critical
            ? "exclamationmark.triangle.fill"
            : "memorychip"
    }
}
