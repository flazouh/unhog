import AppKit
import UnhogCore
import SwiftUI

@MainActor
enum PreviewSupport {
    static var store: AppStore?
    static var storageStore: StorageStore?
    static var usageStore: UsageStore?
    static var updateController: UpdateController?
    private static var window: NSWindow?

    static func applyFixtureIfRequested(to store: AppStore) {
        guard
            let state = ProcessInfo.processInfo.environment[
                "UNHOG_UI_PREVIEW_STATE"
            ]
        else {
            return
        }

        let original = developerStack(rootPID: 4_201)
        let spotify = appGroup(
            name: "Spotify",
            rootPID: 5_001,
            cpuPercent: 29,
            memoryBytes: 981_500_000
        )
        let cursor = appGroup(
            name: "Cursor",
            rootPID: 5_101,
            cpuPercent: 46,
            memoryBytes: 2_250_000_000
        )
        let incident = ResourceIncident(
            id: original.id,
            group: original,
            severity: .high,
            signal: .memory,
            beganAt: Date().addingTimeInterval(-127),
            duration: 127,
            reason: "Memory stayed unusually high."
        )
        let verifier = RecoveryVerifier()

        switch state {
        case "expanded":
            store.applyPreviewFixture(
                groups: [original, cursor, spotify],
                incidents: []
            )
            store.toggleDetails(for: original.id)

        case "calm":
            store.applyPreviewFixture(
                groups: [original, cursor, spotify],
                incidents: []
            )

        case "recovered":
            store.applyPreviewFixture(
                groups: [cursor, spotify],
                incidents: [],
                recoveryAssessment: verifier.assess(
                    original: original,
                    currentGroups: [cursor, spotify],
                    currentProcessIdentities: Set(
                        [cursor, spotify].flatMap(\.processes).map(\.identity)
                    ),
                    verificationDuration: 2.1
                )
            )

        case "restarted":
            let successor = developerStack(rootPID: 4_301)
            store.applyPreviewFixture(
                groups: [successor, cursor, spotify],
                incidents: [],
                recoveryAssessment: verifier.assess(
                    original: original,
                    currentGroups: [successor, cursor, spotify],
                    currentProcessIdentities: Set(
                        [successor, cursor, spotify]
                            .flatMap(\.processes)
                            .map(\.identity)
                    ),
                    verificationDuration: 2.1
                )
            )

        case "update":
            store.applyPreviewFixture(
                groups: [cursor, spotify],
                incidents: []
            )
            updateController?.applyPreviewState(.available(version: "0.1.7"))

        case "update-downloading":
            store.applyPreviewFixture(
                groups: [cursor, spotify],
                incidents: []
            )
            updateController?.applyPreviewState(.downloading(fraction: 0.42))

        case "update-ready":
            store.applyPreviewFixture(
                groups: [cursor, spotify],
                incidents: []
            )
            updateController?.applyPreviewState(.readyToRelaunch)

        case "pressure":
            // The machine is exhausted but no single workload is to blame, so
            // the banner carries the whole explanation.
            store.applyPreviewFixture(
                groups: [cursor, spotify],
                incidents: [],
                systemPressure: SystemPressure(
                    level: .critical,
                    swapUsedBytes: 10_670_309_376,
                    compressedBytes: 5_927_723_008,
                    freeBytes: 179_044_352,
                    // A rate the detector would now actually call critical: the
                    // fixture used to say 21, which the current thresholds treat
                    // as an idle machine.
                    pageOutsPerSecond: 640,
                    beganAt: Date().addingTimeInterval(-184),
                    duration: 184,
                    summary: "Your Mac is out of memory and swapping constantly.",
                    detail: "9,94 GB swap, 5,52 GB compressed, 640 page-outs per second."
                ),
                systemMemory: SystemMemoryReading(
                    installedBytes: 25_769_803_776,
                    freeBytes: 179_044_352,
                    availableBytes: 421_527_552,
                    compressedBytes: 5_927_723_008,
                    swapUsedBytes: 10_670_309_376,
                    swapTotalBytes: 11_811_160_064,
                    cumulativePageOuts: 851_678,
                    takenAt: Date()
                )
            )

        case "partial":
            let remaining = ProcessGroup(
                id: original.id,
                kind: original.kind,
                displayName: original.displayName,
                origin: original.origin,
                processes: [original.processes[0]]
            )
            store.applyPreviewFixture(
                groups: [remaining, cursor, spotify],
                incidents: [],
                recoveryAssessment: verifier.assess(
                    original: original,
                    currentGroups: [remaining, cursor, spotify],
                    currentProcessIdentities: Set(
                        [remaining, cursor, spotify]
                            .flatMap(\.processes)
                            .map(\.identity)
                    ),
                    verificationDuration: 2.1
                ),
                resolvingGroup: remaining,
                stopState: .forceAvailable(original.id)
            )

        default:
            store.applyPreviewFixture(
                groups: [original, cursor, spotify],
                incidents: [incident]
            )
        }
    }

