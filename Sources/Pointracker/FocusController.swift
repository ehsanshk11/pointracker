import AppKit
import ApplicationServices
import PointrackerCore

/// Moves keyboard focus between screens through the Accessibility API.
/// It never clicks: clicking blindly could press a button or drop a selection.
@MainActor
final class FocusController {
    private struct WindowRef {
        let pid: pid_t
        let bounds: CGRect
    }

    /// Where the pointer was on each screen when focus last left it.
    private var pointerPositions: [ScreenID: CGPoint] = [:]
    private(set) var lastWarpTime: TimeInterval = 0

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Accessibility settings.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The screen holding the frontmost app's focused window.
    func screenOfFocusedWindow(in screens: [ScreenInfo]) -> ScreenInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let window = Self.element(appElement, kAXFocusedWindowAttribute),
              let frame = Self.frame(of: window) else { return nil }
        return screens.screen(bestMatching: frame)
    }

    /// Brings the most recently used window on `target` forward and gives it
    /// keyboard focus. Returns false when the screen has no suitable window.
    @discardableResult
    func focus(_ target: ScreenInfo, screens: [ScreenInfo], movePointer: Bool) -> Bool {
        let pointer = CGEvent(source: nil)?.location
        if let pointer, let from = screens.screen(containing: pointer), from.id != target.id {
            pointerPositions[from.id] = pointer
        }

        var focused = false
        if let window = Self.frontmostWindow(on: target) {
            focused = Self.activate(window)
        }

        if movePointer, let pointer, !target.bounds.contains(pointer) {
            var destination = pointerPositions[target.id] ?? target.center
            if !target.bounds.contains(destination) {
                destination = target.center
            }
            lastWarpTime = ProcessInfo.processInfo.systemUptime
            CGWarpMouseCursorPosition(destination)
            // Warping briefly freezes the pointer; re-associating cancels that.
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        return focused
    }

    /// CGWindowList is ordered front to back, so the first normal window on a
    /// screen is the one the user used last there.
    private static func frontmostWindow(on screen: ScreenInfo) -> WindowRef? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 80, bounds.height >= 60 else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 {
                continue
            }
            let overlap = bounds.intersection(screen.bounds)
            guard !overlap.isNull, overlap.width * overlap.height >= 0.5 * bounds.width * bounds.height else {
                continue
            }
            return WindowRef(pid: pid, bounds: bounds)
        }
        return nil
    }

    private static func activate(_ ref: WindowRef) -> Bool {
        let appElement = AXUIElementCreateApplication(ref.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: ref.pid)?.activate(options: [])

        // Activating an app raises its own key window, which may sit on a
        // different screen; raise the window on the target screen after.
        guard let windows = elements(appElement, kAXWindowsAttribute),
              let window = windows.first(where: { frame(of: $0).map { isClose($0, ref.bounds) } ?? false }) else {
            return false
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 4 && abs(a.minY - b.minY) <= 4
            && abs(a.width - b.width) <= 4 && abs(a.height - b.height) <= 4
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
