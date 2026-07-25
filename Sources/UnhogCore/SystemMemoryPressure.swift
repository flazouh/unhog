import Foundation

/// A single observation of how the machine as a whole is coping with memory.
///
/// This deliberately records quantities rather than the kernel's own
/// `memorystatus_vm_pressure_level`. That level was measured reporting "normal"
/// on a Mac with 9.8 GB swapped, 5.4 GB compressed and 590 MB free: it exists to
/// warn processes moments before the kernel starts killing them, not to describe
/// a machine that merely feels unusable.
public struct SystemMemoryReading: Hashable, Sendable {
    public let installedBytes: UInt64
    public let freeBytes: UInt64
    /// What a new allocation could actually have without anything being swapped:
    /// free pages plus the inactive and purgeable ones the kernel would reclaim
    /// on demand. Free pages alone are near zero on any Mac that has been awake a
    /// while, because unused memory is filled with cache on purpose, so reporting
    /// them as the headroom figure reads as an emergency during normal use.
    public let availableBytes: UInt64
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let cumulativePageOuts: UInt64
    public let takenAt: Date

    public init(
        installedBytes: UInt64,
        freeBytes: UInt64,
        availableBytes: UInt64? = nil,
        compressedBytes: UInt64,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        cumulativePageOuts: UInt64,
        takenAt: Date
    ) {
        self.installedBytes = installedBytes
        self.freeBytes = freeBytes
        self.availableBytes = max(availableBytes ?? freeBytes, freeBytes)
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.cumulativePageOuts = cumulativePageOuts
        self.takenAt = takenAt
    }

    public var swapShare: Double {
        share(of: swapUsedBytes)
    }

    public var compressedShare: Double {
        share(of: compressedBytes)
    }

    private func share(of bytes: UInt64) -> Double {
        guard installedBytes > 0 else { return 0 }
        return Double(bytes) / Double(installedBytes)
    }
}

public enum SystemPressureLevel: Int, Comparable, Sendable {
    case normal = 0
    case elevated = 1
    case critical = 2

