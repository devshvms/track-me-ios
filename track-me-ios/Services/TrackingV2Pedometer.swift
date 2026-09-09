import Foundation
import CoreMotion

/// Optional evidence only. Never prompts as a side effect of a GPS callback.
@MainActor final class TrackingV2Pedometer {
    private let pedometer = CMPedometer()
    private var started = false
    private var generation = 0
    private(set) var steps: Int64?
    private(set) var cadence: Float?
    private var lastUpdate: Date?
    var ageMillis: Int64? { lastUpdate.map { Int64(max(0, -$0.timeIntervalSinceNow) * 1000) } }

    func start(persona: RidePersona) {
        guard !started, persona == .walk || persona == .run,
              CMPedometer.isStepCountingAvailable(),
              CMPedometer.authorizationStatus() == .authorized else { return }
        started = true
        generation += 1
        let requestGeneration = generation
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            guard let data, error == nil else { return }
            let count = data.numberOfSteps.int64Value
            let cadence = data.currentCadence?.floatValue
            let end = data.endDate
            Task { @MainActor [weak self] in
                guard let self, self.started, self.generation == requestGeneration else { return }
                self.steps = count
                self.cadence = cadence
                self.lastUpdate = end
            }
        }
    }
    func stop() {
        started = false
        generation += 1
        pedometer.stopUpdates()
        steps = nil
        cadence = nil
        lastUpdate = nil
    }
}
