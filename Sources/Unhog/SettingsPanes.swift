import UnhogCore
import SwiftUI

struct GeneralSettingsPane: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updateController: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            menuBar
            updates
        }
    }

    private var menuBar: some View {
        SettingsGroup("Menu bar") {
            SettingsPicker(
                "Display",
                selection: preferenceBinding(
                    store,
                    \.general.menuBarDisplay
                ),
                options: MenuBarDisplayMode.allCases,
                label: {
                    switch $0 {
                    case .adaptive: "Adaptive"
                    case .iconOnly: "Icon only"
                    case .topCPU: "Top CPU"
                    case .topMemory: "Top RAM"
                    }
                }
            )
            SettingDescription(
                "Adaptive stays quiet normally, then shows the resource "
                    + "behind an alert."
            )
            Toggle(
                "Start Unhog at login",
                isOn: Binding(
                    get: { store.preferences.general.startsAtLogin },
                    set: { store.setStartsAtLogin($0) }
                )
            )
            SettingsPicker(
                "Motion",
                selection: preferenceBinding(store, \.general.motion),
                options: MotionPreference.allCases,
                label: {
                    $0 == .followSystem ? "Follow macOS" : "Reduced"
                }
            )
            SettingDescription(
                "The macOS Reduce Motion setting always takes priority."
            )
        }
    }

    private var updates: some View {
        SettingsGroup("Updates") {
            SettingValue(
                "Current version",
                updateController.currentVersionLabel
            )
            Toggle(
                "Check for updates automatically",
                // Written straight through to the updater as well as the stored
                // preference, so turning it off stops the next scheduled check
                // rather than the one after a relaunch.
                isOn: Binding(
                    get: {
                        store.preferences.general.automaticallyCheckForUpdates
                    },
                    set: { enabled in
                        store.updatePreferences {
                            $0.general.automaticallyCheckForUpdates = enabled
                        }
                        updateController.setAutomaticChecks(enabled)
                    }
                )
            )
            HStack {
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
                if updateController.state == .checking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            updateStatus
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updateController.state {
        case .idle, .checking:
            EmptyView()
        case .upToDate:
            SettingDescription("You're on the latest release.")
        case let .available(version):
            SettingDescription("Unhog \(version) is available.")
            HStack {
                Button("Install and restart") {
                    updateController.installUpdate()
                }
                Button("View release notes") {
                    updateController.openReleasePage()
                }
            }
        case .downloading:
            SettingDescription("Downloading the update…")
        case .installing:
            SettingDescription("Installing the update…")
        case .readyToRelaunch:
            SettingDescription("The update is ready.")
            Button("Restart Unhog") {
                updateController.installUpdate()
            }
        case let .failed(message):
            SettingDescription(message)
            Button("Try again") {
                updateController.checkForUpdates()
            }
        case .unavailable:
            SettingDescription(
                "Automatic updates need a signed copy of Unhog from a release "
                    + "build, so they are off in this one."
            )
        }
    }
}

struct MonitoringSettingsPane: View {
    @ObservedObject var store: AppStore
    let showAdvanced: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Alert behavior") {
                SettingsPicker(
                    "Sensitivity",
                    selection: preferenceBinding(
                        store,
                        \.monitoring.sensitivity
                    ),
                    options: AlertSensitivity.allCases,
                    label: sensitivityLabel
                )
                SettingDescription(sensitivityDescription)
                Toggle(
                    "Watch CPU drain",
                    isOn: preferenceBinding(
                        store,
                        \.monitoring.watchesCPU
                    )
                )
                Toggle(
                    "Watch memory drain",
                    isOn: preferenceBinding(
                        store,
                        \.monitoring.watchesMemory
                    )
                )
                SettingsPicker(
                    "Alert while",
                    selection: preferenceBinding(
                        store,
                        \.monitoring.alertScope
                    ),
                    options: AlertScope.allCases,
                    label: {
                        $0 == .always ? "Always" : "On battery"
                    }
                )
                PauseMonitoringRow(store: store)

                if store.preferences.monitoring.sensitivity == .custom {
                    Button("Edit custom thresholds…", action: showAdvanced)
                        .buttonStyle(InlineActionStyle())
                }
            }

            if !store.preferences.monitoring.mutedWorkloads.isEmpty {
                SettingsGroup("Muted workloads") {
                    ForEach(store.preferences.monitoring.mutedWorkloads) {
                        workload in
                        HStack {
                            Text(workload.displayName)
                                .lineLimit(1)
                            Spacer()
                            Button("Restore alerts") {
                                store.unmuteAlerts(workload.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sensitivityDescription: String {
        switch store.preferences.monitoring.sensitivity {
        case .quiet: "Only stronger drain lasting about 30 seconds."
        case .balanced:
            "Recommended. Ignores normal short compile and launch spikes."
        case .early:
            "Warns after about 10 seconds, useful while on battery."
        case .custom: "Uses the thresholds configured in Advanced."
        }
    }

    private func sensitivityLabel(_ value: AlertSensitivity) -> String {
        switch value {
        case .quiet: "Quiet"
        case .balanced: "Balanced"
        case .early: "Early"
        case .custom: "Custom"
        }
    }
}

struct NotificationSettingsPane: View {
    @ObservedObject var store: AppStore

    var body: some View {
        SettingsGroup("System notifications") {
            Toggle(
                "Show notifications",
                isOn: Binding(
                    get: {
                        store.preferences.notifications.isEnabled
                            && !store.notificationsDenied
                    },
                    set: { value in
                        store.updatePreferences {
                            $0.notifications.isEnabled = value
                        }
                    }
                )
            )
            .disabled(store.notificationsDenied)

            if store.notificationsDenied
                && store.preferences.notifications.isEnabled
            {
                notificationPermissionWarning
            }

            if store.preferences.notifications.isEnabled {
                SettingsPicker(
                    "Notify when",
                    selection: preferenceBinding(
                        store,
                        \.notifications.level
                    ),
                    options: NotificationLevel.allCases,
                    label: {
                        $0 == .needsAttention
                            ? "Needs attention"
                            : "Important only"
                    }
                )
                Toggle(
                    "A stopped workload starts again",
                    isOn: preferenceBinding(
                        store,
                        \.notifications.notifiesOnRestart
                    )
                )
                Toggle(
                    "Recovery is verified",
                    isOn: preferenceBinding(
                        store,
                        \.notifications.notifiesOnRecovery
                    )
                )
                Toggle(
                    "Play a sound",
                    isOn: preferenceBinding(
                        store,
                        \.notifications.playsSound
                    )
                )
                Toggle(
                    "Show workload names",
                    isOn: preferenceBinding(
                        store,
                        \.notifications.showsWorkloadNames
                    )
                )
                SettingDescription(
                    "Leave names off to keep lock-screen notifications private."
                )
            }
        }
    }

    private var notificationPermissionWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Notifications are disabled in macOS.",
                systemImage: "exclamationmark.circle"
            )
            .foregroundStyle(UnhogTheme.attention)
            HStack {
                Button("Open System Settings") {
                    store.openNotificationSettings()
                }
                Button("Check Again") {
                    Task {
                        await store.refreshNotificationAuthorization()
                    }
                }
            }
        }
        .font(.system(size: 11))
    }
}

struct SafetySettingsPane: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Actions") {
                Toggle(
                    "Confirm before stopping a whole workload",
                    isOn: preferenceBinding(
                        store,
                        \.safety.confirmsWholeStackStop
                    )
                )
                Toggle(
                    "Show project names in Unhog",
                    isOn: preferenceBinding(
                        store,
                        \.safety.showsProjectNames
                    )
                )
            }
            SettingsGroup("Permanent safeguards") {
                SafeguardRow(
                    "User processes only",
                    "macOS processes, other users, and Unhog stay protected."
                )
                SafeguardRow(
                    "Identity checked before every signal",
                    "A reused process ID can never target a different process."
                )
                SafeguardRow(
                    "Force Quit always asks",
                    "This confirmation cannot be disabled."
                )
                SafeguardRow(
                    "Everything stays on this Mac",
                    "No process, project, or usage data is uploaded."
                )
            }
        }
    }
}

