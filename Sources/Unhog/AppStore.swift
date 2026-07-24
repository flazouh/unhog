import AppKit
import Combine
import UnhogCore
import Foundation
import ServiceManagement

@MainActor
final class AppStore: ObservableObject {
    enum StopState: Equatable {
        case idle
        case quitting(ProcessGroupID)
        case forceAvailable(ProcessGroupID)
        case forceKilling(ProcessGroupID)
    }

    @Published private(set) var groups: [ProcessGroup] = []
    @Published private(set) var incidents: [ResourceIncident] = []
    @Published private(set) var isPreparing = true
    @Published private(set) var stopState: StopState = .idle
    @Published private(set) var recoveryAssessment: RecoveryAssessment?
    @Published private(set) var resolvingGroup: ProcessGroup?
    @Published private(set) var message: String?
    @Published private(set) var pendingForceName: String?
    @Published private(set) var pendingQuitGroup: ProcessGroup?
    @Published private(set) var pendingForceQuitConfirmationID: ProcessGroupID?
    @Published private(set) var notificationsDenied = false
    @Published private(set) var monitoringPausedUntil: Date?
    @Published var selectedGroupID: ProcessGroupID?
    @Published private(set) var preferences: UnhogPreferences

    private let monitor: ProcessMonitor
    private let terminator: SystemProcessTerminator
    private let grouper = ProcessGrouper()
    private let terminationPolicy: TerminationPolicy
    private let notifications = NotificationController()
    private let preferencesRepository: UserDefaultsPreferencesRepository
    private let recoveryVerifier = RecoveryVerifier()
    private let branchRecoveryVerifier = BranchRecoveryVerifier()
    private let branchResolver = ProcessBranchResolver()
    private let resourceExplainer = ResourceExplainer()
    private let currentUID: UInt32
    private let appPID: Int32
    private var detector: ResourcePressureDetector
    private var monitoringTask: Task<Void, Never>?
    private var sampleCount = 0
    private var notifiedIncidentIDs = Set<ProcessGroupID>()
    private var latestGroups: [ProcessGroup] = []
    private var latestProcessIdentities = Set<ProcessIdentity>()
    private var previousGroupMemory: [ProcessGroupID: UInt64] = [:]
    private var stableGroupOrder: [WorkloadFingerprint: Int] = [:]
    private var nextStableGroupOrder = 0
    private var pressureIsRising = false
    private var pendingForcePlan: TerminationPlan?
    private var pendingForceGroup: ProcessGroup?
    private var recoveryCollapseTask: Task<Void, Never>?
    private var resolutionOriginalGroup: ProcessGroup?
    private var resolutionBranch: ProcessBranch?
    private var resolutionPreexistingBranchIDs = Set<ProcessBranchID>()
    private var resolutionIncident: ResourceIncident?
    private var resolutionPreexistingMatchingGroupIDs =
        Set<ProcessGroupID>()
    private var resolutionStartedAt: Date?
    private let actionsEnabled: Bool

    init(
        monitor: ProcessMonitor = ProcessMonitor(),
        currentUID: UInt32 = getuid(),
        appPID: Int32 = getpid(),
        actionsEnabled: Bool = true,
        preferencesRepository: UserDefaultsPreferencesRepository =
            UserDefaultsPreferencesRepository()
    ) {
        let preferences = preferencesRepository.load()
        self.monitor = monitor
        self.currentUID = currentUID
        self.appPID = appPID
        self.actionsEnabled = actionsEnabled
        self.preferencesRepository = preferencesRepository
        self.preferences = preferences
        let monitoringPolicy = PreferencePolicies.make(
            from: preferences,
            installedMemoryBytes: ProcessInfo.processInfo.physicalMemory
        ).monitoring
        self.detector = ResourcePressureDetector(
            thresholds: monitoringPolicy.thresholds
        )
        self.terminator = SystemProcessTerminator(currentUID: currentUID)
        self.terminationPolicy = TerminationPolicy(
            currentUID: currentUID,
            appPID: appPID
        )
    }

    var activeIncident: ResourceIncident? {
        incidents.first
    }

    var focusedGroup: ProcessGroup? {
        if let recoveryAssessment {
            switch recoveryAssessment {
            case .recovered:
                return nil
            case let .restarted(receipt):
                return resolvingGroup
                    ?? receipt.successorGroupID.flatMap(group(with:))
            case .partial:
                return resolvingGroup
            }
        }
        if let resolvingGroup {
            return resolvingGroup
        }
        if let incident = activeIncident {
            return incident.group
        }
        return nil
    }

