import Foundation

struct CommandPolicy: Sendable {
    var confidenceThreshold: Double
    var cooldownSeconds: Double
    var dwellSeconds: Double
}

struct GateDecision: Sendable {
    let accepted: Bool
    let reason: String
    let command: SlideCommand
}

actor CommandSafetyGate {
    private static let logNumberLocale = Locale(identifier: "en_US_POSIX")

    private struct PendingCandidate: Sendable {
        let signature: String
        let command: SlideCommand
        let firstSeenAt: Date
    }

    private var pendingCandidate: PendingCandidate?
    private var lastAcceptedAt: Date?

    func reset() {
        pendingCandidate = nil
        lastAcceptedAt = nil
    }

    func evaluate(
        command: SlideCommand,
        validSlideIndices: Set<Int>,
        policy: CommandPolicy,
        now: Date = .now
    ) -> GateDecision {
        let normalized = normalizedCommand(from: command)

        guard normalized.confidence.isFinite else {
            pendingCandidate = nil
            return GateDecision(accepted: false, reason: "non-finite confidence", command: normalized)
        }

        let threshold = min(max(policy.confidenceThreshold, 0), 1)
        if normalized.confidence < threshold {
            pendingCandidate = nil
            return GateDecision(
                accepted: false,
                reason: "confidence \(format(normalized.confidence)) below threshold \(format(threshold))",
                command: normalized
            )
        }

        if normalized.action == .stay {
            pendingCandidate = nil
            return GateDecision(accepted: false, reason: "model requested stay", command: normalized)
        }

        if normalized.action == .mark {
            guard let markIndex = normalized.markIndex else {
                pendingCandidate = nil
                return GateDecision(accepted: false, reason: "mark missing mark_index", command: normalized)
            }
            guard markIndex > 0 else {
                pendingCandidate = nil
                return GateDecision(accepted: false, reason: "mark_index must be positive", command: normalized)
            }

            pendingCandidate = nil
            return GateDecision(accepted: true, reason: "accepted mark", command: normalized)
        }

        if normalized.action == .goto {
            guard let targetSlide = normalized.targetSlide else {
                pendingCandidate = nil
                return GateDecision(accepted: false, reason: "goto missing target_slide", command: normalized)
            }
            guard validSlideIndices.contains(targetSlide) else {
                pendingCandidate = nil
                return GateDecision(accepted: false, reason: "goto target_slide outside deck", command: normalized)
            }
        }

        let cooldown = max(0, policy.cooldownSeconds)
        if let lastAcceptedAt {
            let elapsed = now.timeIntervalSince(lastAcceptedAt)
            if elapsed < cooldown {
                return GateDecision(
                    accepted: false,
                    reason: "cooldown active (\(format(cooldown - elapsed))s remaining)",
                    command: normalized
                )
            }
        }

        let dwell = max(0, policy.dwellSeconds)
        if dwell == 0 {
            pendingCandidate = nil
            lastAcceptedAt = now
            return GateDecision(accepted: true, reason: "accepted (no dwell)", command: normalized)
        }

        let signature = normalized.signature
        if let pendingCandidate, pendingCandidate.signature == signature {
            let elapsed = now.timeIntervalSince(pendingCandidate.firstSeenAt)
            guard elapsed >= dwell else {
                return GateDecision(
                    accepted: false,
                    reason: "awaiting dwell (\(format(dwell - elapsed))s remaining)",
                    command: normalized
                )
            }
            self.pendingCandidate = nil
            lastAcceptedAt = now
            return GateDecision(accepted: true, reason: "accepted after dwell", command: normalized)
        }

        pendingCandidate = PendingCandidate(signature: signature, command: normalized, firstSeenAt: now)
        return GateDecision(accepted: false, reason: "candidate observed; waiting for dwell", command: normalized)
    }

    private func normalizedCommand(from command: SlideCommand) -> SlideCommand {
        switch command.action {
        case .next, .previous, .stay:
            return SlideCommand(
                action: command.action,
                targetSlide: nil,
                markIndex: nil,
                confidence: command.confidence,
                rationale: command.rationale,
                utteranceExcerpt: command.utteranceExcerpt,
                highlightPhrases: command.highlightPhrases
            )
        case .goto, .mark:
            return command
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(2))
                .locale(Self.logNumberLocale)
        )
    }
}
