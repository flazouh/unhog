import UnhogCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var storageStore: StorageStore
    @ObservedObject var usageStore: UsageStore
    @State private var selectedSection: PopoverSection =
        ProcessInfo.processInfo.environment[
            "UNHOG_UI_PREVIEW_STATE"
        ]?.hasPrefix("storage") == true ? .storage : .activity

    var body: some View {
        VStack(spacing: 0) {
            header
            PopoverSectionPicker(selection: $selectedSection)
                .padding(.horizontal, UnhogTheme.pagePadding)
                .padding(.bottom, 10)

            // Pinned above the scrolling content: a machine running out of
            // memory is worth seeing whichever section happens to be open.
            if let pressure = store.systemPressure {
                SystemPressureBanner(
                    pressure: pressure,
                    hasWorkloadIncidents: !store.incidents.isEmpty
                )
                .padding(.horizontal, UnhogTheme.pagePadding)
                .padding(.bottom, 10)
                .transition(.opacity)
            }

            ScrollView {
                Group {
                    switch selectedSection {
                    case .activity:
                        activityContent
                    case .usage:
                        UsageView(store: usageStore)
                    case .storage:
                        StorageView(store: storageStore)
                    }
                }
                .transition(.opacity)
                .padding(.horizontal, UnhogTheme.pagePadding)
                .padding(.bottom, 14)
            }
        }
        .frame(
            width: UnhogTheme.popoverWidth,
            height: UnhogTheme.popoverHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Force quit remaining processes?",
            isPresented: Binding(
                get: {
                    store.pendingForceQuitConfirmationID != nil
                },
                set: {
                    if !$0 {
                        store.cancelPendingForceQuitConfirmation()
                    }
                }
            )
        ) {
            Button("Force Quit", role: .destructive) {
                store.confirmPendingForceQuit()
            }
            Button("Cancel", role: .cancel) {
                store.cancelPendingForceQuitConfirmation()
            }
        } message: {
            Text(
                "Only the verified processes that ignored the normal quit "
                    + "request will be force quit."
            )
        }
        .onAppear {
            let previewState = ProcessInfo.processInfo.environment[
                "UNHOG_UI_PREVIEW_STATE"
            ]
            if previewState == "storage" {
                selectedSection = .storage
                storageStore.applyPreviewFixture()
            } else if previewState == "storage-scanning" {
                selectedSection = .storage
                storageStore.applyScanningPreviewFixture()
            } else if previewState == "usage" {
                selectedSection = .usage
                usageStore.applyPreviewFixture()
            }
        }
    }

    private var activityContent: some View {
        VStack(spacing: 14) {
            ResourceLensView(store: store)
            activity

            if store.recoveryAssessment == nil,
                let message = store.message
            {
                messageRow(message)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: store.menuBarPresentation.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)

            Text("Unhog")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            overflowMenu
        }
        .padding(.horizontal, UnhogTheme.pagePadding)
        .padding(.vertical, 11)
    }

    private var overflowMenu: some View {
        FluidDropdown(
            width: 218,
            triggerStyle: .iconOnly
        ) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .medium))
        } content: {
            FluidDropdownSectionLabel("Monitoring")

            if store.isMonitoringPaused {
                FluidDropdownAction(
                    "Resume monitoring",
                    systemImage: "play"
                ) {
                    store.resumeMonitoring()
                }
            } else {
                FluidDropdownAction(
                    "Pause for 15 minutes",
                    systemImage: "pause"
                ) {
                    store.pauseMonitoring(for: 15 * 60)
                }
                FluidDropdownAction(
                    "Pause for 1 hour",
                    systemImage: "clock"
                ) {
                    store.pauseMonitoring(for: 60 * 60)
                }
                FluidDropdownAction(
                    "Pause until resumed",
                    systemImage: "pause.circle"
                ) {
                    store.pauseMonitoring(for: nil)
                }
            }

            Divider()
                .padding(.vertical, 2)

            FluidDropdownSettingsLink()

            FluidDropdownAction(
                "Quit Unhog",
                systemImage: "power",
                tone: .destructive
            ) {
                store.quitApplication()
            }
        }
        .accessibilityLabel("Unhog controls")
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.focusedGroupID == nil ? "Apps" : "Other apps")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 2)

            if displayedGroups.isEmpty {
                Text("No active user processes to show.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(displayedGroups) { group in
                        ProcessActivityRow(
                            group: group,
                            explanation: store.explanation(for: group),
                            signature: store.drainSignature(for: group),
                            branches: store.branches(for: group),
                            severity: store.incidents.first {
                                $0.id == group.id
                            }?.severity,
                            showsProjectNames:
                                store.preferences.safety.showsProjectNames,
                            isExpanded: store.selectedGroupID == group.id,
                            stopState: store.stopState,
                            capability: store.capability(for: group),
                            isAwaitingQuitConfirmation:
                                store.pendingQuitGroup?.id == group.id,
                            hasPendingQuitConfirmation:
                                store.pendingQuitGroup != nil,
                            isMuted: store.isMuted(group),
                            onToggle: { store.toggleDetails(for: group.id) },
                            onQuit: { store.requestQuit(group.id) },
                            onConfirmQuit: {
                                store.confirmPendingQuit()
                            },
                            onCancelQuit: {
                                store.cancelPendingQuit()
                            },
                            onForceQuit: { store.requestForceQuit(group.id) },
                            branchCapability: {
                                store.capability(for: $0)
                            },
                            onStopBranch: {
                                store.requestStopBranch($0)
                            },
                            onForceQuitBranch: {
                                store.requestForceQuit(
                                    $0.asProcessGroup.id
                                )
                            },
                            onToggleMute: {
                                store.toggleMuteAlerts(for: group)
                            }
                        )
                    }
                }
            }
        }
    }

    private var displayedGroups: [ProcessGroup] {
        store.groups.filter { $0.id != store.focusedGroupID }
    }

    private func messageRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.dismissMessage()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss message")

        }
        .padding(12)
        .background(UnhogTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: UnhogTheme.compactRadius))
    }

    private var statusText: String {
        if store.isMonitoringPaused { return "Paused" }
        if store.isPreparing { return "Checking" }
        if let recoveryAssessment = store.recoveryAssessment {
            switch recoveryAssessment {
            case .recovered:
                return "Recovered"
            case .restarted:
                return "Running again"
            case let .partial(_, remaining):
                return "\(remaining.count) still running"
            }
        }
        if store.incidents.isEmpty {
            return "All clear"
        }
        return "\(store.incidents.count) issue"
            + (store.incidents.count == 1 ? "" : "s")
    }

    private var statusColor: Color {
        if store.isMonitoringPaused { return .secondary }
        if store.isPreparing { return .secondary }
        if case .recovered? = store.recoveryAssessment {
            return UnhogTheme.healthyForeground
        }
        if case .restarted? = store.recoveryAssessment {
            return UnhogTheme.warningForeground
        }
        if case .partial? = store.recoveryAssessment {
            return UnhogTheme.warningForeground
        }
        guard let incident = store.activeIncident else {
            return UnhogTheme.healthyForeground
        }
        return UnhogTheme.severityForeground(
            for: incident.severity
        )
    }
}
