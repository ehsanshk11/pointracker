import AppKit
import AVFoundation
import Carbon.HIToolbox
import PointrackerCore

/// Wires camera → classifier → decider → focus, and every reason to pause.
@MainActor
final class AppController: NSObject {
    let settings: Settings
    private let activity: ActivityClock
    private let camera: CameraService
    private let focus: FocusController
    private let input: InputMonitor
    private let power: PowerMonitor
    private let system: SystemStateMonitor
    private var menu: StatusMenuController?
    private var hotKey: HotKey?

    private var store: SampleStore
    private let classifier = ScreenClassifier()
    private var decider: FocusDecider
    private var pause = PauseState()
    private var screens: [ScreenInfo] = []
    private var currentScreen: ScreenID?
    private var lastSample: FaceSample?
    private var lastClassification: Classification?
    private var lastOutput: DeciderOutput = .idle
    private var cameraRunning = false
    private var calibration: CalibrationController?
    private var lastClickLearned: [ScreenID: TimeInterval] = [:]
    private var trustTimer: Timer?

    override init() {
        settings = Settings()
        let config = settings.switchSpeed.config
        activity = ActivityClock(mouseHold: config.mouseHold, typingHold: config.typingHold)
        camera = CameraService(activity: activity)
        focus = FocusController()
        input = InputMonitor()
        power = PowerMonitor()
        system = SystemStateMonitor()
        store = SampleStorage.load() ?? SampleStore()
        decider = FocusDecider(config: config)
        super.init()
    }

    func start() {
        menu = StatusMenuController(app: self)

        camera.onSample = { [weak self] sample in
            self?.handle(sample)
        }
        input.onMouseActivity = { [weak self] in self?.noteMouseActivity() }
        input.onKeyActivity = { [weak self] in
            self?.activity.noteKey(at: ProcessInfo.processInfo.systemUptime)
        }
        input.onLeftClick = { [weak self] location in self?.handleClick(at: location) }
        input.start()

        power.onChange = { [weak self] onBattery in self?.applyPower(onBattery) }
        power.start()
        applyPower(power.isOnBattery)

        system.onChange = { [weak self] reason, active in self?.setPause(reason, active) }
        system.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        hotKey = HotKey(keyCode: kVK_ANSI_G, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.toggleUserPause()
        }

        refreshScreens()
        checkAccessibility(prompt: true)
        checkCameraAccess()
        updateCamera()
    }

    // MARK: - State for the menu

    var isPaused: Bool { calibration == nil && pause.isPaused }
    var isUserPaused: Bool { pause.reasons.contains(.user) }
    var hasAccessibility: Bool { !pause.reasons.contains(.noAccessibility) }
    var hasCameraAccess: Bool { !pause.reasons.contains(.noCamera) }
    var isCalibrated: Bool { !pause.reasons.contains(.notCalibrated) }

    var statusText: String {
        if calibration != nil { return "Calibrating…" }
        if let reason = pause.primaryReason { return reason.message }
        if let id = currentScreen, let screen = screens.screen(for: id) {
            return "Active — focus on \(screen.name)"
        }
        return "Active"
    }

    var liveText: String {
        guard cameraRunning else { return "Camera off" }
        guard let sample = lastSample,
              ProcessInfo.processInfo.systemUptime - sample.timestamp < 1 else { return "No face in view" }
        var text = String(format: "yaw %+.0f°  pitch %+.0f°", sample.yaw, sample.pitch)
        if let classification = lastClassification, let best = classification.best {
            let name = screens.screen(for: best)?.name ?? best.rawValue
            text += classification.isOutlier
                ? "  →  looking away"
                : String(format: "  →  %@ %.0f%%", name, classification.score(for: best) * 100)
        }
        switch lastOutput {
        case .holding(.mouse): text += "  (mouse)"
        case .holding(.typing): text += "  (typing)"
        default: break
        }
        return text
    }

    // MARK: - Actions

