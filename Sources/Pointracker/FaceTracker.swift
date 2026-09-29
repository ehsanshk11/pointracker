import CoreML
import CoreVideo
import Foundation
import PointrackerCore
import Vision

/// Extracts head pose and eye cues from one frame with Apple's Vision
/// framework. Runs entirely on-device.
final class FaceTracker {
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        FaceTracker.preferNeuralEngine(request)
        return request
    }()

    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        FaceTracker.preferNeuralEngine(request)
        return request
    }()

    func process(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> FaceSample? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest])
        } catch {
            return nil
        }
        // With several people in view, follow the largest (closest) face.
        guard let face = faceRequest.results?.max(by: { area($0) < area($1) }),
              face.confidence > 0.5,
              let yaw = face.yaw?.doubleValue else { return nil }

        var noseOffset: Double?
        var eyeOffset: Double?
        landmarksRequest.inputFaceObservations = [face]
        if (try? handler.perform([landmarksRequest])) != nil,
           let landmarks = landmarksRequest.results?.first?.landmarks {
            noseOffset = Self.noseOffset(landmarks)
            eyeOffset = Self.eyeOffset(landmarks)
        }

        let box = face.boundingBox
        return FaceSample(
            yaw: degrees(yaw),
            pitch: degrees(face.pitch?.doubleValue ?? 0),
            roll: degrees(face.roll?.doubleValue ?? 0),
            faceX: Double(box.midX),
            faceY: Double(box.midY),
            faceSize: Double(box.width),
            noseOffset: noseOffset,
            eyeOffset: eyeOffset,
            timestamp: timestamp
        )
    }

    /// Runs the models on the Neural Engine where Vision allows it, which
    /// keeps them off the CPU cores.
    private static func preferNeuralEngine(_ request: VNRequest) {
        guard let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            let neuralEngine = devices.first { device in
                if case .neuralEngine = device { return true }
                return false
            }
            if let neuralEngine {
                request.setComputeDevice(neuralEngine, for: stage)
            }
        }
    }

    private func area(_ face: VNFaceObservation) -> CGFloat {
        face.boundingBox.width * face.boundingBox.height
    }

    private func degrees(_ radians: Double) -> Double {
        radians * 180 / .pi
    }

    /// Nose centre relative to the middle of the face outline, in face widths.
    /// Grows as the head turns; a continuous cue alongside Vision's yaw.
    static func noseOffset(_ landmarks: VNFaceLandmarks2D) -> Double? {
        guard let nose = landmarks.nose?.normalizedPoints, !nose.isEmpty,
              let contour = landmarks.faceContour?.normalizedPoints, contour.count > 2 else { return nil }
        let xs = contour.map { Double($0.x) }
        guard let minX = xs.min(), let maxX = xs.max(), maxX - minX > 0.05 else { return nil }
        let noseX = nose.map { Double($0.x) }.reduce(0, +) / Double(nose.count)
        return (noseX - (minX + maxX) / 2) / (maxX - minX)
    }

    /// Pupil position inside each eye, averaged over both eyes, -1...1.
    static func eyeOffset(_ landmarks: VNFaceLandmarks2D) -> Double? {
        var values: [Double] = []
        for (eye, pupil) in [(landmarks.leftEye, landmarks.leftPupil), (landmarks.rightEye, landmarks.rightPupil)] {
            guard let eye, let pupil, let point = pupil.normalizedPoints.first else { continue }
            let xs = eye.normalizedPoints.map { Double($0.x) }
            guard let minX = xs.min(), let maxX = xs.max(), maxX - minX > 0.01 else { continue }
            values.append((Double(point.x) - (minX + maxX) / 2) / ((maxX - minX) / 2))
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
