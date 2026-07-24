import Foundation

public enum MenuBarDisplayMode: String, Codable, CaseIterable, Sendable {
    case adaptive
    case iconOnly
    case topCPU
    case topMemory
}

public enum MotionPreference: String, Codable, CaseIterable, Sendable {
    case followSystem
    case reduced
}

/// Whether Unhog may read the OAuth token that Claude Code keeps in the login
/// keychain. That item belongs to Claude Code, so macOS asks the user to approve
/// every read by a different app. Unhog therefore explains itself first, asks
/// once, and remembers a refusal instead of prompting on every refresh.
public enum ClaudeKeychainAccess: String, Codable, CaseIterable, Sendable {
    case unasked
    case allowed
    case declined
}

public enum AlertSensitivity: String, Codable, CaseIterable, Sendable {
    case quiet
    case balanced
    case early
    case custom
}

public enum SamplingProfile: String, Codable, CaseIterable, Sendable {
    case efficient
    case adaptive
    case responsive
}

public enum AlertScope: String, Codable, CaseIterable, Sendable {
    case always
    case batteryOnly
}

public struct MutedWorkload: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public init(group: ProcessGroup) {
        let fingerprint = WorkloadFingerprint(group: group)
        self.id = [
            fingerprint.executableName,
            fingerprint.projectPath ?? "",
        ].joined(separator: "|")
        self.displayName = group.contextLabel ?? group.displayName
    }
}

public enum NotificationLevel: String, Codable, CaseIterable, Sendable {
    case needsAttention
    case importantOnly
}

public struct GeneralPreferences: Codable, Equatable, Sendable {
    public var startsAtLogin: Bool
    public var menuBarDisplay: MenuBarDisplayMode
    public var motion: MotionPreference
    public var automaticallyCheckForUpdates: Bool
    public var claudeKeychainAccess: ClaudeKeychainAccess

    public init(
        startsAtLogin: Bool = false,
        menuBarDisplay: MenuBarDisplayMode = .adaptive,
        motion: MotionPreference = .followSystem,
        automaticallyCheckForUpdates: Bool = true,
        claudeKeychainAccess: ClaudeKeychainAccess = .unasked
    ) {
        self.startsAtLogin = startsAtLogin
        self.menuBarDisplay = menuBarDisplay
        self.motion = motion
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
        self.claudeKeychainAccess = claudeKeychainAccess
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GeneralPreferences()
        startsAtLogin =
            container.lenient(Bool.self, .startsAtLogin)
            ?? fallback.startsAtLogin
        menuBarDisplay =
            container.lenient(MenuBarDisplayMode.self, .menuBarDisplay)
            ?? fallback.menuBarDisplay
        motion =
            container.lenient(MotionPreference.self, .motion)
            ?? fallback.motion
        automaticallyCheckForUpdates =
            container.lenient(Bool.self, .automaticallyCheckForUpdates)
            ?? fallback.automaticallyCheckForUpdates
        claudeKeychainAccess =
            container.lenient(
                ClaudeKeychainAccess.self,
                .claudeKeychainAccess
            ) ?? fallback.claudeKeychainAccess
    }
}

/// Preferences are stored as one JSON blob and read back with `try?`, so a single
/// unreadable key would discard every setting the user has chosen. Reading each
/// key independently means a file written by an older or newer version keeps
/// whatever it does contain and only the unknown parts fall back to defaults.
extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

public struct MonitoringPreferences: Codable, Equatable, Sendable {
    public var sensitivity: AlertSensitivity
    public var samplingProfile: SamplingProfile
    public var watchesCPU: Bool
    public var watchesMemory: Bool
    public var alertScope: AlertScope
    public var mutedWorkloads: [MutedWorkload]
    public var recoveryVerificationDuration: TimeInterval
    public var customCPUThresholdCores: Double
    public var customMemoryShare: Double
    public var customSustainedDuration: TimeInterval