    func toggleUserPause() {
        setPause(.user, !pause.reasons.contains(.user))
    }

    func setPauseOnBattery(_ enabled: Bool) {
        settings.pauseOnBattery = enabled
        applyPower(power.isOnBattery)
    }

    func setSwitchSpeed(_ speed: SwitchSpeed) {
        settings.switchSpeed = speed
        let config = speed.config
        decider.config = config
        activity.setHolds(mouse: config.mouseHold, typing: config.typingHold)
        menu?.refresh()
    }

    func selectCamera(_ id: String) {
        settings.cameraUniqueID = id
        if cameraRunning {
            camera.start(deviceID: id)
        }
        menu?.refresh()
    }

    func requestAccessibility() {
        FocusController.requestTrust()
        openSettings("Privacy_Accessibility")
    }

    func requestCamera() {
        if CameraService.authorization == .notDetermined {
            checkCameraAccess()
        } else {
            openSettings("Privacy_Camera")
        }
    }

    func startCalibration() {
        guard calibration == nil else { return }
        guard screens.count >= 2 else {
            showAlert("Connect at least two displays", "Calibration teaches Pointracker where each display is from where you sit.")
            return
        }
        guard CameraService.authorization == .authorized else {
            requestCamera()
            return
        }
        let controller = CalibrationController(screens: screens)
        controller.onFinish = { [weak self] result in
            self?.finishCalibration(result)
        }
        calibration = controller
        decider.reset()
        updateCamera()
        controller.start()
    }

    func resetCalibration() {
        store.removeAll()
        SampleStorage.delete()
        updateCalibrationState()
    }

    // MARK: - Pipeline

    private func handle(_ sample: FaceSample?) {
        guard cameraRunning else { return }
        if let sample { lastSample = sample }
        if let calibration {
            calibration.ingest(sample)
            return
        }
        guard !pause.isPaused else { return }

        let classification = sample.flatMap {
            classifier.classify($0, in: store, among: calibratedScreens)
        }
        if sample != nil { lastClassification = classification }
        let output = decider.step(DeciderInput(
            time: ProcessInfo.processInfo.systemUptime,
            classification: classification,
            currentScreen: currentScreen,
            lastMouseActivity: activity.lastMouse,
            lastKeyActivity: activity.lastKey
        ))
        lastOutput = output
        if case .switchTo(let id) = output, let target = screens.screen(for: id) {
            focus.focus(target, screens: screens, movePointer: settings.movePointer)
            currentScreen = id
            menu?.refresh()
        }
        menu?.updateLive()
    }