    var focusedGroupID: ProcessGroupID? {
        focusedGroup?.id
    }

    var installedMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    var memoryComposition: MemoryComposition {
        MemoryComposition(
            installedBytes: installedMemoryBytes,
            groups: latestGroups,
            maximumVisibleSegments: 3,
            prioritizedGroupID: focusedGroupID
        )
    }

    func ramShare(for group: ProcessGroup) -> Double {
        guard installedMemoryBytes > 0 else { return 0 }
        return min(
            1,
            Double(group.memoryBytes) / Double(installedMemoryBytes)
        )
    }

    func batteryEstimate(for group: ProcessGroup) -> BatteryDrainEstimate {
        BatteryDrainEstimate(cpuPercent: group.cpuPercent)
    }

    func drainSignature(for group: ProcessGroup) -> DrainSignature {
        let signal = incidents.first { $0.id == group.id }?.signal
        let coreCount = max(1, ProcessInfo.processInfo.processorCount)
        let cpuShare = min(
            1,
            group.cpuPercent / 100 / Double(coreCount)
        )
        return DrainSignature(
            group: group,
            primarySignal: signal
                ?? (ramShare(for: group) >= cpuShare ? .memory : .cpu),
            installedMemoryBytes: installedMemoryBytes,
            logicalCoreCount: coreCount
        )
    }

    func branches(for group: ProcessGroup) -> [ProcessBranch] {
        branchResolver.visibleBranches(in: group)
    }

    func capability(for branch: ProcessBranch) -> TerminationCapability {
        terminationPolicy.plan(for: branch).capability
    }

    func explanation(for group: ProcessGroup) -> ResourceExplanation {
        resourceExplainer.explain(
            group,
            includesProjectContext:
                preferences.safety.showsProjectNames
        )
    }

    var menuBarPresentation: MenuBarPresentation {
        MenuBarPresentation.make(
            phase: menuBarPhase,
            leadingGroup: menuBarLeadingGroup,
            installedMemoryBytes: installedMemoryBytes,
            displayMode: preferences.general.menuBarDisplay
        )
    }

    var menuBarDrainSignature: DrainSignature? {
        menuBarLeadingGroup.map(drainSignature(for:))
    }

