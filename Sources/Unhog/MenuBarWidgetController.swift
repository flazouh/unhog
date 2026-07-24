import AppKit
import Combine
import SwiftUI
import UnhogCore

@MainActor
final class MenuBarWidgetController: NSObject, NSPopoverDelegate {
    private let store: AppStore
    private let storageStore: StorageStore
    private let usageStore: UsageStore
    private let updateController: UpdateController
    private let dismissalPolicy = MenuBarWidgetDismissalPolicy()
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength
    )
    private let popover = NSPopover()
    private var statusLabel: NSHostingView<MenuBarItemLabel>?
    private var storeObservation: AnyCancellable?
    private var applicationDeactivationObserver: NSObjectProtocol?
    private var escapeMonitor: Any?

    init(
        store: AppStore,
        storageStore: StorageStore,
        usageStore: UsageStore,
        updateController: UpdateController
    ) {
        self.store = store
        self.storageStore = storageStore
        self.usageStore = usageStore
        self.updateController = updateController
        super.init()
        configureStatusItem()
        configurePopover()
        observeStore()
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem.button else { return }
        guard popover.isShown else {
            popover.animates = !store.shouldReduceMotion
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
            NSApp.activate(ignoringOtherApps: true)
            installEventMonitors()
            return
        }
        closePopover()
    }

    func popoverDidClose(_ notification: Notification) {
        removeEventMonitors()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])

        let label = MenuBarItemLabel(store: store)
        let hostingView = PassthroughHostingView(rootView: label)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(
                equalTo: button.centerXAnchor
            ),
            hostingView.centerYAnchor.constraint(
                equalTo: button.centerYAnchor
            ),
        ])
        statusLabel = hostingView
        refreshStatusItem()
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentSize = NSSize(
            width: UnhogTheme.popoverWidth,
            height: UnhogTheme.popoverHeight
        )
        popover.contentViewController = NSHostingController(
            rootView: MenuBarWidgetRoot(
                store: store,
                storageStore: storageStore,
                usageStore: usageStore,
                updateController: updateController
            )
        )
    }

    private func observeStore() {
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshStatusItem()
            }
        }
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button,
            let statusLabel
        else {
            return
        }
        let presentation = store.menuBarPresentation
        button.toolTip = presentation.accessibilityLabel
        button.setAccessibilityLabel(presentation.accessibilityLabel)

        statusLabel.rootView = MenuBarItemLabel(store: store)
        statusLabel.layoutSubtreeIfNeeded()
        statusItem.length = ceil(
            max(24, statusLabel.fittingSize.width + 8)
        )
    }

    private func installEventMonitors() {
        removeEventMonitors()

        applicationDeactivationObserver = NotificationCenter.default
            .addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                        self.dismissalPolicy.shouldDismiss(
                            for: .outsideApplication
                        )
                    else {
                        return
                    }
                    self.closePopover()
                }
            }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                guard let self,
                    event.window
                        === self.popover.contentViewController?
                        .view.window,
                    self.dismissalPolicy.shouldDismiss(for: .escape)
                else {
                    return
                }
                self.closePopover()
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let applicationDeactivationObserver {
            NotificationCenter.default.removeObserver(
                applicationDeactivationObserver
            )
            self.applicationDeactivationObserver = nil
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        removeEventMonitors()
    }
}

@MainActor
private struct MenuBarWidgetRoot: View {
    @ObservedObject var store: AppStore
    @ObservedObject var storageStore: StorageStore
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var updateController: UpdateController

    var body: some View {
        PopoverView(
            store: store,
            storageStore: storageStore,
            usageStore: usageStore,
            updateController: updateController
        )
        .environment(
            \.unhogReduceMotion,
            store.shouldReduceMotion
        )
    }
}

@MainActor
private struct MenuBarItemLabel: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let presentation = store.menuBarPresentation
        HStack(spacing: 4) {
            if presentation.symbolName == "circle" {
                UnhogMenuBarMark()
            } else {
                Image(systemName: presentation.symbolName)
            }
            if presentation.compactLabel != nil,
                let signature = store.menuBarDrainSignature
            {
                MenuBarSignatureView(signature: signature)
            } else if let label = presentation.compactLabel {
                Text(label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

@MainActor
private final class PassthroughHostingView<Content: View>:
    NSHostingView<Content>
{
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