    private func noteMouseActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        // Our own pointer warp is not the user touching the mouse.
        guard now - focus.lastWarpTime > 0.2 else { return }
        activity.noteMouse(at: now)
    }

    /// People look where they click, so a click is a free, correctly labelled
    /// training sample. This is how the model keeps up when the user sits
    /// closer, farther or off to one side.
    private func handleClick(at location: CGPoint) {
        guard let screen = screens.screen(containing: location) else { return }
        currentScreen = screen.id
        guard settings.learnFromClicks,
              calibration == nil,
              !pause.isPaused,
              calibratedScreens.contains(screen.id),
              let sample = lastSample else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - sample.timestamp < 0.35 else { return }
        if let last = lastClickLearned[screen.id], now - last < 2 { return }
        // Skip poses nothing like any screen (e.g. clicking without looking).
        if let classification = classifier.classify(sample, in: store, among: calibratedScreens),
           classification.nearestDistance > classifier.outlierDistance * 1.5 {
            return
        }
        store.add(LabeledSample(screen: screen.id, sample: sample, source: .click))
        lastClickLearned[screen.id] = now
        scheduleSave()
    }

    private func finishCalibration(_ result: CalibrationController.Result?) {
        calibration = nil
        if let result {
            for (id, samples) in result.samples {
                store.resetScreen(id, with: samples)
            }
            SampleStorage.save(store)
            updateCalibrationState()
            showCalibrationReport(result)
        }
        decider.reset()
        updateCamera()
    }

    private func showCalibrationReport(_ result: CalibrationController.Result) {
        var lines: [String] = []
        for screen in screens {
            guard let centroid = CalibrationQuality.centroid(of: screen.id, in: store) else {
                lines.append("\(screen.name): no samples")
                continue
            }
            lines.append(String(format: "%@: head at %+.0f° yaw, %+.0f° pitch", screen.name, centroid.yaw, centroid.pitch))
        }
        for separation in CalibrationQuality.separations(in: store, among: calibratedScreens, space: classifier.space) {
            let first = screens.screen(for: separation.first)?.name ?? separation.first.rawValue
            let second = screens.screen(for: separation.second)?.name ?? separation.second.rawValue
            let verdict: String
            switch separation.rating {
            case .good: verdict = "easy to tell apart"
            case .fair: verdict = "close; switching may hesitate near the edges"
            case .poor: verdict = "overlapping; move the camera or recalibrate"
            }
            lines.append("\(first) ↔ \(second): \(verdict)")
        }
        if result.skippedPoints > 0 {
            lines.append("\(result.skippedPoints) point(s) skipped: your face was not visible to the camera.")
        }
        showAlert("Calibration finished", lines.joined(separator: "\n"))
    }

    // MARK: - Pausing

    private var calibratedScreens: Set<ScreenID> {
        store.screens.intersection(screens.map(\.id))
    }

    func setPause(_ reason: PauseReason, _ active: Bool) {
        guard pause.set(reason, active) else { return }
        if active {
            decider.reset()
        }
        updateCamera()
    }

    private func applyPower(_ onBattery: Bool) {
        setPause(.onBattery, settings.pauseOnBattery && onBattery)
        menu?.refresh()
    }

    private func updateCalibrationState() {
        setPause(.notCalibrated, calibratedScreens.count < 2)
        menu?.refresh()
    }

    private func updateCamera() {
        let shouldRun = pause.cameraShouldRun(calibrating: calibration != nil)
        if shouldRun != cameraRunning {
            cameraRunning = shouldRun
            if shouldRun {
                camera.start(deviceID: settings.cameraUniqueID)
            } else {
                camera.stop()
                lastSample = nil
                lastClassification = nil
            }
        }
        menu?.refresh()
    }

    private func checkAccessibility(prompt: Bool) {
        let trusted = prompt ? FocusController.requestTrust() : FocusController.isTrusted
        setPause(.noAccessibility, !trusted)
        if trusted {
            trustTimer?.invalidate()
            trustTimer = nil
        } else if trustTimer == nil {
            let timer = Timer(timeInterval: 2, target: self, selector: #selector(pollAccessibility), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            trustTimer = timer
        }
    }

    @objc private func pollAccessibility() {
        guard FocusController.isTrusted else { return }
        checkAccessibility(prompt: false)
        // Global key monitors only deliver once the app is trusted.
        input.start()
    }

    private func checkCameraAccess() {
        switch CameraService.authorization {
        case .authorized:
            setPause(.noCamera, false)
        case .notDetermined:
            setPause(.noCamera, true)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.setPause(.noCamera, !granted)
                    }
                }
            }
        default:
            setPause(.noCamera, true)
        }
    }

    // MARK: - Notifications

    @objc private func screensChanged() {
        refreshScreens()
    }

    @objc private func appActivated() {
        if let screen = focus.screenOfFocusedWindow(in: screens) {
            currentScreen = screen.id
        }
    }

    private func refreshScreens() {
        screens = ScreenRegistry.currentScreens()
        setPause(.singleScreen, screens.count < 2)
        updateCalibrationState()
        currentScreen = focus.screenOfFocusedWindow(in: screens)?.id ?? currentScreen
    }

    // MARK: - Helpers

    private func scheduleSave() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveNow), object: nil)
        perform(#selector(saveNow), with: nil, afterDelay: 5)
    }

    @objc private func saveNow() {
        SampleStorage.save(store)
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
