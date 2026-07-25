import UnhogCore
import SwiftUI

struct ResourceLensView: View {
    @ObservedObject var store: AppStore
    @Environment(\.unhogReduceMotion) private var reduceMotion

    @State private var showsEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            InstalledMemoryMapView(
                composition: store.memoryComposition,
                focusedGroupID: store.focusedGroupID,
                availableBytes: store.systemMemory?.availableBytes
            )

            content
                .transition(.opacity)
        }
        .onChange(of: store.focusedGroupID) {
            showsEvidence = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isMonitoringPaused {
            paused
        } else if let assessment = store.recoveryAssessment {
            recovery(assessment)
        } else if let group = store.resolvingGroup,
            store.stopState != .idle
        {
            focusedWorkload(
                group: group,
                incident: store.incidents.first { $0.id == group.id }
            )
        } else if let incident = store.activeIncident {
            focusedWorkload(
                group: incident.group,
                incident: incident
            )
        } else if store.isPreparing {
            measuring
        } else {
            calm
        }
    }

    private var paused: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "pause.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("Monitoring is paused")
                    .font(.system(size: 14, weight: .semibold))
                Text("Unhog is not sampling processes or sending alerts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Resume") {
                    store.resumeMonitoring()
                }
                .buttonStyle(InlineActionStyle())
            }
        }
        .padding(.vertical, 5)
    }

    private var measuring: some View {
        HStack(spacing: 10) {
            LoadingIndicator(size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("Measuring current resource use")
                    .font(.system(size: 14, weight: .semibold))
                Text("The first useful CPU reading takes two samples.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private var calm: some View {
        HStack(alignment: .top, spacing: 9) {
            // The per-app rules being quiet is not the same as the machine being
            // well, and the banner above says so in red. Claiming everything
            // looks normal directly underneath it reads as a broken app.
            let machineIsStruggling = store.systemPressure != nil
            Image(
                systemName: machineIsStruggling
                    ? "magnifyingglass" : "checkmark.circle"
            )
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(
                machineIsStruggling
                    ? UnhogTheme.subtleText : UnhogTheme.healthyForeground
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    machineIsStruggling
                        ? "No single app is to blame"
                        : "Everything looks normal"
                )
                .font(.system(size: 14, weight: .semibold))
                Text("No app has sustained unusual CPU or memory use.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private func focusedWorkload(
        group: ProcessGroup,
        incident: ResourceIncident?
    ) -> some View {
        let explanation = store.explanation(for: group)
        let signature = store.drainSignature(for: group)

        return VStack(alignment: .leading, spacing: 9) {
            Text(incidentEyebrow(incident))
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.55)
                .foregroundStyle(incidentColor(incident))

            HStack(spacing: 10) {
                ProcessIconView(group: group, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(explanation.workloadTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)

                    Text(workloadDeck(group, signature: signature))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }

            ResourceSignatureView(signature: signature)

            if showsEvidence {
                evidence(group: group, explanation: explanation)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(
                                with: .scale(
                                    scale: 0.97,
                                    anchor: .top
                                )
                            )
                    )
            }

            action(for: group)
        }
        .padding(12)
        .background(UnhogTheme.surface)
        .clipShape(
            RoundedRectangle(
                cornerRadius: UnhogTheme.cornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .contain)
    }

    private func evidence(
        group: ProcessGroup,
        explanation: ResourceExplanation
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(explanation.processChain.joined(separator: "  →  "))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(2)

            Text(
                "\(explanation.topWorker.name) · "
                    + "\(MetricFormatting.memory(explanation.topWorker.memoryBytes)) "
                    + "· \(Int((explanation.topWorker.memoryShare * 100).rounded()))% "
                    + "· \(explanation.confidence.rawValue) confidence"
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            let branches = store.branches(for: group)
            if !branches.isEmpty {
                Divider()
                    .padding(.vertical, 1)

                ProcessBranchBarView(
                    parent: group,
                    branches: branches,
                    stopState: store.stopState,
                    capability: { store.capability(for: $0) },
                    onStop: { store.requestStopBranch($0) },
                    onForceQuit: {
                        store.requestForceQuit($0.asProcessGroup.id)
                    }
                )
            }
        }
        .padding(.vertical, 2)
    }

    private func incidentEyebrow(
        _ incident: ResourceIncident?
    ) -> String {
        guard let incident else { return "NEEDS ATTENTION" }
        return "NEEDS ATTENTION · "
            + MetricFormatting.duration(incident.duration).uppercased()
    }

    private func incidentColor(
        _ incident: ResourceIncident?
    ) -> Color {
        guard let incident else {
            return UnhogTheme.warningForeground
        }
        return UnhogTheme.severityForeground(
            for: incident.severity
        )
    }

    private func workloadDeck(
        _ group: ProcessGroup,
        signature: DrainSignature
    ) -> String {
        let processes =
            "\(group.processCount) process"
            + (group.processCount == 1 ? "" : "es")
        return "\(processes) · \(signature.impact.rawValue.lowercased()) energy use"
    }

    @ViewBuilder
    private func action(for group: ProcessGroup) -> some View {
        switch store.capability(for: group) {
        case .allowed:
            if isStopping(group) {
                Button {
                } label: {
                    HStack(spacing: 7) {
                        LoadingIndicator(size: 11)
                        Text(stoppingTitle(group))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(
                    BorderlessActionStyle(
                        tone: isStackWorkload(group)
                            ? .destructive
                            : .primary
                    )
                )
                .disabled(true)
                .accessibilityLabel(stoppingTitle(group))
            } else if isAwaitingQuitConfirmation(group) {
                InlineConfirmationControl(
                    confirmTitle: "Confirm",
                    confirmAccessibilityLabel:
                        "Confirm \(stopActionTitle(group))",
                    onCancel: {
                        animateConfirmationChange {
                            store.cancelPendingQuit()
                        }
                    },
                    onConfirm: {
                        animateConfirmationChange {
                            store.confirmPendingQuit()
                        }
                    }
                )
                .transition(confirmationTransition)
            } else {
                HStack(spacing: 8) {
                    Button {
                        animateConfirmationChange {
                            store.requestQuit(group.id)
                        }
                    } label: {
                        Text(visibleStopActionTitle(group))
                            .lineLimit(1)
                    }
                    .buttonStyle(
                        BorderlessActionStyle(
                            tone: isStackWorkload(group)
                                ? .destructive
                                : .primary
                        )
                    )
                    .disabled(
                        store.stopState != .idle
                            || store.pendingQuitGroup != nil
                    )
                    .accessibilityLabel(stopActionTitle(group))

                    evidenceButton(for: group)

                    Button {
                        store.toggleMuteAlerts(for: group)
                    } label: {
                        Label(
                            store.isMuted(group) ? "Unmute" : "Mute",
                            systemImage: store.isMuted(group)
                                ? "bell"
                                : "bell.slash"
                        )
                    }
                    .buttonStyle(InlineActionStyle())
                    .accessibilityLabel(
                        "\(store.isMuted(group) ? "Unmute" : "Mute") alerts for \(group.displayName)"
                    )
                }
            }

        case let .protected(reason):
            Label(reason, systemImage: "lock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func evidenceButton(
        for group: ProcessGroup
    ) -> some View {
        let branchCount = store.branches(for: group).count

        return Button {
            withAnimation(
                reduceMotion
                    ? UnhogTheme.motionFade
                    : UnhogTheme.motionEnter
            ) {
                showsEvidence.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(
                    showsEvidence
                        ? "Hide details"
                        : branchCount > 0
                            ? "Manage \(branchCount) "
                                + (branchCount == 1 ? "part" : "parts")
                            : "Details"
                )
                .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(showsEvidence ? 180 : 0))
            }
        }
        .buttonStyle(InlineActionStyle())
        .accessibilityValue(showsEvidence ? "Expanded" : "Collapsed")
        .accessibilityHint(
            branchCount > 0
                ? "Shows process evidence and controls for parts of this stack"
                : "Shows the process chain and top worker"
        )
    }

    @ViewBuilder
    private func recovery(
        _ assessment: RecoveryAssessment
    ) -> some View {
        switch assessment {
        case let .recovered(receipt):
            receiptView(
                receipt,
                symbol: "checkmark.circle.fill",
                title: recoveredTitle(receipt),
                detail: recoveredDetail(receipt),
                tone: UnhogTheme.healthyForeground
            )

        case let .restarted(receipt):
            receiptView(
                receipt,
                symbol: "arrow.clockwise.circle.fill",
                title: "\(recoveryDisplayName(receipt)) is running again",
                detail: "A matching new \(receipt.displayName) workload appeared",
                tone: UnhogTheme.warningForeground
            )

        case let .partial(receipt, remaining):
            partialRecovery(
                receipt: receipt,
                remainingCount: remaining.count
            )
        }
    }

    private func receiptView(
        _ receipt: RecoveryReceipt,
        symbol: String,
        title: String,
        detail: String,
        tone: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            comparison(receipt)

            Button("Done") {
                store.dismissRecovery()
            }
            .buttonStyle(BorderlessActionStyle(tone: .primary))

            if let message = store.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func comparison(
        _ receipt: RecoveryReceipt
    ) -> some View {
        HStack(spacing: 10) {
            comparisonMetric(
                label: receipt.scope == .branch
                    ? "Branch memory"
                    : "Stack memory",
                before: MetricFormatting.memory(receipt.before.memoryBytes),
                after: MetricFormatting.memory(receipt.after.memoryBytes)
            )
            comparisonMetric(
                label: "CPU",
                before: MetricFormatting.cpu(receipt.before.cpuPercent),
                after: MetricFormatting.cpu(receipt.after.cpuPercent)
            )
        }
    }

    private func comparisonMetric(
        label: String,
        before: String,
        after: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text(before)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(after)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 12, design: .rounded))
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func partialRecovery(
        receipt: RecoveryReceipt,
        remainingCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "\(remainingCount) process\(remainingCount == 1 ? "" : "es") did not stop",
                systemImage: "exclamationmark.circle"
            )
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(UnhogTheme.warningForeground)

            Text(
                "Unhog stopped \(receipt.stoppedProcessCount) original process\(receipt.stoppedProcessCount == 1 ? "" : "es")."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if store.stopState == .forceAvailable(receipt.originalGroupID) {
                    Button("Force quit \(remainingCount)") {
                        store.requestForceQuit(receipt.originalGroupID)
                    }
                    .buttonStyle(BorderlessActionStyle(tone: .destructive))

                    Button("Cancel") {
                        store.cancelPendingForceQuit()
                    }
                    .buttonStyle(BorderlessActionStyle(tone: .secondary))
                } else if store.stopState
                    == .forceKilling(receipt.originalGroupID)
                {
                    LoadingIndicator(size: 11)
                    Text("Force quitting…")
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Button("Done") {
                        store.dismissRecovery()
                    }
                    .buttonStyle(BorderlessActionStyle(tone: .primary))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func recoveryDisplayName(_ receipt: RecoveryReceipt) -> String {
        guard store.preferences.safety.showsProjectNames else {
            return receipt.displayName
        }
        return receipt.contextLabel ?? receipt.displayName
    }

    private func recoveredTitle(_ receipt: RecoveryReceipt) -> String {
        receipt.scope == .branch
            ? "\(receipt.displayName) stopped"
            : "Back to normal"
    }

    private func recoveredDetail(_ receipt: RecoveryReceipt) -> String {
        if receipt.scope == .branch {
            return "The rest of the workload is still running"
        }
        return "Stopped \(receipt.stoppedProcessCount) process"
            + (receipt.stoppedProcessCount == 1 ? "" : "es")
            + " safely"
    }

    private func stopActionTitle(_ group: ProcessGroup) -> String {
        WorkloadPresentation.actionTitle(
            for: group,
            includesProjectName:
                store.preferences.safety.showsProjectNames
        )
    }

    private func visibleStopActionTitle(
        _ group: ProcessGroup
    ) -> String {
        guard !isStackWorkload(group) else {
            return "Stop stack"
        }

        let name = WorkloadPresentation.shortName(
            for: group,
            includesProjectName: false
        )
        return "Quit \(name)"
    }

    private func isStackWorkload(_ group: ProcessGroup) -> Bool {
        let root =
            group.processes.first {
                $0.identity.pid == group.id.rootPID
            } ?? group.processes.first
        return root?.executablePath.contains(".app/") != true
    }

    private func stoppingTitle(_ group: ProcessGroup) -> String {
        let name = WorkloadPresentation.shortName(
            for: group,
            includesProjectName:
                store.preferences.safety.showsProjectNames
        )
        return "Stopping \(name)…"
    }

    private func isStopping(_ group: ProcessGroup) -> Bool {
        store.stopState == .quitting(group.id)
            || store.stopState == .forceKilling(group.id)
    }

    private func isAwaitingQuitConfirmation(
        _ group: ProcessGroup
    ) -> Bool {
        store.pendingQuitGroup?.id == group.id
    }

    private var confirmationTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
    }

    private func animateConfirmationChange(
        _ change: () -> Void
    ) {
        withAnimation(
            reduceMotion
                ? UnhogTheme.motionFade
                : UnhogTheme.motionEnter
        ) {
            change()
        }
    }

}
