import AppKit
import PointrackerCore

/// Guided calibration: a dot visits the centre and four corners of every
/// screen while head-pose samples are collected. Covering the corners teaches
/// the model each screen's full extent as seen from the camera, wherever the
/// camera sits.
@MainActor
final class CalibrationController: NSObject {
    struct Result {
        let samples: [ScreenID: [LabeledSample]]
        let skippedPoints: Int
    }

    /// Called once; nil when the user cancelled with Esc.
    var onFinish: ((Result?) -> Void)?

    private static let points: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.12, y: 0.15),
        CGPoint(x: 0.88, y: 0.15),
        CGPoint(x: 0.88, y: 0.85),
        CGPoint(x: 0.12, y: 0.85),
    ]
    private let settleDuration: TimeInterval = 0.8
    private let collectDuration: TimeInterval = 1.0
    private let maxCollectDuration: TimeInterval = 2.5
    private let minSamplesPerPoint = 4

    private let screens: [ScreenInfo]
    private let steps: [(screen: ScreenInfo, point: CGPoint)]
    private var windows: [ScreenID: NSWindow] = [:]
    private var views: [ScreenID: CalibrationView] = [:]
    private var stepIndex = 0
    private var stepStart: TimeInterval = 0
    private var stepSamples: [FaceSample] = []
    private var collected: [ScreenID: [LabeledSample]] = [:]
    private var skipped = 0
    private var timer: Timer?
    private var keyMonitor: Any?

    init(screens: [ScreenInfo]) {
        self.screens = screens
        self.steps = screens.flatMap { screen in Self.points.map { (screen: screen, point: $0) } }
        super.init()
    }

    func start() {
        NSApp.activate()
        for screen in screens {
            guard let nsScreen = ScreenRegistry.nsScreen(for: screen) else { continue }
            let window = KeyableWindow(
                contentRect: nsScreen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.88)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            let view = CalibrationView(frame: NSRect(origin: .zero, size: nsScreen.frame.size))
            window.contentView = view
            window.setFrame(nsScreen.frame, display: true)
            window.orderFrontRegardless()
            windows[screen.id] = window
            views[screen.id] = view
        }
        windows.values.first?.makeKeyAndOrderFront(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            MainActor.assumeIsolated {
                self?.cancel()
            }
            return nil
        }

        let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        beginStep(0)
    }

    /// Feed every analysed frame here while calibrating.
    func ingest(_ sample: FaceSample?) {
        guard let sample, stepIndex < steps.count else { return }
        if ProcessInfo.processInfo.systemUptime - stepStart >= settleDuration {
            stepSamples.append(sample)
        }
    }

    func cancel() {
        teardown()
        finish(nil)
    }

    @objc private func tick() {
        guard stepIndex < steps.count else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - stepStart
        let collecting = elapsed - settleDuration
        views[steps[stepIndex].screen.id]?.progress = max(0, min(1, collecting / collectDuration))
        let enough = collecting >= collectDuration && stepSamples.count >= minSamplesPerPoint
        if enough || collecting >= maxCollectDuration {
            finishStep()
        }
    }

    private func beginStep(_ index: Int) {
        stepIndex = index
        stepSamples = []
        stepStart = ProcessInfo.processInfo.systemUptime
        guard index < steps.count else {
            teardown()
            finish(Result(samples: collected, skippedPoints: skipped))
            return
        }
        let step = steps[index]
        let screenNumber = (screens.firstIndex(of: step.screen) ?? 0) + 1
        for (id, view) in views {
            view.progress = 0
            if id == step.screen.id {
                view.dot = step.point
                view.message = "Screen \(screenNumber) of \(screens.count): look at the dot. Esc cancels."
            } else {
                view.dot = nil
                view.message = ""
            }
        }
    }

    private func finishStep() {
        let screen = steps[stepIndex].screen
        if stepSamples.count >= minSamplesPerPoint {
            collected[screen.id, default: []] += stepSamples.map {
                LabeledSample(screen: screen.id, sample: $0, source: .calibration)
            }
        } else {
            skipped += 1
        }
        beginStep(stepIndex + 1)
    }

    private func finish(_ result: Result?) {
        let callback = onFinish
        onFinish = nil
        callback?(result)
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }
}

/// Borderless windows refuse key status by default; calibration needs Esc.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class CalibrationView: NSView {
    /// Dot position as a fraction of the view, origin top-left.
    var dot: CGPoint? { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var message = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let dot else { return }
        let centre = CGPoint(x: bounds.width * dot.x, y: bounds.height * dot.y)
        let radius: CGFloat = 12
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)).fill()

        if progress > 0 {
            let ring = NSBezierPath()
            ring.appendArc(
                withCenter: centre,
                radius: 24,
                startAngle: -90,
                endAngle: -90 + 360 * CGFloat(progress),
                clockwise: false
            )
            ring.lineWidth = 4
            NSColor.white.setStroke()
            ring.stroke()
        }

        guard !message.isEmpty else { return }
        let text = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.5 + 56))
    }
}
