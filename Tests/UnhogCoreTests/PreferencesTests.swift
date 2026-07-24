import Foundation
import Testing
@testable import UnhogCore

@Suite("Unhog preferences")
struct PreferencesTests {
    @Test("Recommended preferences compile to balanced low-overhead policies")
    func recommendedPolicies() {
        let preferences = UnhogPreferences.recommended

        let policies = PreferencePolicies.make(
            from: preferences,
            installedMemoryBytes: 24_000_000_000
        )

        #expect(preferences.monitoring.sensitivity == .balanced)
        #expect(preferences.general.menuBarDisplay == .adaptive)
        #expect(policies.monitoring.thresholds.elevatedCPUPercent == 150)
        #expect(policies.monitoring.thresholds.elevatedMemoryBytes == 4_800_000_000)
        #expect(policies.monitoring.calmSamplingInterval == 5)
        #expect(policies.monitoring.pressureSamplingInterval == 2)
        #expect(policies.monitoring.alertScope == .always)
        #expect(policies.monitoring.recoveryVerificationDuration == 2)
        #expect(policies.monitoring.mutedWorkloadIDs.isEmpty)
        #expect(policies.notifications.isEnabled)
        #expect(!policies.notifications.playsSound)
    }

    @Test("Muted workloads and recovery timing compile into monitoring policy")
    func compilesWorkloadControls() {
        var preferences = UnhogPreferences.recommended
        preferences.monitoring.alertScope = .batteryOnly
        preferences.monitoring.recoveryVerificationDuration = 8
        preferences.monitoring.mutedWorkloads = [
            MutedWorkload(id: "bun|project", displayName: "bun")
        ]

        let policy = PreferencePolicies.make(
            from: preferences,
            installedMemoryBytes: 24_000_000_000
        ).monitoring

        #expect(policy.alertScope == .batteryOnly)
        #expect(policy.recoveryVerificationDuration == 8)
        #expect(policy.mutedWorkloadIDs == ["bun|project"])
    }

    @Test("Sensitivity presets change thresholds and duration together")
    func sensitivityPresets() {
        var quiet = UnhogPreferences.recommended
        quiet.monitoring.sensitivity = .quiet
        var early = UnhogPreferences.recommended
        early.monitoring.sensitivity = .early

        let quietPolicy = PreferencePolicies.make(
            from: quiet,
            installedMemoryBytes: 24_000_000_000
        ).monitoring
        let earlyPolicy = PreferencePolicies.make(
            from: early,
            installedMemoryBytes: 24_000_000_000
        ).monitoring

        #expect(quietPolicy.thresholds.elevatedCPUPercent == 200)
        #expect(quietPolicy.thresholds.sustainedFor == 30)
        #expect(earlyPolicy.thresholds.elevatedCPUPercent == 100)
        #expect(earlyPolicy.thresholds.sustainedFor == 10)
    }

    @Test("Custom values are clamped to safe sampling and threshold limits")
    func clampsCustomValues() {
        var preferences = UnhogPreferences.recommended
        preferences.monitoring.sensitivity = .custom
        preferences.monitoring.samplingProfile = .responsive
        preferences.monitoring.customCPUThresholdCores = 0
        preferences.monitoring.customMemoryShare = 2
        preferences.monitoring.customSustainedDuration = 0

        let policy = PreferencePolicies.make(
            from: preferences,
            installedMemoryBytes: 20_000_000_000
        ).monitoring

        #expect(policy.thresholds.elevatedCPUPercent == 50)
        #expect(policy.thresholds.elevatedMemoryBytes == 16_000_000_000)
        #expect(policy.thresholds.sustainedFor == 5)
        #expect(policy.pressureSamplingInterval == 1)
    }

    /// Preferences are persisted as JSON and decoded with `try?`, so a key added
    /// in a later version must not make the whole blob undecodable. If it does,
    /// upgrading silently throws away every setting the user chose.
    @Test("Settings saved by an older version survive an upgrade")
    func toleratesPreferencesWrittenBeforeNewKeysExisted() throws {
        let suiteName = "UnhogPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Exactly what 0.1.1 wrote: no automaticallyCheckForUpdates key.
        let legacy = """
            {
              "general": {
                "startsAtLogin": true,
                "menuBarDisplay": "iconOnly",
                "motion": "followSystem"
              },
              "monitoring": {
                "sensitivity": "quiet",
                "samplingProfile": "adaptive",
                "watchesCPU": true,
                "watchesMemory": true,
                "alertScope": "always",
                "mutedWorkloads": [],
                "recoveryVerificationDuration": 2,
                "customCPUThresholdCores": 1.5,
                "customMemoryShare": 0.2,
                "customSustainedDuration": 20
              },
              "notifications": {
                "isEnabled": true,
                "level": "all",
                "notifiesOnRestart": true,
                "notifiesOnRecovery": true,
                "playsSound": false,
                "showsWorkloadNames": true
              },
              "safety": {
                "confirmsWholeStackStop": true,
                "showsProjectNames": true
              }
            }
            """
        defaults.set(Data(legacy.utf8), forKey: "preferences")

        let preferences = UserDefaultsPreferencesRepository(
            defaults: defaults,
            storageKey: "preferences"
        ).load()

        #expect(preferences.general.startsAtLogin)
        #expect(preferences.general.menuBarDisplay == .iconOnly)
        #expect(preferences.monitoring.sensitivity == .quiet)
        // Absent keys fall back to their current default.
        #expect(preferences.general.automaticallyCheckForUpdates)
    }

    @Test("Legacy notification choice migrates into typed preferences")
    func migratesNotificationChoice() throws {
        let suiteName = "UnhogPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "notificationsEnabled")
        let repository = UserDefaultsPreferencesRepository(
            defaults: defaults,
            storageKey: "preferences"
        )

        let preferences = repository.load()

        #expect(!preferences.notifications.isEnabled)
        #expect(defaults.data(forKey: "preferences") != nil)
    }
}