    public init(
        sensitivity: AlertSensitivity = .balanced,
        samplingProfile: SamplingProfile = .adaptive,
        watchesCPU: Bool = true,
        watchesMemory: Bool = true,
        alertScope: AlertScope = .always,
        mutedWorkloads: [MutedWorkload] = [],
        recoveryVerificationDuration: TimeInterval = 2,
        customCPUThresholdCores: Double = 1.5,
        customMemoryShare: Double = 0.2,
        customSustainedDuration: TimeInterval = 20
    ) {
        self.sensitivity = sensitivity
        self.samplingProfile = samplingProfile
        self.watchesCPU = watchesCPU
        self.watchesMemory = watchesMemory
        self.alertScope = alertScope
        self.mutedWorkloads = mutedWorkloads
        self.recoveryVerificationDuration =
            recoveryVerificationDuration
        self.customCPUThresholdCores = customCPUThresholdCores
        self.customMemoryShare = customMemoryShare
        self.customSustainedDuration = customSustainedDuration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MonitoringPreferences()
        sensitivity =
            container.lenient(AlertSensitivity.self, .sensitivity)
            ?? fallback.sensitivity
        samplingProfile =
            container.lenient(SamplingProfile.self, .samplingProfile)
            ?? fallback.samplingProfile
        watchesCPU =
            container.lenient(Bool.self, .watchesCPU) ?? fallback.watchesCPU
        watchesMemory =
            container.lenient(Bool.self, .watchesMemory)
            ?? fallback.watchesMemory
        alertScope =
            container.lenient(AlertScope.self, .alertScope)
            ?? fallback.alertScope
        mutedWorkloads =
            container.lenient([MutedWorkload].self, .mutedWorkloads)
            ?? fallback.mutedWorkloads
        recoveryVerificationDuration =
            container.lenient(
                TimeInterval.self,
                .recoveryVerificationDuration
            ) ?? fallback.recoveryVerificationDuration
        customCPUThresholdCores =
            container.lenient(Double.self, .customCPUThresholdCores)
            ?? fallback.customCPUThresholdCores
        customMemoryShare =
            container.lenient(Double.self, .customMemoryShare)
            ?? fallback.customMemoryShare
        customSustainedDuration =
            container.lenient(TimeInterval.self, .customSustainedDuration)
            ?? fallback.customSustainedDuration
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var level: NotificationLevel
    public var notifiesOnRestart: Bool
    public var notifiesOnRecovery: Bool
    public var playsSound: Bool
    public var showsWorkloadNames: Bool

    public init(
        isEnabled: Bool = true,
        level: NotificationLevel = .needsAttention,
        notifiesOnRestart: Bool = true,
        notifiesOnRecovery: Bool = false,
        playsSound: Bool = false,
        showsWorkloadNames: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.level = level
        self.notifiesOnRestart = notifiesOnRestart
        self.notifiesOnRecovery = notifiesOnRecovery
        self.playsSound = playsSound
        self.showsWorkloadNames = showsWorkloadNames
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = NotificationPreferences()
        isEnabled =
            container.lenient(Bool.self, .isEnabled) ?? fallback.isEnabled
        level =
            container.lenient(NotificationLevel.self, .level)
            ?? fallback.level
        notifiesOnRestart =
            container.lenient(Bool.self, .notifiesOnRestart)
            ?? fallback.notifiesOnRestart
        notifiesOnRecovery =
            container.lenient(Bool.self, .notifiesOnRecovery)
            ?? fallback.notifiesOnRecovery
        playsSound =
            container.lenient(Bool.self, .playsSound) ?? fallback.playsSound
        showsWorkloadNames =
            container.lenient(Bool.self, .showsWorkloadNames)
            ?? fallback.showsWorkloadNames
    }
}

public struct SafetyPreferences: Codable, Equatable, Sendable {
    public var confirmsWholeStackStop: Bool
    public var showsProjectNames: Bool

