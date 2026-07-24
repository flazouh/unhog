import AppKit
import SwiftUI

@main
struct UnhogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRoot(
                store: appDelegate.store,
                updateController: appDelegate.updateController
            )
        }
    }
}

@MainActor
private struct SettingsRoot: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updateController: UpdateController

    var body: some View {
        SettingsView(
            store: store,
            updateController: updateController
        )
        .environment(
            \.unhogReduceMotion,
            store.shouldReduceMotion
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: AppStore
    let storageStore: StorageStore
    let usageStore: UsageStore
    let updateController: UpdateController
    private var menuBarWidgetController: MenuBarWidgetController?
    private var updateCheckTask: Task<Void, Never>?

    override init() {
        let showsPreviewWindow =
            ProcessInfo.processInfo.environment["UNHOG_UI_PREVIEW"] == "1"
        store = AppStore(actionsEnabled: !showsPreviewWindow)
        storageStore = StorageStore()
        usageStore = UsageStore(
            keychainAccess: store.preferences.general.claudeKeychainAccess
        )
        updateController = UpdateController()
        super.init()

        usageStore.persistKeychainAccess = { [weak store] access in
            store?.setClaudeKeychainAccess(access)
        }

        if showsPreviewWindow {
            PreviewSupport.store = store
            PreviewSupport.storageStore = storageStore
            PreviewSupport.usageStore = usageStore
            PreviewSupport.updateController = updateController
            PreviewSupport.applyFixtureIfRequested(to: store)
        }
        if ProcessInfo.processInfo.environment[
            "UNHOG_UI_PREVIEW_STATE"
        ] == nil {
            store.start()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showsPreviewWindow =
            ProcessInfo.processInfo.environment["UNHOG_UI_PREVIEW"] == "1"
        NSApp.setActivationPolicy(showsPreviewWindow ? .regular : .accessory)
        if showsPreviewWindow {
            NSApp.activate(ignoringOtherApps: true)
            PreviewSupport.present()
        } else {
            menuBarWidgetController = MenuBarWidgetController(
                store: store,
                storageStore: storageStore,
                usageStore: usageStore,
                updateController: updateController
            )
            updateCheckTask = Task { [weak self] in
                // Unhog is left running for weeks, so checking only at launch
                // meant the banner could never appear during the session that
                // needed it. The daily budget is enforced inside the check, so
                // this loop only decides how often to reconsider.
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.updateController.checkForUpdatesIfNeeded(
                        automaticallyCheck: self.store.preferences.general
                            .automaticallyCheckForUpdates
                    )
                    try? await Task.sleep(for: .seconds(3_600))
                }
            }
        }
    }
}
