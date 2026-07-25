import SwiftUI

/// The update surface for people who never open Settings.
struct UpdateBanner: View {
    let presentation: UpdateBannerPresentation
    let onPrimaryAction: (UpdateBannerPresentation.PrimaryAction.Kind) -> Void
    let onReleaseNotes: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                if let detail = presentation.detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(UnhogTheme.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            switch presentation.progress {
            case let .fraction(value):
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .frame(width: 64)
            case .indeterminate:
                ProgressView()
                    .controlSize(.small)
            case nil:
                EmptyView()
            }

            if presentation.showsReleaseNotes {
                Button(action: onReleaseNotes) {
                    Text("Notes")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                }
                .buttonStyle(InlineActionStyle(compact: true))
                .accessibilityLabel("View release notes")
            }

            if let primary = presentation.primary {
                Button {
                    onPrimaryAction(primary.kind)
                } label: {
                    Text(primary.label)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                }
                .buttonStyle(InlineActionStyle(tone: tint, compact: true))
                .accessibilityLabel(primary.label)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
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
    }

    private var tint: Color {
        presentation.isWarning ? UnhogTheme.destructive : UnhogTheme.energy
    }

    private var symbolName: String {
        presentation.isWarning
            ? "exclamationmark.triangle.fill"
            : "arrow.down.circle.fill"
    }
}
