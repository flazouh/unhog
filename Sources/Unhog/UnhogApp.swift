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
                usageStore: usageStore
            )
            Task {
                await updateController.checkForUpdatesIfNeeded(
                    automaticallyCheck: store.preferences.general
                        .automaticallyCheckForUpdates
                )
            }
        }
    }
}