    static func present() {
        guard window == nil,
            let store,
            let storageStore,
            let usageStore,
            let updateController
        else { return }

        let controller = NSHostingController(
            rootView: PopoverView(
                store: store,
                storageStore: storageStore,
                usageStore: usageStore,
                updateController: updateController
            )
        )
        let contentSize = NSSize(
            width: UnhogTheme.popoverWidth,
            height: UnhogTheme.popoverHeight
        )
        let previewWindow = NSWindow(contentViewController: controller)
        previewWindow.title = "Unhog Preview"
        previewWindow.styleMask = [.titled, .closable, .fullSizeContentView]
        previewWindow.titlebarAppearsTransparent = true
        previewWindow.isMovableByWindowBackground = true
        previewWindow.setContentSize(contentSize)
        previewWindow.center()
        previewWindow.makeKeyAndOrderFront(nil)
        window = previewWindow
    }

    private static func developerStack(rootPID: Int32) -> ProcessGroup {
        let workingDirectory =
            "/Users/example/Projects/sample-app"
        let processes = [
            ProcessSample(
                identity: ProcessIdentity(
                    pid: rootPID,
                    startedAtMicroseconds: 100
                ),
                parentPID: 1,
                ownerUID: getuid(),
                name: "bun",
                executablePath: "/Users/example/.bun/bin/bun",
                workingDirectory: workingDirectory,
                cpuPercent: 24,
                memoryBytes: 720_000_000
            ),
            ProcessSample(
                identity: ProcessIdentity(
                    pid: rootPID + 1,
                    startedAtMicroseconds: 101
                ),
                parentPID: rootPID,
                ownerUID: getuid(),
                name: "esbuild",
                executablePath: "/node_modules/esbuild/bin/esbuild",
                workingDirectory: workingDirectory,
                cpuPercent: 73,
                memoryBytes: 3_140_000_000
            ),
        ]
        return ProcessGroup(
            id: ProcessGroupID(
                kind: .application("bun"),
                rootPID: rootPID
            ),
            kind: .application("bun"),
            displayName: "bun",
            origin: nil,
            processes: processes
        )
    }

    private static func appGroup(
        name: String,
        rootPID: Int32,
        cpuPercent: Double,
        memoryBytes: UInt64
    ) -> ProcessGroup {
        let sample = ProcessSample(
            identity: ProcessIdentity(
                pid: rootPID,
                startedAtMicroseconds: 200
            ),
            parentPID: 1,
            ownerUID: getuid(),
            name: name,
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            cpuPercent: cpuPercent,
            memoryBytes: memoryBytes
        )
        return ProcessGroup(
            id: ProcessGroupID(
                kind: .application(name),
                rootPID: rootPID
            ),
            kind: .application(name),
            displayName: name,
            origin: nil,
            processes: [sample]
        )
    }
}
