import AppKit
import PointrackerCore

struct ScreenInfo: Equatable {
    let id: ScreenID
    let displayID: CGDirectDisplayID
    /// Global Quartz coordinates (origin top-left of the main display), the
    /// same space as CGWindowList, Accessibility and CGEvent locations.
    let bounds: CGRect
    let name: String

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
}

@MainActor
enum ScreenRegistry {
    static func currentScreens() -> [ScreenInfo] {
        var result: [ScreenInfo] = []
        var usedKeys = Set<String>()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(displayID)
            var key = CGDisplayIsBuiltin(displayID) != 0
                ? "builtin"
                : "\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(CGDisplaySerialNumber(displayID))"
            // Two identical monitors without serial numbers: tell them apart by position.
            if usedKeys.contains(key) {
                key += "@\(Int(bounds.minX)),\(Int(bounds.minY))"
            }
            usedKeys.insert(key)
            result.append(ScreenInfo(id: ScreenID(key), displayID: displayID, bounds: bounds, name: screen.localizedName))
        }
        return result
    }

    static func nsScreen(for info: ScreenInfo) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == info.displayID
        }
    }
}

extension Array where Element == ScreenInfo {
    func screen(for id: ScreenID) -> ScreenInfo? {
        first { $0.id == id }
    }

    func screen(containing point: CGPoint) -> ScreenInfo? {
        first { $0.bounds.contains(point) }
    }

    /// The screen holding most of a rectangle, e.g. a window frame.
    func screen(bestMatching rect: CGRect) -> ScreenInfo? {
        var best: (screen: ScreenInfo, area: CGFloat)?
        for screen in self {
            let overlap = screen.bounds.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) {
                best = (screen, area)
            }
        }
        return best?.screen
    }
}
