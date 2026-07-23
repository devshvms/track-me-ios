import Foundation
import CoreMotion

@MainActor
final class MotionSensorManager {
    static let stationaryEnergyThreshold = 0.18 // m/s²
    static let driftSpeedThreshold = 0.6 // m/s
    static let driftDistanceThreshold = 2.5 // metres
    static let minDistanceToAccumulate = 1.5 // metres
    static let minSpeedToAccumulate = 0.3 // m/s
    
    private let motionManager = CMMotionManager()
    private var emaEnergy: Double = 0.0
    private let emaAlpha: Double = 0.15
    private var sampleReceived: Bool = false
    
    func startListening() {
        guard motionManager.isDeviceMotionAvailable else { return }
        
        motionManager.deviceMotionUpdateInterval = 0.1 // 10 Hz
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self, let motion = motion, error == nil else { return }
            
            // userAcceleration is in Gs. Convert to m/s² (1 G = 9.81 m/s²)
            let acc = motion.userAcceleration
            let magnitudeG = sqrt(acc.x * acc.x + acc.y * acc.y + acc.z * acc.z)
            let magnitudeMS2 = magnitudeG * 9.81
            
            if !self.sampleReceived {
                self.emaEnergy = magnitudeMS2
                self.sampleReceived = true
            } else {
                self.emaEnergy = (self.emaAlpha * magnitudeMS2) + ((1.0 - self.emaAlpha) * self.emaEnergy)
            }
        }
    }
    
    func stopListening() {
        if motionManager.isDeviceMotionAvailable {
            motionManager.stopDeviceMotionUpdates()
        }
        // Reset to "moving" so a stale reading doesn't mistakenly pause
        emaEnergy = 0.0
        sampleReceived = false
    }
    
    func isDeviceStationary() -> Bool {
        return MotionSensorManager.shouldTreatDeviceAsStationary(
            sensorAvailable: motionManager.isDeviceMotionAvailable,
            sampleReceived: sampleReceived,
            motionEnergy: emaEnergy
        )
    }
    
    static func shouldTreatDeviceAsStationary(sensorAvailable: Bool, sampleReceived: Bool, motionEnergy: Double) -> Bool {
        return sensorAvailable && sampleReceived && motionEnergy < stationaryEnergyThreshold
    }
}
