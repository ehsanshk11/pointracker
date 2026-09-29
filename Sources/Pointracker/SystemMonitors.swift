import AppKit
import Carbon.HIToolbox
import IOKit.ps
import PointrackerCore

/// Watches keyboard and mouse activity system-wide. Only timestamps and click
/// locations are used; key contents are never read.
@MainActor
final class InputMonitor {
    var onMouseActivity: (() -> Void)?
    var onKeyActivity: (() -> Void)?
    /// Left click at a location in global Quartz coordinates.
    var onLeftClick: ((CGPoint) -> Void)?

    private var monitors: [Any] = []

    /// Key events arrive only once Accessibility is granted, so call this
    /// again after the user grants it.
    func start() {
        stop()
        let mouseMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .rightMouseDown, .otherMouseDown,
        ]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onMouseActivity?()
            }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                let location = event.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero
                self?.onMouseActivity?()
                self?.onLeftClick?(location)
            }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onKeyActivity?()
            }
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

/// Reports whether the Mac is running on battery, and every change.
@MainActor
final class PowerMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var isOnBattery = false
    private var source: CFRunLoopSource?

    func start() {
        isOnBattery = Self.readOnBattery()
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.refresh()
            }
        }, context)?.takeRetainedValue() else { return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func refresh() {
        let onBattery = Self.readOnBattery()
        guard onBattery != isOnBattery else { return }
        isOnBattery = onBattery
        onChange?(onBattery)
    }

    private static func readOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// Sleep, display sleep, screen lock and fast user switching.
@MainActor
final class SystemStateMonitor: NSObject {
    var onChange: ((PauseReason, Bool) -> Void)?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let observations: [(Notification.Name, Selector)] = [
            (NSWorkspace.willSleepNotification, #selector(willSleep)),
            (NSWorkspace.didWakeNotification, #selector(didWake)),
            (NSWorkspace.screensDidSleepNotification, #selector(screensDidSleep)),
            (NSWorkspace.screensDidWakeNotification, #selector(screensDidWake)),
            (NSWorkspace.sessionDidResignActiveNotification, #selector(locked)),
            (NSWorkspace.sessionDidBecomeActiveNotification, #selector(unlocked)),
        ]
        for (name, selector) in observations {
            workspace.addObserver(self, selector: selector, name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(locked), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(unlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func willSleep() { onChange?(.systemAsleep, true) }
    @objc private func didWake() { onChange?(.systemAsleep, false) }
    @objc private func screensDidSleep() { onChange?(.displaysAsleep, true) }
    @objc private func screensDidWake() { onChange?(.displaysAsleep, false) }
    @objc private func locked() { onChange?(.screenLocked, true) }
    @objc private func unlocked() { onChange?(.screenLocked, false) }
}

/// A system-wide keyboard shortcut via Carbon, which needs no extra permission.
@MainActor
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private var reference: EventHotKeyRef?

    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()
        let id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5054_5243), id: id) // 'PTRC'
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else {
            NSLog("Pointracker: could not register hotkey (\(status))")
            return nil
        }
        self.reference = reference
        Self.handlers[id] = handler
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            MainActor.assumeIsolated {
                HotKey.handlers[id]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
