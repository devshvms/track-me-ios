import Foundation
import CoreMotion

@MainActor
final class MotionSensorManager {
    static let stationaryEnergyThreshold = 0.18 // m/s²
    static let driftSpeedThreshold = 0.6 // m/s
    static let driftDistanceThreshold = 2.5 // metres
    static let minDistanceToAccumulate = 1.5 // metres
    static let minSpeedToAccumulate = 0.3 // m/s

    static let isMotionFusionEnabled = true

    private let motionManager = CMMotionManager()
    private var emaEnergy: Double = 0.0
    private let emaAlpha: Double = 0.15
    private var sampleReceived: Bool = false

    private var gravityX: Double = 0.0
    private var gravityY: Double = 0.0
    private var gravityZ: Double = 0.0

    func startListening() {
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.1 // 10 Hz
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                guard let self = self, let motion = motion, error == nil else { return }
                self.processAcceleration(acc: motion.userAcceleration)
            }
        } else if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.1 // 10 Hz
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                guard let self = self, let data = data, error == nil else { return }
                self.processRawAccelerometer(acc: data.acceleration)
            }
        }
    }

    private func processRawAccelerometer(acc: CMAcceleration) {
        // High-pass filter to remove gravity
        let alpha = 0.8
        gravityX = alpha * gravityX + (1 - alpha) * acc.x
        gravityY = alpha * gravityY + (1 - alpha) * acc.y
        gravityZ = alpha * gravityZ + (1 - alpha) * acc.z

        let userX = acc.x - gravityX
        let userY = acc.y - gravityY
        let userZ = acc.z - gravityZ

        processAcceleration(acc: CMAcceleration(x: userX, y: userY, z: userZ))
    }

    private func processAcceleration(acc: CMAcceleration) {
        // userAcceleration is in Gs. Convert to m/s² (1 G = 9.81 m/s²)
        let magnitudeG = sqrt(acc.x * acc.x + acc.y * acc.y + acc.z * acc.z)
        let magnitudeMS2 = MotionSensorManager.convertGToMS2(g: magnitudeG)

        if !self.sampleReceived {
            self.emaEnergy = magnitudeMS2
            self.sampleReceived = true
        } else {
            self.emaEnergy = (self.emaAlpha * magnitudeMS2) + ((1.0 - self.emaAlpha) * self.emaEnergy)
        }
    }

    func stopListening() {
        if motionManager.isDeviceMotionAvailable {
            motionManager.stopDeviceMotionUpdates()
        }
        if motionManager.isAccelerometerAvailable {
            motionManager.stopAccelerometerUpdates()
        }
        // Reset to "moving" so a stale reading doesn't mistakenly pause
        emaEnergy = 0.0
        sampleReceived = false
        gravityX = 0.0
        gravityY = 0.0
        gravityZ = 0.0
    }

    func isDeviceStationary() -> Bool {
        let sensorAvailable = motionManager.isDeviceMotionAvailable || motionManager.isAccelerometerAvailable
        return MotionSensorManager.shouldTreatDeviceAsStationary(
            sensorAvailable: sensorAvailable,
            sampleReceived: sampleReceived,
            motionEnergy: emaEnergy
        )
    }

    static func shouldTreatDeviceAsStationary(sensorAvailable: Bool, sampleReceived: Bool, motionEnergy: Double) -> Bool {
        return sensorAvailable && sampleReceived && motionEnergy < stationaryEnergyThreshold
    }

    static func convertGToMS2(g: Double) -> Double {
        return g * 9.81
    }

    static func distanceShouldAccumulate(state: TrackingState, isPaused: Bool, dist: Double, effectiveSpeed: Double) -> Bool {
        return state == .tracking && !isPaused && dist >= minDistanceToAccumulate && effectiveSpeed > minSpeedToAccumulate
    }
}
