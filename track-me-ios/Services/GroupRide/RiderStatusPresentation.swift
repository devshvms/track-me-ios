import SwiftUI

enum RiderStatusPresentation {
    static func label(for status: RiderStatus) -> String {
        let key: String? = switch status.code {
        case RiderStatusCatalog.shortBreak: "Short break"
        case RiderStatusCatalog.tired: "Tired"
        case RiderStatusCatalog.vehicleIssue: "Vehicle issue"
        case RiderStatusCatalog.needHelp: "Need help"
        case RiderStatusCatalog.crashed: "Crashed"
        case RiderStatusCatalog.fuelStopBike, RiderStatusCatalog.fuelStopCar: "Fuel stop"
        case RiderStatusCatalog.engineHeat: "Engine heat"
        case RiderStatusCatalog.onACall: "On a call"
        case RiderStatusCatalog.waterBreakCycle,
             RiderStatusCatalog.waterBreakWalk,
             RiderStatusCatalog.waterBreakRun: "Water break"
        case RiderStatusCatalog.puncture: "Puncture"
        default: nil
        }
        if let key { return LocalizationHelper.localized(key) }

        let fallback: String = switch (status.severity, status.persona) {
        case (.alert, _): "Status needs attention"
        case (.caution, .bikeDrive): "Motorbike — something's wrong"
        case (.caution, .carDrive): "Car — something's wrong"
        case (.caution, .cycling): "Bicycle — something's wrong"
        case (.caution, .walk): "Walking — something's wrong"
        case (.caution, .run): "Running — something's wrong"
        case (.caution, _): "Something's wrong"
        case (.info, _): "Status update"
        }
        return LocalizationHelper.localized(fallback)
    }

    static func severityName(_ severity: StatusSeverity) -> String {
        let key = switch severity {
        case .alert: "Alert"
        case .caution: "Caution"
        case .info: "Info"
        }
        return LocalizationHelper.localized(key)
    }

    static func systemImage(_ severity: StatusSeverity) -> String {
        switch severity {
        case .alert: "exclamationmark"
        case .caution: "wrench.fill"
        case .info: "circle.fill"
        }
    }

    static func color(_ severity: StatusSeverity) -> Color {
        switch severity {
        case .alert: BrandColor.severityAlert
        case .caution: BrandColor.severityCaution
        case .info: BrandColor.severityInfo
        }
    }

    static func fillForeground(_ severity: StatusSeverity) -> Color {
        switch severity {
        case .alert: .white
        case .caution, .info: BrandColor.onWarning
        }
    }

    static func textColor(_ severity: StatusSeverity) -> Color {
        switch severity {
        case .alert: BrandColor.destructiveText
        case .caution: BrandColor.severityCautionText
        case .info: BrandColor.severityInfoText
        }
    }
}