    public init(
        confirmsWholeStackStop: Bool = true,
        showsProjectNames: Bool = true
    ) {
        self.confirmsWholeStackStop = confirmsWholeStackStop
        self.showsProjectNames = showsProjectNames
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SafetyPreferences()
        confirmsWholeStackStop =
            container.lenient(Bool.self, .confirmsWholeStackStop)
            ?? fallback.confirmsWholeStackStop
        showsProjectNames =
            container.lenient(Bool.self, .showsProjectNames)
            ?? fallback.showsProjectNames
    }
}

public struct UnhogPreferences: Codable, Equatable, Sendable {
    public var general: GeneralPreferences
    public var monitoring: MonitoringPreferences
    public var notifications: NotificationPreferences
    public var safety: SafetyPreferences

    public init(
        general: GeneralPreferences = .init(),
        monitoring: MonitoringPreferences = .init(),
        notifications: NotificationPreferences = .init(),
        safety: SafetyPreferences = .init()
    ) {
        self.general = general
        self.monitoring = monitoring
        self.notifications = notifications
        self.safety = safety
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        general =
            container.lenient(GeneralPreferences.self, .general)
            ?? GeneralPreferences()
        monitoring =
            container.lenient(MonitoringPreferences.self, .monitoring)
            ?? MonitoringPreferences()
        notifications =
            container.lenient(NotificationPreferences.self, .notifications)
            ?? NotificationPreferences()
        safety =
            container.lenient(SafetyPreferences.self, .safety)
            ?? SafetyPreferences()
    }

    public static let recommended = UnhogPreferences()
}

public struct MonitoringPolicy: Equatable, Sendable {
    public let thresholds: ResourceThresholds
    public let calmSamplingInterval: TimeInterval
    public let pressureSamplingInterval: TimeInterval
    public let alertScope: AlertScope
    public let mutedWorkloadIDs: Set<String>
    public let recoveryVerificationDuration: TimeInterval

    public init(
        thresholds: ResourceThresholds,
        calmSamplingInterval: TimeInterval,
        pressureSamplingInterval: TimeInterval,
        alertScope: AlertScope,
        mutedWorkloadIDs: Set<String>,
        recoveryVerificationDuration: TimeInterval
    ) {
        self.thresholds = thresholds
        self.calmSamplingInterval = calmSamplingInterval
        self.pressureSamplingInterval = pressureSamplingInterval
        self.alertScope = alertScope
        self.mutedWorkloadIDs = mutedWorkloadIDs
        self.recoveryVerificationDuration =
            recoveryVerificationDuration
    }
}

public struct MenuBarPolicy: Equatable, Sendable {
    public let displayMode: MenuBarDisplayMode
}

public struct NotificationPolicy: Equatable, Sendable {
    public let isEnabled: Bool
    public let level: NotificationLevel
    public let notifiesOnRestart: Bool
    public let notifiesOnRecovery: Bool
    public let playsSound: Bool
    public let showsWorkloadNames: Bool
}

public struct PreferencePolicies: Equatable, Sendable {
    public let monitoring: MonitoringPolicy
    public let menuBar: MenuBarPolicy
    public let notifications: NotificationPolicy

    public static func make(
        from preferences: UnhogPreferences,
        installedMemoryBytes: UInt64
    ) -> PreferencePolicies {
        let thresholds = thresholds(
            for: preferences.monitoring,
            installedMemoryBytes: installedMemoryBytes
        )
        let sampling = samplingIntervals(
            for: preferences.monitoring.samplingProfile
        )

        return PreferencePolicies(
            monitoring: MonitoringPolicy(
                thresholds: thresholds,
                calmSamplingInterval: sampling.calm,
                pressureSamplingInterval: sampling.pressure,
                alertScope: preferences.monitoring.alertScope,
                mutedWorkloadIDs: Set(
                    preferences.monitoring.mutedWorkloads.map(\.id)
                ),
                recoveryVerificationDuration: min(
                    10,
                    max(
                        2,
                        preferences.monitoring
                            .recoveryVerificationDuration
                    )
                )
            ),
            menuBar: MenuBarPolicy(
                displayMode: preferences.general.menuBarDisplay
            ),
            notifications: NotificationPolicy(
                isEnabled: preferences.notifications.isEnabled,
                level: preferences.notifications.level,
                notifiesOnRestart:
                    preferences.notifications.notifiesOnRestart,
                notifiesOnRecovery:
                    preferences.notifications.notifiesOnRecovery,
                playsSound: preferences.notifications.playsSound,
                showsWorkloadNames:
                    preferences.notifications.showsWorkloadNames
            )
        )
    }