    public static func < (
        lhs: SystemPressureLevel,
        rhs: SystemPressureLevel
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SystemPressureThresholds: Hashable, Sendable {
    public var elevatedSwapShare: Double
    public var criticalSwapShare: Double
    public var elevatedCompressedShare: Double
    public var criticalCompressedShare: Double
    /// The rate at which paging is the reason the machine feels slow.
    ///
    /// This was once set to 1, which is indistinguishable from idle: macOS pages
    /// out a handful of pages a second as ordinary housekeeping, so the alert
    /// fired on a Mac with half its RAM free and reported it as swapping
    /// constantly. A Mac genuinely thrashing pages out in the thousands.
    public var activePageOutsPerSecond: Double
    /// Enough paging to be worth naming, but not enough to blame.
    public var noticeablePageOutsPerSecond: Double
    public var sustainedFor: TimeInterval

    public init(
        elevatedSwapShare: Double = 0.10,
        criticalSwapShare: Double = 0.25,
        elevatedCompressedShare: Double = 0.15,
        criticalCompressedShare: Double = 0.30,
        activePageOutsPerSecond: Double = 100,
        noticeablePageOutsPerSecond: Double = 10,
        sustainedFor: TimeInterval = 20
    ) {
        self.elevatedSwapShare = elevatedSwapShare
        self.criticalSwapShare = criticalSwapShare
        self.elevatedCompressedShare = elevatedCompressedShare
        self.criticalCompressedShare = criticalCompressedShare
        self.activePageOutsPerSecond = activePageOutsPerSecond
        self.noticeablePageOutsPerSecond = noticeablePageOutsPerSecond
        self.sustainedFor = sustainedFor
    }
}

public struct SystemPressure: Hashable, Sendable {
    public let level: SystemPressureLevel
    public let swapUsedBytes: UInt64
    public let compressedBytes: UInt64
    public let freeBytes: UInt64
    public let pageOutsPerSecond: Double
    public let beganAt: Date
    public let duration: TimeInterval
    public let summary: String
    public let detail: String

    public init(
        level: SystemPressureLevel,
        swapUsedBytes: UInt64,
        compressedBytes: UInt64,
        freeBytes: UInt64,
        pageOutsPerSecond: Double,
        beganAt: Date,
        duration: TimeInterval,
        summary: String,
        detail: String
    ) {
        self.level = level
        self.swapUsedBytes = swapUsedBytes
        self.compressedBytes = compressedBytes
        self.freeBytes = freeBytes
        self.pageOutsPerSecond = pageOutsPerSecond
        self.beganAt = beganAt
        self.duration = duration
        self.summary = summary
        self.detail = detail
    }
}

/// Turns a stream of readings into a verdict about the machine itself, for the
/// case no per-process threshold can catch: memory exhausted by the sum of
/// everything running, with no single application worth blaming.
public struct SystemPressureDetector: Sendable {
    public var thresholds: SystemPressureThresholds
    private var previous: SystemMemoryReading?
    private var pressureBeganAt: Date?

    public init(thresholds: SystemPressureThresholds = .init()) {
        self.thresholds = thresholds
    }

    public mutating func evaluate(
        _ reading: SystemMemoryReading
    ) -> SystemPressure? {
        let rate = pageOutsPerSecond(for: reading)
        defer { previous = reading }

        let level = level(for: reading, pageOutsPerSecond: rate)
        guard level > .normal else {
            pressureBeganAt = nil
            return nil
        }

        let beganAt = pressureBeganAt ?? reading.takenAt
        pressureBeganAt = beganAt
        let duration = reading.takenAt.timeIntervalSince(beganAt)
        guard duration >= thresholds.sustainedFor else { return nil }

        return SystemPressure(
            level: level,
            swapUsedBytes: reading.swapUsedBytes,
            compressedBytes: reading.compressedBytes,
            freeBytes: reading.freeBytes,
            pageOutsPerSecond: rate,
            beganAt: beganAt,
            duration: duration,
            summary: summary(for: level, pageOutsPerSecond: rate),
            detail: detail(for: reading, pageOutsPerSecond: rate)
        )
    }

    /// Page-outs are reported as a running total, so a rate needs two readings.
    /// The first observation of a session therefore reports no activity, which
    /// keeps a freshly launched app from calling a quiet machine critical.
    private func pageOutsPerSecond(for reading: SystemMemoryReading) -> Double {
        guard let previous,
            reading.cumulativePageOuts >= previous.cumulativePageOuts
        else {
            return 0
        }
        let elapsed = reading.takenAt.timeIntervalSince(previous.takenAt)
        guard elapsed > 0 else { return 0 }
        let delta = reading.cumulativePageOuts - previous.cumulativePageOuts
        return Double(delta) / elapsed
    }

    /// Depth and activity answer different questions. Swap and the compressor
    /// say how deep the hole is; the page-out rate says whether anyone is still
    /// digging. Swap left over from a build that finished an hour ago is worth
    /// mentioning, but it is not why a machine feels slow right now.
    private func level(
        for reading: SystemMemoryReading,
        pageOutsPerSecond rate: Double
    ) -> SystemPressureLevel {
        let deep =
            reading.swapShare >= thresholds.criticalSwapShare
            || reading.compressedShare >= thresholds.criticalCompressedShare
        let shallow =
            reading.swapShare >= thresholds.elevatedSwapShare
            || reading.compressedShare >= thresholds.elevatedCompressedShare

        if deep, rate >= thresholds.activePageOutsPerSecond {
            return .critical
        }
        return deep || shallow ? .elevated : .normal
    }

    /// Depth without activity is history, and has to read like it. Swap left
    /// over from a build that finished an hour ago says nothing about how the
    /// machine feels now, and describing it in the present tense contradicts the
    /// free memory the user can see for themselves.
    private func summary(
        for level: SystemPressureLevel,
        pageOutsPerSecond rate: Double
    ) -> String {
        switch level {
        case .critical:
            "Your Mac is out of memory and swapping constantly."
        case .elevated where rate >= thresholds.noticeablePageOutsPerSecond:
            "Your Mac is low on memory."
        case .elevated:
            "Your Mac ran low on memory earlier."
        case .normal:
            ""
        }
    }

    private func detail(
        for reading: SystemMemoryReading,
        pageOutsPerSecond rate: Double
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory

        var parts = [
            "\(formatter.string(fromByteCount: Int64(clamping: reading.swapUsedBytes))) swap",
            "\(formatter.string(fromByteCount: Int64(clamping: reading.compressedBytes))) compressed",
        ]
        if rate >= thresholds.noticeablePageOutsPerSecond {
            parts.append("\(Int(rate.rounded())) page-outs per second")
        }
        return parts.joined(separator: ", ") + "."
    }
}
