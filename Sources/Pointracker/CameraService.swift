import AVFoundation
import CoreMedia
import PointrackerCore

/// Owns the capture session. Frames are analysed in memory on a background
/// queue and dropped immediately; nothing is recorded or saved.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Device: Equatable {
        let id: String
        let name: String
    }

    /// Analysis rates (see FramePacer) are 15, 7.5, 5 and 2 fps: whole
    /// divisors of the capture rate, so frames are skipped evenly.
    static let captureFPS = 15.0

    struct Stats: Equatable {
        var analysedFPS: Double = 0
        var millisecondsPerFrame: Double = 0
    }

    /// Called on the main actor with each analysed frame (nil = no face).
    /// Set before calling `start`.
    var onSample: (@MainActor (FaceSample?) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pointracker.camera.session")
    private let videoQueue = DispatchQueue(label: "pointracker.camera.video", qos: .userInitiated)
    private let tracker = FaceTracker()
    private let activity: ActivityClock
    let pacer = FramePacer()
    // Session state: sessionQueue only.
    private var configuredDeviceID: String??
    // Frame throttling: videoQueue only.
    private var lastProcessed: TimeInterval = 0
    private var windowStart: TimeInterval = 0
    private var windowFrames = 0
    private var windowMilliseconds = 0.0
    // Published stats, readable from any thread.
    private let statsLock = NSLock()
    private var _stats = Stats()

    init(activity: ActivityClock) {
        self.activity = activity
        super.init()
    }

    var stats: Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _stats
    }

    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func availableDevices() -> [Device] {
        discovery().devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func defaultDeviceID() -> String? {
        AVCaptureDevice.default(for: .video)?.uniqueID
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
    }

    /// Starts (or switches to) the given camera. Nil = system default.
    func start(deviceID: String?) {
        sessionQueue.async { [self] in
            if configuredDeviceID != .some(deviceID) || session.inputs.isEmpty {
                configure(deviceID: deviceID)
            }
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configure(deviceID: String?) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        // Head pose needs very little resolution; small frames keep Vision cheap.
        if let preset = [AVCaptureSession.Preset.cif352x288, .vga640x480, .low].first(where: session.canSetSessionPreset) {
            session.sessionPreset = preset
        }

        let devices = Self.discovery().devices
        let device = devices.first { $0.uniqueID == deviceID }
            ?? AVCaptureDevice.default(for: .video)
            ?? devices.first
        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            NSLog("Pointracker: no usable camera")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
        configuredDeviceID = .some(deviceID)
        limitFrameRate(device, fps: Self.captureFPS)
    }

    private func limitFrameRate(_ device: AVCaptureDevice, fps: Double) {
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= fps && fps <= $0.maxFrameRate
        }) else { return }
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            NSLog("Pointracker: could not limit frame rate: \(error)")
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = pacer.interval(at: now, held: activity.isHeld(at: now))
        guard now - lastProcessed >= interval * 0.9 else { return }
        lastProcessed = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let sample = tracker.process(pixelBuffer, timestamp: now)
        pacer.observe(sample, at: now)
        recordStats(start: now, end: ProcessInfo.processInfo.systemUptime)
        let handler = onSample
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler?(sample)
            }
        }
    }

    private func recordStats(start: TimeInterval, end: TimeInterval) {
        if windowStart == 0 {
            windowStart = start
        }
        windowFrames += 1
        windowMilliseconds += (end - start) * 1000
        let elapsed = end - windowStart
        guard elapsed >= 2 else { return }
        let stats = Stats(
            analysedFPS: Double(windowFrames) / elapsed,
            millisecondsPerFrame: windowMilliseconds / Double(windowFrames)
        )
        windowStart = end
        windowFrames = 0
        windowMilliseconds = 0
        statsLock.lock()
        _stats = stats
        statsLock.unlock()
    }
}
