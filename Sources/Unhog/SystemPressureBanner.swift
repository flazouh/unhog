import SwiftUI
import UnhogCore

/// Shown when the machine as a whole is short on memory.
///
/// No single process is over its limit, which is why the workload rules stay
/// silent, but "it is the total of everything running" is not something a user
/// can act on. The largest holders are named and offered up for quitting: that
/// is the one move available, and finding it is the entire point of the app.
struct SystemPressureBanner: View {
    let pressure: SystemPressure
    let hasWorkloadIncidents: Bool
    /// Largest memory holders, biggest first. Empty before the first sample.
    var topGroups: [ProcessGroup] = []
    var onQuit: ((ProcessGroupID) -> Void)?

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
                    Text(holdersLine)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if let largest = topGroups.first, let onQuit {
                Button("Quit \(largest.displayName)") {
                    onQuit(largest.id)
                }
                .buttonStyle(InlineActionStyle(tone: tint, compact: true))
                .padding(.top, 1)
            }
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

    /// Naming the holders turns an observation into somewhere to start. With no
    /// sample yet there is nothing to name, so the original explanation stands.
    private var holdersLine: String {
        guard !topGroups.isEmpty else {
            return "No single app is over its limit — it is the total of "
                + "everything running."
        }
        let named = topGroups.prefix(3)
            .map { "\($0.displayName) \(MetricFormatting.memory($0.memoryBytes))" }
            .joined(separator: " · ")
        return "Holding the most: \(named)."
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
