import Combine
import Foundation

enum MarkingStrictnessMode: Int, CaseIterable, Identifiable {
    case current = 0
    case balanced = 1
    case strict = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .current:
            return "Current"
        case .balanced:
            return "Balanced"
        case .strict:
            return "Strict"
        }
    }

    var detail: String {
        switch self {
        case .current:
            return "Allows heuristic recovery and fallback to first unmarked segment."
        case .balanced:
            return "Allows heuristic recovery but disables first-unmarked fallback."
        case .strict:
            return "Requires explicit spoken overlap with target segment; no recovery fallback."
        }
    }

    var allowsHeuristicRecovery: Bool {
        switch self {
        case .current, .balanced:
            return true
        case .strict:
            return false
        }
    }

    var allowsDeterministicFallback: Bool {
        self == .current
    }

    var requiresExplicitSpokenEvidence: Bool {
        self == .strict
    }
}

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

    @Published var realtimeSilenceDurationMilliseconds: Double {
        didSet {
            let clamped = min(max(realtimeSilenceDurationMilliseconds.rounded(), 120), 1_000)
            if clamped != realtimeSilenceDurationMilliseconds {
                realtimeSilenceDurationMilliseconds = clamped
                return
            }
            defaults.set(clamped, forKey: Self.realtimeSilenceDurationMillisecondsKey)
        }
    }

    @Published var realtimeMaxOutputTokens: Double {
        didSet {
            let clamped = min(max(realtimeMaxOutputTokens.rounded(), 80), 420)
            if clamped != realtimeMaxOutputTokens {
                realtimeMaxOutputTokens = clamped
                return
            }
            defaults.set(clamped, forKey: Self.realtimeMaxOutputTokensKey)
        }
    }

    @Published var realtimeMarkCooldownMilliseconds: Double {
        didSet {
            let clamped = min(max(realtimeMarkCooldownMilliseconds.rounded(), 0), 3_000)
            if clamped != realtimeMarkCooldownMilliseconds {
                realtimeMarkCooldownMilliseconds = clamped
                return
            }
            defaults.set(clamped, forKey: Self.realtimeMarkCooldownMillisecondsKey)
        }
    }

    @Published var markingStrictnessMode: MarkingStrictnessMode {
        didSet {
            defaults.set(markingStrictnessMode.rawValue, forKey: Self.markingStrictnessModeKey)
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
        let storedRealtimeSilenceDurationMilliseconds =
            defaults.object(forKey: Self.realtimeSilenceDurationMillisecondsKey) as? Double
        let storedRealtimeMaxOutputTokens =
            defaults.object(forKey: Self.realtimeMaxOutputTokensKey) as? Double
        let storedRealtimeMarkCooldownMilliseconds =
            defaults.object(forKey: Self.realtimeMarkCooldownMillisecondsKey) as? Double
        let storedMarkingStrictnessModeRawValue =
            defaults.object(forKey: Self.markingStrictnessModeKey) as? Int
        let storedQuoteAudioStartDelayMilliseconds =
            defaults.object(forKey: Self.quoteAudioStartDelayMillisecondsKey) as? Double
        let storedQuoteAudioPostPlaybackWaitMilliseconds =
            defaults.object(forKey: Self.quoteAudioPostPlaybackWaitMillisecondsKey) as? Double

        confidenceThreshold = min(max(storedConfidence ?? 0.70, 0.0), 1.0)
        cooldownSeconds = min(max(storedCooldown ?? 1.20, 0.0), 5.0)
        dwellSeconds = min(max(storedDwell ?? 0.00, 0.0), 3.0)
        realtimeSilenceDurationMilliseconds =
            min(max((storedRealtimeSilenceDurationMilliseconds ?? 260).rounded(), 120), 1_000)
        realtimeMaxOutputTokens =
            min(max((storedRealtimeMaxOutputTokens ?? 220).rounded(), 80), 420)
        realtimeMarkCooldownMilliseconds =
            min(max((storedRealtimeMarkCooldownMilliseconds ?? 600).rounded(), 0), 3_000)
        markingStrictnessMode = MarkingStrictnessMode(rawValue: storedMarkingStrictnessModeRawValue ?? 1) ?? .balanced
        quoteAudioStartDelayMilliseconds = min(max((storedQuoteAudioStartDelayMilliseconds ?? 900).rounded(), 0), 60_000)
        quoteAudioPostPlaybackWaitMilliseconds =
            min(max((storedQuoteAudioPostPlaybackWaitMilliseconds ?? 2_000).rounded(), 0), 60_000)
    }

    private static let confidenceThresholdKey = "settings.safety.confidenceThreshold"
    private static let cooldownSecondsKey = "settings.safety.cooldownSeconds"
    private static let dwellSecondsKey = "settings.safety.dwellSeconds"
    private static let realtimeSilenceDurationMillisecondsKey = "settings.realtime.silenceDurationMilliseconds"
    private static let realtimeMaxOutputTokensKey = "settings.realtime.maxOutputTokens"
    private static let realtimeMarkCooldownMillisecondsKey = "settings.realtime.markCooldownMilliseconds"
    private static let markingStrictnessModeKey = "settings.realtime.markingStrictnessMode"
    private static let quoteAudioStartDelayMillisecondsKey = "settings.quoteAudio.startDelayMilliseconds"
    private static let quoteAudioPostPlaybackWaitMillisecondsKey =
        "settings.quoteAudio.postPlaybackWaitMilliseconds"
}