struct AdvancedSettingsPane: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            sampling
            thresholds
            SettingsGroup("Support") {
                Button("Copy redacted diagnostics") {
                    store.copyDiagnostics()
                }
                SettingDescription(
                    "Excludes usernames, paths, command arguments, and PIDs."
                )
            }
        }
    }

    private var sampling: some View {
        SettingsGroup("Sampling") {
            SettingsPicker(
                "Profile",
                selection: preferenceBinding(
                    store,
                    \.monitoring.samplingProfile
                ),
                options: SamplingProfile.allCases,
                label: {
                    switch $0 {
                    case .efficient: "Efficient"
                    case .adaptive: "Adaptive"
                    case .responsive: "Responsive"
                    }
                }
            )
            SettingDescription(
                "Adaptive samples every 2–5 seconds. Efficient uses 3–8; "
                    + "Responsive uses 1–2."
            )
            Stepper(
                value: preferenceBinding(
                    store,
                    \.monitoring.recoveryVerificationDuration
                ),
                in: 2...10,
                step: 1
            ) {
                SettingValue(
                    "Verify a stop for",
                    "\(Int(store.preferences.monitoring.recoveryVerificationDuration)) seconds"
                )
            }
        }
    }

    private var thresholds: some View {
        SettingsGroup("Custom thresholds") {
            Stepper(
                value: preferenceBinding(
                    store,
                    \.monitoring.customCPUThresholdCores
                ),
                in: 0.5...32,
                step: 0.5
            ) {
                SettingValue(
                    "CPU attention",
                    String(
                        format: "%.1f cores",
                        store.preferences.monitoring.customCPUThresholdCores
                    )
                )
            }
            Stepper(
                value: preferenceBinding(
                    store,
                    \.monitoring.customMemoryShare
                ),
                in: 0.05...0.8,
                step: 0.05
            ) {
                SettingValue(
                    "Memory attention",
                    "\(Int((store.preferences.monitoring.customMemoryShare * 100).rounded()))% of installed RAM"
                )
            }
            Stepper(
                value: preferenceBinding(
                    store,
                    \.monitoring.customSustainedDuration
                ),
                in: 5...120,
                step: 5
            ) {
                SettingValue(
                    "Sustained for",
                    "\(Int(store.preferences.monitoring.customSustainedDuration)) seconds"
                )
            }
            HStack {
                Button("Use these thresholds") {
                    store.updatePreferences {
                        $0.monitoring.sensitivity = .custom
                    }
                }
                Button("Reset to Balanced") {
                    store.resetMonitoringPreferences()
                }
            }
        }
    }
}

