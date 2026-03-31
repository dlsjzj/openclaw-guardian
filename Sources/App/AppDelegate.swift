import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var monitorService: MonitorService!
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitorService = MonitorService()

        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "OpenClaw Guardian")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Build popover content
        let contentView = StatusBarView(monitorService: monitorService)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        // Start monitoring
        monitorService.start()

        // Set initial status to healthy immediately (we just checked it above)
        monitorService.status = .healthy
        updateStatusIcon(.healthy)

        // Observe status changes → update icon color
        monitorService.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.updateStatusIcon(status)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorService.stop()
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(button)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    func updateStatusIcon(_ status: HealthStatus) {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let color: NSColor

        switch status {
        case .healthy:
            symbolName = "checkmark.shield.fill"
            color = .systemGreen
        case .warning:
            symbolName = "exclamationmark.shield.fill"
            color = .systemYellow
        case .critical:
            symbolName = "xmark.shield.fill"
            color = .systemRed
        case .unknown:
            symbolName = "questionmark.circle"
            color = .systemGray
        }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "OpenClaw Guardian") {
            let coloredImage = image.withSymbolConfiguration(config)
            button.image = coloredImage
            button.contentTintColor = color
        }
    }
}