    private static func thresholds(
        for preferences: MonitoringPreferences,
        installedMemoryBytes: UInt64
    ) -> ResourceThresholds {
        let values:
            (
                elevatedCPU: Double,
                highCPU: Double,
                elevatedMemoryShare: Double,
                highMemoryShare: Double,
                developerElevated: UInt64,
                developerHigh: UInt64,
                duration: TimeInterval
            )

        switch preferences.sensitivity {
        case .quiet:
            values = (200, 400, 0.25, 0.42, 4_000_000_000, 8_000_000_000, 30)
        case .balanced:
            values = (150, 300, 0.20, 0.35, 3_000_000_000, 6_000_000_000, 20)
        case .early:
            values = (100, 200, 0.15, 0.25, 2_000_000_000, 4_000_000_000, 10)
        case .custom:
            let cores = min(32, max(0.5, preferences.customCPUThresholdCores))
            let share = min(0.8, max(0.05, preferences.customMemoryShare))
            values = (
                cores * 100,
                min(6_400, max(cores * 200, cores * 100 + 100)),
                share,
                min(0.95, share + 0.15),
                bytes(installedMemoryBytes, share: share),
                bytes(installedMemoryBytes, share: min(0.95, share + 0.15)),
                min(120, max(5, preferences.customSustainedDuration))
            )
        }

        return ResourceThresholds(
            elevatedCPUPercent: preferences.watchesCPU
                ? values.elevatedCPU
                : .greatestFiniteMagnitude,
            highCPUPercent: preferences.watchesCPU
                ? values.highCPU
                : .greatestFiniteMagnitude,
            elevatedMemoryBytes: preferences.watchesMemory
                ? bytes(installedMemoryBytes, share: values.elevatedMemoryShare)
                : .max,
            highMemoryBytes: preferences.watchesMemory
                ? bytes(installedMemoryBytes, share: values.highMemoryShare)
                : .max,
            developerToolElevatedMemoryBytes: preferences.watchesMemory
                ? values.developerElevated
                : .max,
            developerToolHighMemoryBytes: preferences.watchesMemory
                ? values.developerHigh
                : .max,
            sustainedFor: values.duration
        )
    }

    private static func bytes(_ installed: UInt64, share: Double) -> UInt64 {
        UInt64((Double(installed) * share).rounded())
    }

    private static func samplingIntervals(
        for profile: SamplingProfile
    ) -> (calm: TimeInterval, pressure: TimeInterval) {
        switch profile {
        case .efficient:
            (8, 3)
        case .adaptive:
            (5, 2)
        case .responsive:
            (2, 1)
        }
    }
}

public final class UserDefaultsPreferencesRepository {
    private let defaults: UserDefaults
    private let storageKey: String
    private let legacyNotificationsKey = "notificationsEnabled"

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "unhog.preferences.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> UnhogPreferences {
        if let data = defaults.data(forKey: storageKey),
            let preferences = try? JSONDecoder().decode(
                UnhogPreferences.self,
                from: data
            )
        {
            return preferences
        }

        var preferences = UnhogPreferences.recommended
        if defaults.object(forKey: legacyNotificationsKey) != nil {
            preferences.notifications.isEnabled = defaults.bool(
                forKey: legacyNotificationsKey
            )
        }
        save(preferences)
        return preferences
    }

    public func save(_ preferences: UnhogPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}
