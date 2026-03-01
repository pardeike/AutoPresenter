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

            // Marks are non-navigation feedback and should feel immediate once validated.
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

        if shouldBypassDwellForExplicitNavigationCue(command: normalized) {
            pendingCandidate = nil
            lastAcceptedAt = now
            return GateDecision(accepted: true, reason: "accepted explicit navigation cue", command: normalized)
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

    private func shouldBypassDwellForExplicitNavigationCue(command: SlideCommand) -> Bool {
        guard command.action == .next || command.action == .previous else {
            return false
        }

        guard let cue = explicitNavigationCue(from: command) else {
            return false
        }

        switch command.action {
        case .next:
            return isExplicitNextSlideCue(cue)
        case .previous:
            return isExplicitPreviousSlideCue(cue)
        case .goto, .mark, .stay:
            return false
        }
    }

    private func explicitNavigationCue(from command: SlideCommand) -> String? {
        let sourceText: String?
        if let excerpt = command.utteranceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !excerpt.isEmpty {
            sourceText = excerpt
        } else {
            let rationale = command.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            sourceText = rationale.isEmpty ? nil : rationale
        }

        guard let sourceText else {
            return nil
        }

        let normalized = sourceText
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let trimmed = trimPolitenessFromCue(normalized)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func trimPolitenessFromCue(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "please ",
            "can you ",
            "could you ",
            "would you ",
            "will you "
        ]
        let suffixes = [
            " please",
            " now",
            " thanks",
            " thank you"
        ]

        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where output.hasPrefix(prefix) {
                output.removeFirst(prefix.count)
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
            for suffix in suffixes where output.hasSuffix(suffix) {
                output.removeLast(suffix.count)
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return output
    }

    private func isExplicitNextSlideCue(_ cue: String) -> Bool {
        let cues: Set<String> = [
            "next slide",
            "next page",
            "go next slide",
            "go to next slide",
            "go to the next slide",
            "move to next slide",
            "move to the next slide",
            "show next slide",
            "advance to next slide"
        ]
        return cues.contains(cue)
    }

    private func isExplicitPreviousSlideCue(_ cue: String) -> Bool {
        let cues: Set<String> = [
            "previous slide",
            "prev slide",
            "previous page",
            "go to previous slide",
            "go to the previous slide",
            "move to previous slide",
            "move to the previous slide",
            "show previous slide",
            "go back one slide"
        ]
        return cues.contains(cue)
    }

    private func format(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(2))
                .locale(Self.logNumberLocale)
        )
    }
}
