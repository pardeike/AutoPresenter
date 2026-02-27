import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var confidenceThreshold: Double {
        didSet {
            let clamped = min(max(confidenceThreshold, 0.0), 1.0)
            if clamped != confidenceThreshold {
                confidenceThreshold = clamped
                return
            }
            defaults.set(clamped, forKey: Self.confidenceThresholdKey)
        }
    }

    @Published var cooldownSeconds: Double {
        didSet {
            let clamped = min(max(cooldownSeconds, 0.0), 5.0)
            if clamped != cooldownSeconds {
                cooldownSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Self.cooldownSecondsKey)
        }
    }

    @Published var dwellSeconds: Double {
        didSet {
            let clamped = min(max(dwellSeconds, 0.0), 3.0)
            if clamped != dwellSeconds {
                dwellSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Self.dwellSecondsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedConfidence = defaults.object(forKey: Self.confidenceThresholdKey) as? Double
        let storedCooldown = defaults.object(forKey: Self.cooldownSecondsKey) as? Double
        let storedDwell = defaults.object(forKey: Self.dwellSecondsKey) as? Double

        confidenceThreshold = min(max(storedConfidence ?? 0.70, 0.0), 1.0)
        cooldownSeconds = min(max(storedCooldown ?? 1.20, 0.0), 5.0)
        dwellSeconds = min(max(storedDwell ?? 0.00, 0.0), 3.0)
    }

    private static let confidenceThresholdKey = "settings.safety.confidenceThreshold"
    private static let cooldownSecondsKey = "settings.safety.cooldownSeconds"
    private static let dwellSecondsKey = "settings.safety.dwellSeconds"
}
