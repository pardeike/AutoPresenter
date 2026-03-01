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

    @Published var quoteAudioStartDelayMilliseconds: Double {
        didSet {
            let clamped = min(max(quoteAudioStartDelayMilliseconds.rounded(), 0), 60_000)
            if clamped != quoteAudioStartDelayMilliseconds {
                quoteAudioStartDelayMilliseconds = clamped
                return
            }
            defaults.set(clamped, forKey: Self.quoteAudioStartDelayMillisecondsKey)
        }
    }

    @Published var quoteAudioPostPlaybackWaitMilliseconds: Double {
        didSet {
            let clamped = min(max(quoteAudioPostPlaybackWaitMilliseconds.rounded(), 0), 60_000)
            if clamped != quoteAudioPostPlaybackWaitMilliseconds {
                quoteAudioPostPlaybackWaitMilliseconds = clamped
                return
            }
            defaults.set(clamped, forKey: Self.quoteAudioPostPlaybackWaitMillisecondsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedConfidence = defaults.object(forKey: Self.confidenceThresholdKey) as? Double
        let storedCooldown = defaults.object(forKey: Self.cooldownSecondsKey) as? Double
        let storedDwell = defaults.object(forKey: Self.dwellSecondsKey) as? Double
        let storedQuoteAudioStartDelayMilliseconds =
            defaults.object(forKey: Self.quoteAudioStartDelayMillisecondsKey) as? Double
        let storedQuoteAudioPostPlaybackWaitMilliseconds =
            defaults.object(forKey: Self.quoteAudioPostPlaybackWaitMillisecondsKey) as? Double

        confidenceThreshold = min(max(storedConfidence ?? 0.70, 0.0), 1.0)
        cooldownSeconds = min(max(storedCooldown ?? 1.20, 0.0), 5.0)
        dwellSeconds = min(max(storedDwell ?? 0.00, 0.0), 3.0)
        quoteAudioStartDelayMilliseconds = min(max((storedQuoteAudioStartDelayMilliseconds ?? 900).rounded(), 0), 60_000)
        quoteAudioPostPlaybackWaitMilliseconds =
            min(max((storedQuoteAudioPostPlaybackWaitMilliseconds ?? 2_000).rounded(), 0), 60_000)
    }

    private static let confidenceThresholdKey = "settings.safety.confidenceThreshold"
    private static let cooldownSecondsKey = "settings.safety.cooldownSeconds"
    private static let dwellSecondsKey = "settings.safety.dwellSeconds"
    private static let quoteAudioStartDelayMillisecondsKey = "settings.quoteAudio.startDelayMilliseconds"
    private static let quoteAudioPostPlaybackWaitMillisecondsKey =
        "settings.quoteAudio.postPlaybackWaitMilliseconds"
}
