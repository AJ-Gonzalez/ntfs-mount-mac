import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "NTFSMountStatusItem"
        item.isVisible = true
        item.button?.title = "NTFS"
        item.button?.imagePosition = .noImage
        item.button?.toolTip = "NTFS Mount"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let controller = NSHostingController(
            rootView: ContentView().environmentObject(model)
        )
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 372, height: 620)
        self.popover = popover

        model.$volumes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showPopover()
            }
        }
    }

    private func icon() -> NSImage? {
        let image = NSImage(systemSymbolName: model.menuBarSymbol, accessibilityDescription: "NTFS Mount")
        image?.isTemplate = true
        return image
    }

    private func updateIcon() {
        statusItem?.button?.image = icon()
    }

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let popover, let button = statusItem?.button else { return }
        model.refresh(forceHelperCheck: true)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
