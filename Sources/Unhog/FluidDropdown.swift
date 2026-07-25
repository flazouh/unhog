import AppKit
import SwiftUI

private struct FluidDropdownDismissAction: Sendable {
    let action: @MainActor @Sendable () -> Void

    @MainActor
    func callAsFunction() {
        action()
    }
}

private struct FluidDropdownDismissKey: EnvironmentKey {
    static let defaultValue = FluidDropdownDismissAction(action: {})
}

private extension EnvironmentValues {
    var dismissFluidDropdown: FluidDropdownDismissAction {
        get { self[FluidDropdownDismissKey.self] }
        set { self[FluidDropdownDismissKey.self] = newValue }
    }
}

struct FluidDropdown<Label: View, Content: View>: View {
    enum TriggerStyle {
        case standard
        case iconOnly
    }

    let width: CGFloat
    let triggerStyle: TriggerStyle
    @ViewBuilder let label: Label
    @ViewBuilder let content: Content

    @Environment(\.unhogReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var isHovered = false

    init(
        width: CGFloat = 220,
        triggerStyle: TriggerStyle = .standard,
        @ViewBuilder label: () -> Label,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.triggerStyle = triggerStyle
        self.label = label()
        self.content = content()
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                label

                if triggerStyle == .standard {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(
                            .degrees(isPresented ? 180 : 0)
                        )
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isPresented ? .primary : .secondary)
            .padding(
                .horizontal,
                triggerStyle == .iconOnly ? 0 : 8
            )
            .frame(
                width: triggerStyle == .iconOnly ? 28 : nil,
                height: 28
            )
            .background(
                isPresented || isHovered
                    ? UnhogTheme.surfaceHover
                    : .clear
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 7,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(
            reduceMotion ? nil : UnhogTheme.motionFade,
            value: isHovered
        )
        .animation(
            reduceMotion ? nil : UnhogTheme.motionEnter,
            value: isPresented
        )
        .popover(
            isPresented: $isPresented,
            arrowEdge: .bottom
        ) {
            FluidDropdownPanel(width: width) {
                content
            }
            .environment(
                \.dismissFluidDropdown,
                FluidDropdownDismissAction {
                    isPresented = false
                }
            )
            .presentationBackground(.clear)
        }
        .accessibilityValue(isPresented ? "Expanded" : "Collapsed")
    }
}

struct FluidDropdownSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

struct FluidDropdownAction: View {
    enum Tone {
        case normal
        case destructive
    }

    let title: String
    let subtitle: String?
    let systemImage: String
    let tone: Tone
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.dismissFluidDropdown) private var dismiss
    @Environment(\.unhogReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        tone: Tone = .normal,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 15)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, subtitle == nil ? 7 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered && !isDisabled
                    ? UnhogTheme.surfaceHover
                    : .clear
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 7,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
            .offset(
                x: isHovered && !isDisabled && !reduceMotion
                    ? 2
                    : 0
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
        .onHover { isHovered = $0 }
        .animation(
            reduceMotion ? nil : UnhogTheme.motionEnter,
            value: isHovered
        )
    }

    private var foreground: Color {
        tone == .destructive
            ? UnhogTheme.destructive
            : .primary
    }
}

struct FluidDropdownSettingsLink: View {
    @Environment(\.dismissFluidDropdown) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.unhogReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button {
            dismiss()
            openSettings()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 15)
                Text("Settings…")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isHovered
                    ? UnhogTheme.surfaceHover
                    : .clear
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 7,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
            .offset(x: isHovered && !reduceMotion ? 2 : 0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(
            reduceMotion ? nil : UnhogTheme.motionEnter,
            value: isHovered
        )
    }
}

private struct FluidDropdownPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    @Environment(\.unhogReduceMotion) private var reduceMotion
    @Environment(\.dismissFluidDropdown) private var dismiss
    @State private var appeared = false
    @FocusState private var receivesKeyboardFocus: Bool

    init(
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .padding(6)
        .frame(width: width)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(0.24),
            radius: 18,
            x: 0,
            y: 8
        )
        .scaleEffect(
            reduceMotion || appeared ? 1 : 0.96,
            anchor: .topTrailing
        )
        .opacity(reduceMotion || appeared ? 1 : 0)
        .focusSection()
        .focusable()
        .focused($receivesKeyboardFocus)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.downArrow) {
            NSApp.keyWindow?.selectNextKeyView(nil)
            return .handled
        }
        .onKeyPress(.upArrow) {
            NSApp.keyWindow?.selectPreviousKeyView(nil)
            return .handled
        }
        .onAppear {
            receivesKeyboardFocus = true

            if reduceMotion {
                appeared = true
            } else {
                withAnimation(
                    .spring(
                        response: 0.24,
                        dampingFraction: 0.90
                    )
                ) {
                    appeared = true
                }
            }
        }
    }
}