private struct PauseMonitoringRow: View {
    @ObservedObject var store: AppStore

    var body: some View {
        HStack {
            Text("Monitoring")
            Spacer()
            if store.isMonitoringPaused {
                Button("Resume") {
                    store.resumeMonitoring()
                }
            } else {
                Menu("Pause…") {
                    Button("For 15 minutes") {
                        store.pauseMonitoring(for: 15 * 60)
                    }
                    Button("For 1 hour") {
                        store.pauseMonitoring(for: 60 * 60)
                    }
                    Button("Until I resume") {
                        store.pauseMonitoring(for: nil)
                    }
                }
            }
        }
    }
}

@MainActor
private func preferenceBinding<Value>(
    _ store: AppStore,
    _ keyPath: WritableKeyPath<UnhogPreferences, Value>
) -> Binding<Value> {
    Binding(
        get: { store.preferences[keyPath: keyPath] },
        set: { value in
            store.updatePreferences {
                $0[keyPath: keyPath] = value
            }
        }
    )
}

private struct SettingsPicker<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    init(
        _ title: String,
        selection: Binding<Option>,
        options: [Option],
        label: @escaping (Option) -> String
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }
}

private struct SettingDescription: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingValue: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct SafeguardRow: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            Divider()
        }
    }
}