    var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || preferences.general.motion == .reduced
    }

    var isMonitoringPaused: Bool {
        guard let monitoringPausedUntil else { return false }
        return monitoringPausedUntil > Date()
    }

    func start() {
        guard monitoringTask == nil else { return }

        monitoringTask = Task { [weak self] in
            if let self, self.preferences.notifications.isEnabled {
                self.notificationsDenied =
                    !(await self.notifications.requestPermission())
            }

            while !Task.isCancelled {
                guard let interval = await self?.refreshAndNextInterval() else {
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func applyPreviewFixture(
        groups: [ProcessGroup],
        incidents: [ResourceIncident],
        recoveryAssessment: RecoveryAssessment? = nil,
        resolvingGroup: ProcessGroup? = nil,
        stopState: StopState = .idle
    ) {
        monitoringTask?.cancel()
        monitoringTask = nil
        sampleCount = 2
        isPreparing = false
        latestGroups = groups
        latestProcessIdentities = Set(
            groups.flatMap(\.processes).map(\.identity)
        )
        self.groups = groups
        self.incidents = incidents
        self.recoveryAssessment = recoveryAssessment
        self.resolvingGroup = resolvingGroup
        self.stopState = stopState
    }

    func toggleDetails(for id: ProcessGroupID) {
        if selectedGroupID == id,
            pendingQuitGroup?.id == id
        {
            cancelPendingQuit()
        }
        selectedGroupID = selectedGroupID == id ? nil : id
    }

    func capability(for group: ProcessGroup) -> TerminationCapability {
        terminationPolicy.plan(for: group).capability
    }

    func requestQuit(_ id: ProcessGroupID) {
        guard actionsEnabled else {
            message = "Preview only — no process was stopped."
            return
        }
        guard stopState == .idle,
            let group = group(with: id)
        else {
            return
        }

        if preferences.safety.confirmsWholeStackStop {
            pendingQuitGroup = group
            return
        }

        beginQuit(group)
    }

    func requestStopBranch(_ branch: ProcessBranch) {
        guard actionsEnabled else {
            message = "Preview only — no process was stopped."
            return
        }
        guard stopState == .idle else { return }
        beginQuit(branch.asProcessGroup, branch: branch)
    }

    func confirmPendingQuit() {
        guard let group = pendingQuitGroup else { return }
        pendingQuitGroup = nil
        beginQuit(group)
    }

    func cancelPendingQuit() {
        pendingQuitGroup = nil
    }

    private func beginQuit(
        _ group: ProcessGroup,
        branch: ProcessBranch? = nil
    ) {

        let plan =
            branch.map { terminationPolicy.plan(for: $0) }
            ?? terminationPolicy.plan(for: group)
        guard plan.capability == .allowed else {
            if case let .protected(reason) = plan.capability {
                message = reason
            }
            return
        }

        stopState = .quitting(group.id)
        recoveryAssessment = nil
        resolvingGroup = group
        resolutionOriginalGroup = group
        resolutionBranch = branch
        resolutionIncident =
            branch.flatMap { selected in
                incidents.first { $0.id == selected.id.workloadID }
            } ?? incidents.first { $0.id == group.id }
        if let branch,
            let workload = self.group(with: branch.id.workloadID)
        {
            resolutionPreexistingBranchIDs = Set(
                branchResolver.visibleBranches(in: workload)
                    .filter {
                        $0.id != branch.id
                            && ProcessBranchFingerprint(branch: $0)
                                == ProcessBranchFingerprint(branch: branch)
                    }
                    .map(\.id)
            )
        } else {
            resolutionPreexistingBranchIDs = []
        }
        let fingerprint = WorkloadFingerprint(group: group)
        resolutionPreexistingMatchingGroupIDs = Set(
            latestGroups
                .filter {
                    $0.id != group.id
                        && WorkloadFingerprint(group: $0) == fingerprint
                }
                .map(\.id)
        )
        resolutionStartedAt = Date()
        message = nil
        pendingForceName = nil
        pendingForcePlan = nil
        pendingForceGroup = nil
        let verificationDelay =
            currentPolicies.monitoring.recoveryVerificationDuration

        Task {
            let signalResult: TerminationResult?

            if branch == nil,
                case .application = group.kind,
                let application = NSRunningApplication(
                    processIdentifier: group.id.rootPID
                )
            {
                _ = application.terminate()
                signalResult = nil
            } else {
                signalResult = await terminator.terminate(plan, mode: .graceful)
            }

            try? await Task.sleep(for: .seconds(verificationDelay))
            await refresh()

            let assessment = assessRecovery(
                original: group,
                branch: branch,
                verificationDuration: resolutionStartedAt.map {
                    Date().timeIntervalSince($0)
                } ?? verificationDelay
            )
            await applyRecoveryAssessment(assessment)

            switch assessment {
            case let .partial(_, remaining):
                if let refreshedGroup = refreshedGroup(
                    from: group,
                    keeping: remaining
                ) {
                    let refreshedPlan = terminationPolicy.plan(for: refreshedGroup)
                    if refreshedPlan.capability == .allowed,
                        !refreshedPlan.targets.isEmpty
                    {
                        pendingForcePlan = refreshedPlan
                        pendingForceGroup = refreshedGroup
                        pendingForceName = group.displayName
                        stopState = .forceAvailable(group.id)
                    } else {
                        stopState = .idle
                        message = "The remaining process became protected and was not stopped."
                    }
                } else {
                    stopState = .idle
                    message = "The remaining processes could not be verified."
                }

            case .recovered:
                stopState = .idle
                if let signalResult, !signalResult.failures.isEmpty {
                    message =
                        "Quit completed with \(signalResult.failures.count) warning\(signalResult.failures.count == 1 ? "" : "s")."
                }

            case .restarted:
                stopState = .idle
            }
        }
    }

    func requestForceQuit(_ id: ProcessGroupID) {
        guard stopState == .forceAvailable(id) else { return }
        pendingForceQuitConfirmationID = id
    }

    func confirmPendingForceQuit() {
        guard let id = pendingForceQuitConfirmationID else { return }
        pendingForceQuitConfirmationID = nil
        performForceQuit(id)
    }

    func cancelPendingForceQuitConfirmation() {
        pendingForceQuitConfirmationID = nil
    }

    private func performForceQuit(_ id: ProcessGroupID) {
        guard actionsEnabled else {
            message = "Preview only — no process was stopped."
            return
        }
        guard stopState == .forceAvailable(id),
            let oldPlan = pendingForcePlan,
            let oldGroup = pendingForceGroup,
            let refreshedGroup = refreshedGroup(
                from: oldGroup,
                keeping: oldPlan.targets
            )
        else {
            cancelPendingForceQuit()
            return
        }

        let plan = terminationPolicy.plan(for: refreshedGroup)
        guard plan.capability == .allowed, !plan.targets.isEmpty else {
            cancelPendingForceQuit()
            message = "The remaining process became protected and was not stopped."
            return
        }

        stopState = .forceKilling(id)
        message = nil
        let displayName = pendingForceName ?? "Process family"

        Task {
            let result = await terminator.terminate(plan, mode: .force)
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
            let original = resolutionOriginalGroup ?? oldGroup
            let assessment = assessRecovery(
                original: original,
                branch: resolutionBranch,
                verificationDuration: resolutionStartedAt.map {
                    Date().timeIntervalSince($0)
                } ?? 2.6
            )
            await applyRecoveryAssessment(assessment)
            stopState = .idle
            pendingForcePlan = nil
            pendingForceGroup = nil
            pendingForceName = nil

            if case let .partial(_, remaining) = assessment {
                let count = max(remaining.count, result.failures.count)
                message = "\(count) process\(count == 1 ? "" : "es") could not be stopped."
            } else if !result.failures.isEmpty {
                message =
                    "\(displayName) stopped with \(result.failures.count) warning\(result.failures.count == 1 ? "" : "s")."
            }
        }
    }

    func dismissMessage() {
        if case .forceAvailable = stopState { return }
        message = nil
    }

    func dismissRecovery() {
        guard stopState == .idle else { return }
        recoveryAssessment = nil
        resolvingGroup = nil
        resolutionOriginalGroup = nil
        resolutionBranch = nil
        resolutionPreexistingBranchIDs = []
        resolutionIncident = nil
        resolutionPreexistingMatchingGroupIDs = []
        resolutionStartedAt = nil
        message = nil
        recoveryCollapseTask?.cancel()
        recoveryCollapseTask = nil
    }

    func cancelPendingForceQuit() {
        guard case .forceAvailable = stopState else { return }
        pendingForceQuitConfirmationID = nil
        stopState = .idle
        pendingForcePlan = nil
        pendingForceGroup = nil
        pendingForceName = nil
        recoveryAssessment = nil
        resolvingGroup = nil
        resolutionOriginalGroup = nil
        resolutionBranch = nil
        resolutionPreexistingBranchIDs = []
        resolutionIncident = nil
        resolutionPreexistingMatchingGroupIDs = []
        resolutionStartedAt = nil
        message = "Force quit cancelled. Some processes are still running."
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func updatePreferences(
        _ update: (inout UnhogPreferences) -> Void
    ) {
        let notificationsWereEnabled =
            preferences.notifications.isEnabled
        var updated = preferences
        update(&updated)
        preferences = updated
        preferencesRepository.save(updated)
        detector = ResourcePressureDetector(
            thresholds: currentPolicies.monitoring.thresholds
        )

        if !notificationsWereEnabled
            && updated.notifications.isEnabled
        {
            Task {
                notificationsDenied =
                    !(await notifications.requestPermission())
            }
        } else if !updated.notifications.isEnabled {
            notificationsDenied = false
        }
    }

    func setStartsAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            updatePreferences {
                $0.general.startsAtLogin = isEnabled
            }
        } catch {
            message = "Unhog could not update its login setting."
        }
    }

    func openNotificationSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshNotificationAuthorization() async {
        notificationsDenied =
            await notifications.permissionIsDenied()
    }

    func resetMonitoringPreferences() {
        updatePreferences {
            $0.monitoring = UnhogPreferences.recommended.monitoring
        }
    }

    func setClaudeKeychainAccess(_ access: ClaudeKeychainAccess) {
        updatePreferences {
            $0.general.claudeKeychainAccess = access
        }
    }

    func copyDiagnostics() {
        let policy = currentPolicies.monitoring
        let text = """
            Unhog diagnostics
            Sensitivity: \(preferences.monitoring.sensitivity.rawValue)
            Sampling: \(policy.pressureSamplingInterval)-\(policy.calmSamplingInterval) seconds
            Visible workloads: \(groups.count)
            Active incidents: \(incidents.count)
            Installed memory: \(installedMemoryBytes) bytes
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Redacted diagnostics copied."
    }

    func pauseMonitoring(for duration: TimeInterval?) {
        monitoringPausedUntil =
            duration.map {
                Date().addingTimeInterval($0)
            } ?? .distantFuture
        incidents = []
        notifiedIncidentIDs = []
    }

    func resumeMonitoring() {
        monitoringPausedUntil = nil
    }

    func muteAlerts(for group: ProcessGroup) {
        let identity = MutedWorkload(group: group)
        let muted = MutedWorkload(
            id: identity.id,
            displayName: preferences.safety.showsProjectNames
                ? identity.displayName
                : group.displayName
        )
        updatePreferences {
            if !$0.monitoring.mutedWorkloads.contains(where: {
                $0.id == muted.id
            }) {
                $0.monitoring.mutedWorkloads.append(muted)
            }
        }
        incidents.removeAll {
            MutedWorkload(group: $0.group).id == muted.id
        }
    }

    func isMuted(_ group: ProcessGroup) -> Bool {
        let id = MutedWorkload(group: group).id
        return preferences.monitoring.mutedWorkloads.contains {
            $0.id == id
        }
    }

    func toggleMuteAlerts(for group: ProcessGroup) {
        let id = MutedWorkload(group: group).id
        if isMuted(group) {
            unmuteAlerts(id)
        } else {
            muteAlerts(for: group)
        }
    }

    func unmuteAlerts(_ id: String) {
        updatePreferences {
            $0.monitoring.mutedWorkloads.removeAll { $0.id == id }
        }
    }

    private func refresh() async {
        let samples = await monitor.sample()
        let userSamples = samples.filter {
            $0.ownerUID == currentUID && $0.identity.pid != appPID
        }
        let allGroups = grouper.groups(from: userSamples)
        let monitoringPolicy = currentPolicies.monitoring
        let detectedIncidents = detector.evaluate(allGroups)
        let alertsAllowed =
            monitoringPolicy.alertScope == .always
            || PowerSource.isUsingBattery
        let newIncidents =
            alertsAllowed
            ? detectedIncidents.filter {
                !monitoringPolicy.mutedWorkloadIDs.contains(
                    MutedWorkload(group: $0.group).id
                )
            }
            : []
        let memoryIsGrowing = allGroups.contains { group in
            guard let previous = previousGroupMemory[group.id] else {
                return false
            }
            return group.memoryBytes > previous + 100_000_000
        }

        sampleCount += 1
        isPreparing = sampleCount < 2
        latestGroups = allGroups
        latestProcessIdentities = Set(samples.map(\.identity))
        previousGroupMemory = Dictionary(
            uniqueKeysWithValues: allGroups.map { ($0.id, $0.memoryBytes) }
        )
        pressureIsRising =
            !newIncidents.isEmpty
            || (preferences.monitoring.watchesMemory
                && memoryIsGrowing)
            || (preferences.monitoring.watchesCPU
                && allGroups.contains { $0.cpuPercent >= 100 })
        let incidentIDs = Set(newIncidents.map(\.id))
        let visibleGroups =
            allGroups
            .filter { $0.cpuPercent >= 0.5 || $0.memoryBytes >= 30_000_000 }
        for group in visibleGroups.sorted(by: {
            $0.memoryBytes > $1.memoryBytes
        }) {
            let fingerprint = WorkloadFingerprint(group: group)
            if stableGroupOrder[fingerprint] == nil {
                stableGroupOrder[fingerprint] = nextStableGroupOrder
                nextStableGroupOrder += 1
            }
        }
        groups = Array(
            visibleGroups
                .sorted {
                    let leftNeedsAttention = incidentIDs.contains($0.id)
                    let rightNeedsAttention = incidentIDs.contains($1.id)
                    if leftNeedsAttention != rightNeedsAttention {
                        return leftNeedsAttention
                    }
                    let leftOrder =
                        stableGroupOrder[
                            WorkloadFingerprint(group: $0)
                        ] ?? .max
                    let rightOrder =
                        stableGroupOrder[
                            WorkloadFingerprint(group: $1)
                        ] ?? .max
                    if leftOrder == rightOrder {
                        return $0.id.rootPID < $1.id.rootPID
                    }
                    return leftOrder < rightOrder
                }
                .prefix(6)
        )
        incidents = newIncidents

        let activeIDs = Set(newIncidents.map(\.id))
        notifiedIncidentIDs.formIntersection(activeIDs)

        let notificationPolicy = currentPolicies.notifications
        guard notificationPolicy.isEnabled else {
            return
        }

        for incident in newIncidents {
            if notificationPolicy.level == .importantOnly,
                incident.severity != .high
            {
                continue
            }
            guard notifiedIncidentIDs.insert(incident.id).inserted else {
                continue
            }
            await notifications.send(
                incident,
                policy: notificationPolicy
            )
        }
    }

    private func group(with id: ProcessGroupID) -> ProcessGroup? {
        latestGroups.first { $0.id == id }
            ?? incidents.first { $0.id == id }?.group
    }

    private var nextSamplingInterval: Duration {
        let policy = currentPolicies.monitoring
        return .seconds(
            pressureIsRising
                ? policy.pressureSamplingInterval
                : policy.calmSamplingInterval
        )
    }

    private func refreshAndNextInterval() async -> Duration {
        if let pausedUntil = monitoringPausedUntil {
            if pausedUntil > Date() {
                incidents = []
                return .seconds(5)
            }
            monitoringPausedUntil = nil
        }
        await refresh()
        return nextSamplingInterval
    }

    private func refreshedGroup(
        from original: ProcessGroup,
        keeping identities: [ProcessIdentity]
    ) -> ProcessGroup? {
        let wanted = Set(identities)
        let processes =
            latestGroups
            .flatMap(\.processes)
            .filter { wanted.contains($0.identity) }
        guard !processes.isEmpty else { return nil }

        return ProcessGroup(
            id: original.id,
            kind: original.kind,
            displayName: original.displayName,
            origin: original.origin,
            processes: processes
        )
    }

    private func assessRecovery(
        original: ProcessGroup,
        branch: ProcessBranch?,
        verificationDuration: TimeInterval
    ) -> RecoveryAssessment {
        guard let branch else {
            return recoveryVerifier.assess(
                original: original,
                currentGroups: latestGroups,
                currentProcessIdentities: latestProcessIdentities,
                preexistingMatchingGroupIDs:
                    resolutionPreexistingMatchingGroupIDs,
                verificationDuration: verificationDuration
            )
        }

        let assessment = branchRecoveryVerifier.assess(
            original: branch,
            currentGroups: latestGroups,
            currentProcessIdentities: latestProcessIdentities,
            preexistingMatchingBranchIDs:
                resolutionPreexistingBranchIDs,
            verificationDuration: verificationDuration
        )
        if case let .restarted(receipt) = assessment,
            let successorID = receipt.successorGroupID
        {
            resolvingGroup =
                latestGroups
                .flatMap { branchResolver.visibleBranches(in: $0) }
                .first { $0.asProcessGroup.id == successorID }?
                .asProcessGroup
        }
        return assessment
    }

    private var currentPolicies: PreferencePolicies {
        PreferencePolicies.make(
            from: preferences,
            installedMemoryBytes: installedMemoryBytes
        )
    }

    private var menuBarPhase: MenuBarPhase {
        if isMonitoringPaused {
            return .paused
        }
        if let recoveryAssessment {
            switch recoveryAssessment {
            case let .restarted(receipt):
                return .restarted(receipt)
            case let .partial(receipt, remaining):
                return .partial(receipt, remainingCount: remaining.count)
            case .recovered:
                break
            }
        }
        switch stopState {
        case .quitting, .forceKilling:
            return .stopping(resolutionIncident)
        case .forceAvailable, .idle:
            break
        }
        if let activeIncident {
            return .attention(activeIncident)
        }
        if case let .recovered(receipt)? = recoveryAssessment {
            return .recovered(receipt)
        }
        return isPreparing ? .measuring : .calm
    }

    private var menuBarLeadingGroup: ProcessGroup? {
        switch preferences.general.menuBarDisplay {
        case .topCPU:
            return groups.max { $0.cpuPercent < $1.cpuPercent }
        case .topMemory:
            return groups.max { $0.memoryBytes < $1.memoryBytes }
        case .adaptive, .iconOnly:
            return focusedGroup
        }
    }

    private func applyRecoveryAssessment(
        _ assessment: RecoveryAssessment
    ) async {
        recoveryAssessment = assessment
        recoveryCollapseTask?.cancel()

        let notificationPolicy = currentPolicies.notifications
        if notificationPolicy.isEnabled {
            switch assessment {
            case let .recovered(receipt)
            where notificationPolicy.notifiesOnRecovery:
                await notifications.sendRecovery(
                    receipt,
                    policy: notificationPolicy
                )
            case let .restarted(receipt)
            where notificationPolicy.notifiesOnRestart:
                await notifications.sendRestart(
                    receipt,
                    policy: notificationPolicy
                )
            default:
                break
            }
        }

        guard case let .recovered(receipt) = assessment else { return }
        recoveryCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                case let .recovered(currentReceipt) =
                    self?.recoveryAssessment,
                currentReceipt == receipt
            else {
                return
            }
            self?.dismissRecovery()
        }
    }

}
