import AppKit
import UnhogCore
import SwiftUI

struct InstalledMemoryMapView: View {
    let composition: MemoryComposition
    let focusedGroupID: ProcessGroupID?
    /// Absent until the first sample lands, and on any Mac where the kernel
    /// refuses the statistics call.
    var availableBytes: UInt64?

    @Environment(\.unhogReduceMotion) private var reduceMotion
    @State private var revealed = false

    private let barHeight: CGFloat = 18
    private let segmentIconSize: CGFloat = 13
    private let segmentSpacing: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    "\(MetricFormatting.memory(composition.installedBytes)) memory"
                )
                .font(.system(size: 12, weight: .semibold))

                Spacer()

                // The bar maps the whole of installed RAM, so a percentage of it
                // could only ever read 100%. Headroom is the number that moves,
                // and the one worth knowing.
                if let availableBytes {
                    Text("\(MetricFormatting.memory(availableBytes)) available")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            GeometryReader { proxy in
                memoryChart(width: proxy.size.width)
            }
            .frame(height: barHeight)
        }
        .onAppear {
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(UnhogTheme.motionEnter) {
                    revealed = true
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func memoryChart(
        width: CGFloat
    ) -> some View {
        let geometry = chartGeometry(width: width)

        return memoryBar(geometry: geometry, width: width)
            .animation(
                reduceMotion ? nil : UnhogTheme.motionEnter,
                value: revealed
            )
    }

    private func memoryBar(
        geometry: ChartGeometry,
        width: CGFloat
    ) -> some View {
        HStack(spacing: segmentSpacing) {
            ForEach(geometry.segments) { item in
                memorySegment(item)
                    .frame(width: item.width)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(item.segment.group.displayName), "
                            + MetricFormatting.memory(item.segment.bytes)
                            + (item.segment.group.id == focusedGroupID
                                ? ", current issue"
                                : "")
                    )
            }

            remainderSegment(width: geometry.remainderWidth)
                .frame(width: geometry.remainderWidth)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "macOS, other apps, and unused memory, "
                        + MetricFormatting.memory(
                            composition.remainderBytes
                        )
                )
        }
        .frame(width: width, height: barHeight)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 5,
                style: .continuous
            )
        )
        .scaleEffect(
            x: revealed ? 1 : 0,
            y: 1,
            anchor: .leading
        )
    }

    private func memorySegment(
        _ item: SegmentGeometry
    ) -> some View {
        ZStack {
            UnhogTheme.identityColor(
                for: item.segment.group.displayName
            )

            if segmentIconFits(width: item.width) {
                HStack(spacing: 3) {
                    ProcessIconView(
                        group: item.segment.group,
                        size: segmentIconSize
                    )

                    if memoryValueFitsBesideIcon(
                        bytes: item.segment.bytes,
                        width: item.width
                    ) {
                        memoryValue(item.segment.bytes)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 2)
            }
        }
    }

    private func remainderSegment(
        width: CGFloat
    ) -> some View {
        ZStack {
            UnhogTheme.remainder

            if remainderValueFits(width: width) {
                Text(
                    "Other · \(MetricFormatting.memory(composition.remainderBytes))"
                )
                .font(.system(size: 7.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 3)
            }
        }
    }

    private func chartGeometry(
        width: CGFloat
    ) -> ChartGeometry {
        let itemCount = composition.segments.count + 1
        let totalSpacing =
            segmentSpacing
            * CGFloat(max(0, itemCount - 1))
        let usableWidth = max(0, width - totalSpacing)
        var cursor: CGFloat = 0

        let segments = composition.segments.map { segment in
            let segmentWidth =
                usableWidth
                * segment.shareOfInstalledRAM
            let item = SegmentGeometry(
                segment: segment,
                minimumX: cursor,
                width: segmentWidth
            )
            cursor += segmentWidth + segmentSpacing
            return item
        }

        return ChartGeometry(
            segments: segments,
            remainderWidth: usableWidth * composition.remainderShare
        )
    }

    private func remainderValueFits(
        width: CGFloat
    ) -> Bool {
        let label =
            "Other · "
            + MetricFormatting.memory(composition.remainderBytes)
        return measuredTextWidth(
            label,
            font: .systemFont(
                ofSize: 7.5,
                weight: .medium
            )
        ) + 6 <= width
    }

    private func memoryValueFitsBesideIcon(
        bytes: UInt64,
        width: CGFloat
    ) -> Bool {
        return measuredTextWidth(
            MetricFormatting.memory(bytes),
            font: .systemFont(
                ofSize: 7.5 * 0.72,
                weight: .semibold
            )
        ) + segmentIconSize + 9 <= width
    }

    private func segmentIconFits(width: CGFloat) -> Bool {
        segmentIconSize + 4 <= width
    }

    private func measuredTextWidth(
        _ text: String,
        font: NSFont
    ) -> CGFloat {
        ceil(
            (text as NSString).size(
                withAttributes: [.font: font]
            ).width
        )
    }

    private func memoryValue(
        _ bytes: UInt64
    ) -> some View {
        Text(MetricFormatting.memory(bytes))
            .font(
                .system(
                    size: 7.5,
                    weight: .semibold,
                    design: .rounded
                )
            )
            .monospacedDigit()
            .minimumScaleFactor(0.72)
            .foregroundStyle(Color.black.opacity(0.88))
            .lineLimit(1)
    }
}

private struct ChartGeometry {
    let segments: [SegmentGeometry]
    let remainderWidth: CGFloat
}

private struct SegmentGeometry: Identifiable {
    var id: ProcessGroupID {
        segment.id
    }

    let segment: AppMemorySegment
    let minimumX: CGFloat
    let width: CGFloat
}
