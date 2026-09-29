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

    /// Frame rate while a switch could happen, and while the user is busy
    /// typing or using the mouse (when no switch can happen anyway).
    static let activeFPS = 12.0
    static let heldFPS = 4.0

    /// Called on the main actor with each analysed frame (nil = no face).
    /// Set before calling `start`.
    var onSample: (@MainActor (FaceSample?) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pointracker.camera.session")
    private let videoQueue = DispatchQueue(label: "pointracker.camera.video", qos: .userInitiated)
    private let tracker = FaceTracker()
    private let activity: ActivityClock
    // Session state: sessionQueue only.
    private var configuredDeviceID: String??
    // Frame throttling: videoQueue only.
    private var lastProcessed: TimeInterval = 0

    init(activity: ActivityClock) {
        self.activity = activity
        super.init()
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
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else {
            session.sessionPreset = .low
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
        limitFrameRate(device, fps: 15)
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
        let interval = activity.frameInterval(at: now, activeFPS: Self.activeFPS, heldFPS: Self.heldFPS)
        guard now - lastProcessed >= interval * 0.9 else { return }
        lastProcessed = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let sample = tracker.process(pixelBuffer, timestamp: now)
        let handler = onSample
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler?(sample)
            }
        }
    }
}
