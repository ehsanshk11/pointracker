import AppKit
import PointrackerCore

/// The eye icon in the menu bar and its menu.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private unowned let app: AppController
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let cameraMenu: NSMenu
    private let speedMenu: NSMenu
    private let stateItem: NSMenuItem
    private let liveItem: NSMenuItem
    private let performanceItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let batteryItem: NSMenuItem
    private let learnItem: NSMenuItem
    private let pointerItem: NSMenuItem
    private let accessibilityItem: NSMenuItem
    private let cameraAccessItem: NSMenuItem
    private var isMenuOpen = false

    init(app: AppController) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        cameraMenu = NSMenu()
        speedMenu = NSMenu()
        stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        liveItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        performanceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "g")
        batteryItem = NSMenuItem(title: "Pause on Battery", action: #selector(toggleBattery), keyEquivalent: "")
        learnItem = NSMenuItem(title: "Learn from Clicks", action: #selector(toggleLearn), keyEquivalent: "")
        pointerItem = NSMenuItem(title: "Move Pointer with Focus", action: #selector(togglePointer), keyEquivalent: "")
        accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccessibility), keyEquivalent: "")
        cameraAccessItem = NSMenuItem(title: "Grant Camera Access…", action: #selector(grantCamera), keyEquivalent: "")
        super.init()
        build()
        refresh()
    }

    private func build() {
        stateItem.isEnabled = false
        liveItem.isEnabled = false
        performanceItem.isEnabled = false
        pauseItem.keyEquivalentModifierMask = [.command, .shift]

        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraItem.submenu = cameraMenu
        cameraMenu.delegate = self

        let speedItem = NSMenuItem(title: "Switch Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu
        for speed in SwitchSpeed.allCases {
            let config = speed.config
            let item = NSMenuItem(
                title: "\(speed.title) — \(Int(config.dwell * 1000)) ms, waits \(config.mouseHold)s after mouse",
                action: #selector(selectSpeed(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = speed.rawValue
            speedMenu.addItem(item)
        }

        let calibrateItem = NSMenuItem(title: "Calibrate…", action: #selector(calibrate), keyEquivalent: "")
        let resetItem = NSMenuItem(title: "Reset Calibration", action: #selector(resetCalibration), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "Quit Pointracker", action: #selector(quit), keyEquivalent: "q")

        for item in [pauseItem, batteryItem, learnItem, pointerItem, accessibilityItem, cameraAccessItem, calibrateItem, resetItem, quitItem] {
            item.target = self
        }

        menu.addItem(stateItem)
        menu.addItem(liveItem)
        menu.addItem(performanceItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(calibrateItem)
        menu.addItem(cameraItem)
        menu.addItem(speedItem)
        menu.addItem(.separator())
        menu.addItem(batteryItem)
        menu.addItem(learnItem)
        menu.addItem(pointerItem)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(cameraAccessItem)
        menu.addItem(resetItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu
    }

    func refresh() {
        let image = NSImage(
            systemSymbolName: app.isPaused ? "eye.slash" : "eye",
            accessibilityDescription: "Pointracker"
        )
        image?.isTemplate = true
        statusItem.button?.image = image

        stateItem.title = app.statusText
        pauseItem.title = app.isUserPaused ? "Resume" : "Pause"
        batteryItem.state = app.settings.pauseOnBattery ? .on : .off
        learnItem.state = app.settings.learnFromClicks ? .on : .off
        pointerItem.state = app.settings.movePointer ? .on : .off
        let speed = app.settings.switchSpeed.rawValue
        for item in speedMenu.items {
            item.state = (item.representedObject as? String) == speed ? .on : .off
        }
        accessibilityItem.isHidden = app.hasAccessibility
        cameraAccessItem.isHidden = app.hasCameraAccess
        updateLive()
    }

    /// Live head-pose readout; only updated while the menu is open.
    func updateLive() {
        guard isMenuOpen else { return }
        liveItem.title = app.liveText
        let performance = app.performanceText
        performanceItem.title = performance
        performanceItem.isHidden = performance.isEmpty
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            isMenuOpen = true
            refresh()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu {
            isMenuOpen = false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === cameraMenu else { return }
        cameraMenu.removeAllItems()
        let devices = CameraService.availableDevices()
        guard !devices.isEmpty else {
            let empty = NSMenuItem(title: "No cameras found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            cameraMenu.addItem(empty)
            return
        }
        let selected = app.settings.cameraUniqueID ?? CameraService.defaultDeviceID()
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectCamera(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == selected ? .on : .off
            cameraMenu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func togglePause() { app.toggleUserPause() }
    @objc private func calibrate() { app.startCalibration() }
    @objc private func grantAccessibility() { app.requestAccessibility() }
    @objc private func grantCamera() { app.requestCamera() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        app.selectCamera(id)
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let speed = SwitchSpeed(rawValue: raw) else { return }
        app.setSwitchSpeed(speed)
    }

    @objc private func toggleBattery() {
        app.setPauseOnBattery(!app.settings.pauseOnBattery)
        refresh()
    }

    @objc private func toggleLearn() {
        app.settings.learnFromClicks.toggle()
        refresh()
    }

    @objc private func togglePointer() {
        app.settings.movePointer.toggle()
        refresh()
    }

    @objc private func resetCalibration() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Reset calibration?"
        alert.informativeText = "Everything Pointracker has learned about where your screens are will be forgotten."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            app.resetCalibration()
        }
    }
}
