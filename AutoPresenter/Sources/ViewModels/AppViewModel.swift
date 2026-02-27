import AVFoundation
import AppKit
import Combine
import Foundation
import WebKit

enum AppBuildFlags {
    // Build-time switch for main-window diagnostics UI.
    static let debugTextLogInMainWindow = false
    static let strictFullscreenAudienceMode = true
}

enum RealtimeSessionPhase: String, Sendable {
    case idle
    case starting
    case connecting
    case listening
    case speaking
    case processing
    case stopped
    case error

    var displayLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting"
        case .connecting:
            return "Connecting"
        case .listening:
            return "Listening"
        case .speaking:
            return "Speaking"
        case .processing:
            return "Processing"
        case .stopped:
            return "Stopped"
        case .error:
            return "Error"
        }
    }

    var showsActiveRecordingControl: Bool {
        switch self {
        case .starting, .connecting, .listening, .speaking, .processing:
            return true
        case .idle, .stopped, .error:
            return false
        }
    }
}

enum ActivityFeedLevel: String, Sendable {
    case info
    case success
    case warning
    case error
}

struct ActivityFeedEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let title: String
    let detail: String?
    let level: ActivityFeedLevel
}

@MainActor
final class AppViewModel: ObservableObject {
    private static let logNumberLocale = Locale(identifier: "en_US_POSIX")

    @Published var apiKey: String = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    @Published var model: String = "gpt-realtime"
    @Published var deckFilePath: String = ""

    @Published var currentSlideIndex: Int = 1

    @Published private(set) var deck: PresentationDeck?
    @Published private(set) var loadedDeckURL: URL?
    @Published private(set) var isSessionActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var sessionPhase: RealtimeSessionPhase = .idle
    @Published private(set) var connectionState = "idle"
    @Published private(set) var statusLine = "Ready"
    @Published private(set) var isSpeechDetected = false
    @Published private(set) var highlightedPhrasesBySlide: [Int: [String]] = [:]
    @Published private(set) var markedSegmentIndicesBySlide: [Int: Set<Int>] = [:]

    let bridge: RealtimeWebBridge

    private let settings: AppSettings
    private let tokenService = OpenAIRealtimeTokenService()
    private let safetyGate = CommandSafetyGate()
    private let webViewHost = RealtimeWebViewHostWindow()
    private let maxLogEntries = 600
    private let maxActivityEntries = 300
    private let logFileURL = AppViewModel.resolveLogFileURL()
    @Published private var logEntries: [String] = []
    @Published private var activityEntries: [ActivityFeedEntry] = []
    private var realtimeActivityToken: NSObjectProtocol?
    private var didReportLogFileError = false

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(settings: AppSettings, bootstrapExampleDeck: Bool = true) {
        self.settings = settings
        bridge = RealtimeWebBridge()
        bridge.onMessage = { [weak self] payload in
            self?.handleBridgePayload(payload)
        }
        webViewHost.attach(bridge.webView)
        prepareLogFileIfNeeded()
        loadAPIKeyFromKnownLocations()
        if bootstrapExampleDeck {
            bootstrapDeckPath()
        }
        if let logFileURL {
            appendLog("Mirroring command log to \(logFileURL.path)")
        }
        appendLog("AutoPresenter initialized")
        appendActivity("AutoPresenter ready")
    }

    var deckSlideCount: Int {
        deck?.slides.count ?? 0
    }

    var canGoPrevious: Bool {
        guard let deck else { return false }
        return currentSlideIndex > deck.firstSlideIndex
    }

    var canGoNext: Bool {
        guard let deck else { return false }
        return currentSlideIndex < deck.lastSlideIndex
    }

    var activeSlideTitle: String {
        guard let deck, let slide = deck.slide(at: currentSlideIndex) else {
            return "No slide loaded"
        }
        return slide.title
    }

    var logLines: [String] {
        logEntries
    }

    var activityFeed: [ActivityFeedEntry] {
        activityEntries
    }

    var usesDebugTextLogInMainWindow: Bool {
        AppBuildFlags.debugTextLogInMainWindow
    }

    var canToggleSession: Bool {
        !isStarting && !isStopping
    }

    var isRecordingControlActive: Bool {
        sessionPhase.showsActiveRecordingControl
    }

    var isSessionTransitioning: Bool {
        isStopping || sessionPhase == .starting || sessionPhase == .connecting
    }

    var currentSlideHighlightPhrases: [String] {
        highlightedPhrasesBySlide[currentSlideIndex] ?? []
    }

    var currentSlideMarkedSegmentIndices: Set<Int> {
        markedSegmentIndicesBySlide[currentSlideIndex] ?? []
    }

    func chooseDeckFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            deckFilePath = url.path
            loadDeckFromPath()
        }
    }

    func loadDeckFromPath() {
        let trimmedPath = deckFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            statusLine = "Deck path is empty"
            appendLog("Deck load skipped: empty path")
            return
        }

        do {
            let url = URL(fileURLWithPath: trimmedPath)
            let loadedDeck = try PresentationDeckLoader.load(from: url)
            applyLoadedDeck(loadedDeck, sourceURL: url, sourceDescription: trimmedPath)
        } catch {
            statusLine = "Failed to load deck"
            appendLog("Deck load failed: \(error.localizedDescription)")
        }
    }

    func loadDeckFromData(_ data: Data, sourceURL: URL?) {
        do {
            let loadedDeck = try PresentationDeckLoader.load(from: data)
            let sourceDescription = sourceURL?.path ?? "document data"
            applyLoadedDeck(loadedDeck, sourceURL: sourceURL, sourceDescription: sourceDescription)
        } catch {
            statusLine = "Failed to load deck"
            appendLog("Deck load failed: \(error.localizedDescription)")
        }
    }

    func setLoadedDeckURL(_ url: URL?) {
        loadedDeckURL = url
        if let url {
            deckFilePath = url.path
        }
    }

    func previousSlide() {
        guard let deck else { return }
        let suppressLoggingForArrowKey = isCurrentEventArrowKeyNavigation()
        let previous = currentSlideIndex
        currentSlideIndex = deck.clampedSlideIndex(currentSlideIndex - 1)
        guard currentSlideIndex != previous else { return }
        if !suppressLoggingForArrowKey {
            appendLog("Slide set to \(currentSlideIndex)")
            appendActivity("Moved to slide \(currentSlideIndex)", detail: "Manual previous")
        }
        pushContextUpdate(reason: "manual previous", shouldLogResult: !suppressLoggingForArrowKey)
    }

    func nextSlide() {
        guard let deck else { return }
        let suppressLoggingForArrowKey = isCurrentEventArrowKeyNavigation()
        let previous = currentSlideIndex
        currentSlideIndex = deck.clampedSlideIndex(currentSlideIndex + 1)
        guard currentSlideIndex != previous else { return }
        if !suppressLoggingForArrowKey {
            appendLog("Slide set to \(currentSlideIndex)")
            appendActivity("Moved to slide \(currentSlideIndex)", detail: "Manual next")
        }
        pushContextUpdate(reason: "manual next", shouldLogResult: !suppressLoggingForArrowKey)
    }

    func applyContextUpdate() {
        guard isSessionActive else {
            appendActivity("Context refresh skipped", detail: "Stream is not active", level: .warning)
            appendLog("Context update skipped: stream inactive")
            return
        }
        pushContextUpdate(reason: "manual refresh")
        appendActivity("Context refreshed", detail: "Current slide instructions sent")
    }

    func clearLog() {
        logEntries.removeAll(keepingCapacity: true)
        truncateLogFile()
        appendLog("Command log cleared")
    }

    func clearVisibleFeed() {
        if usesDebugTextLogInMainWindow {
            clearLog()
        } else {
            activityEntries.removeAll(keepingCapacity: true)
        }
    }

    func startSession() async {
        guard !isStarting else { return }
        guard !isSessionActive else {
            statusLine = "Stream already active"
            appendActivity("Stream already active")
            return
        }
        guard let deck else {
            statusLine = "Load a presentation deck first"
            sessionPhase = .idle
            appendLog("Start blocked: no deck loaded")
            appendActivity("Start blocked", detail: "Load a deck first", level: .warning)
            return
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            statusLine = "OpenAI API key missing"
            sessionPhase = .idle
            appendLog("Start blocked: API key is empty")
            appendActivity("Start blocked", detail: "OpenAI API key missing", level: .warning)
            return
        }

        let micGranted = await requestMicrophoneAccessIfNeeded()
        guard micGranted else {
            statusLine = "Microphone permission denied"
            sessionPhase = .idle
            appendLog("Start blocked: microphone permission denied")
            appendActivity("Start blocked", detail: "Microphone permission denied", level: .warning)
            return
        }

        isStarting = true
        isSpeechDetected = false
        sessionPhase = .starting
        statusLine = "Starting stream..."
        appendActivity("Starting stream")
        defer { isStarting = false }
        beginRealtimeActivityIfNeeded()

        do {
            let clientSecret = try await tokenService.mintClientSecret(apiKey: trimmedKey, model: model)
            let instructions = deck.instructionBlock(currentSlideIndex: currentSlideIndex)
            try await bridge.startSession(clientSecret: clientSecret, model: model, instructions: instructions)
            isSessionActive = true
            connectionState = "connecting"
            sessionPhase = .connecting
            statusLine = "Connecting to Realtime..."
            appendLog("Realtime start request sent")
            appendActivity("Stream start requested", detail: "Connecting to Realtime")
        } catch {
            endRealtimeActivityIfNeeded()
            statusLine = "Start failed"
            sessionPhase = .error
            appendLog("Failed to start Realtime stream: \(error.localizedDescription)")
            appendActivity("Failed to start stream", detail: error.localizedDescription, level: .error)
        }
    }

    func stopSession() async {
        guard !isStopping else { return }
        isStopping = true
        if isSessionActive || sessionPhase.showsActiveRecordingControl {
            statusLine = "Stopping stream..."
        }
        defer { isStopping = false }

        do {
            try await bridge.stopSession()
        } catch {
            appendLog("Stop stream JS error: \(error.localizedDescription)")
            appendActivity("Stop warning", detail: error.localizedDescription, level: .warning)
        }
        isSessionActive = false
        isSpeechDetected = false
        connectionState = "stopped"
        sessionPhase = .stopped
        statusLine = "Stream stopped"
        await safetyGate.reset()
        endRealtimeActivityIfNeeded()
        appendLog("Realtime stream stopped")
        appendActivity("Stream stopped")
    }

    func toggleRealtimeSession() {
        guard canToggleSession else { return }
        Task {
            if isRecordingControlActive || isSessionActive {
                await stopSession()
            } else {
                await startSession()
            }
        }
    }

    private func handleBridgePayload(_ payload: [String: Any]) {
        guard let kind = payload["kind"] as? String else {
            appendLog("Bridge payload missing kind")
            return
        }

        switch kind {
        case "log":
            let levelRaw = payload["level"] as? String ?? "info"
            let level = levelRaw.uppercased()
            let message = payload["message"] as? String ?? "<no message>"
            appendLog("[bridge/\(level)] \(message)")
            if message == "Realtime data channel opened" {
                if isSessionActive {
                    sessionPhase = .listening
                }
                statusLine = "Listening"
                appendActivity("Microphone live", detail: "Speak naturally to drive slides")
            } else if levelRaw.lowercased() == "error" {
                sessionPhase = .error
                statusLine = "Realtime bridge error"
                appendActivity("Bridge error", detail: message, level: .error)
            }
        case "connection":
            let state = payload["state"] as? String ?? "unknown"
            let previousState = connectionState
            connectionState = state
            if state != previousState {
                appendLog("WebRTC state: \(state)")
            }
            applyConnectionStateUpdate(state: state, previousState: previousState)
        case "event":
            guard let event = payload["event"] as? [String: Any] else {
                appendLog("Bridge event payload malformed")
                return
            }
            handleRealtimeEvent(event)
        case "bridge_ready":
            break
        default:
            appendLog("Bridge payload kind not handled: \(kind)")
        }
    }

    private func applyConnectionStateUpdate(state: String, previousState: String) {
        switch state {
        case "connected":
            statusLine = "Listening"
            isSessionActive = true
            isSpeechDetected = false
            sessionPhase = .listening
            beginRealtimeActivityIfNeeded()
            if previousState != "connected" {
                appendActivity("Realtime connected")
            }
        case "closed":
            statusLine = "Stream stopped"
            isSessionActive = false
            isSpeechDetected = false
            sessionPhase = .stopped
            endRealtimeActivityIfNeeded()
            if previousState != "closed" {
                appendActivity("Realtime disconnected")
            }
        case "failed":
            statusLine = "Connection failed"
            isSessionActive = false
            isSpeechDetected = false
            sessionPhase = .error
            endRealtimeActivityIfNeeded()
            if previousState != "failed" {
                appendActivity("Realtime connection failed", level: .error)
            }
        default:
            if (isSessionActive || isStarting) && (state == "connecting" || state == "new" || state == "checking" || state.hasPrefix("ice:")) {
                sessionPhase = .connecting
                statusLine = "Connecting to Realtime..."
            }
        }
    }

    private func handleRealtimeEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else {
            appendLog("Realtime event missing type")
            return
        }

        switch type {
        case "response.output_item.done":
            guard
                let item = event["item"] as? [String: Any],
                let itemType = item["type"] as? String,
                itemType == "function_call",
                let arguments = item["arguments"] as? String
            else {
                return
            }
            handleCommand(argumentsJSON: arguments, source: type)
        case "error":
            let pretty = prettyJSONString(from: event) ?? "<unserializable error payload>"
            appendLog("Realtime error event: \(pretty)")
            sessionPhase = .error
            statusLine = "Realtime error"
            appendActivity("Realtime error", detail: "Model reported an error", level: .error)
        case "input_audio_buffer.speech_started":
            appendLog("Speech detected")
            isSpeechDetected = true
            if isSessionActive {
                sessionPhase = .speaking
                statusLine = "Speaking"
            }
        case "input_audio_buffer.speech_stopped":
            appendLog("Speech ended")
            isSpeechDetected = false
            if isSessionActive {
                sessionPhase = .processing
                statusLine = "Processing speech"
            }
        default:
            break
        }
    }

    private func handleCommand(argumentsJSON: String, source: String) {
        guard let jsonData = argumentsJSON.data(using: .utf8) else {
            appendLog("Command decode failed: invalid UTF-8")
            return
        }

        do {
            let command = try jsonDecoder.decode(SlideCommand.self, from: jsonData)
            Task {
                await evaluateCommand(command, source: source)
            }
            return
        } catch {
            if let recovered = recoverCommandFromPossiblyTruncatedJSON(argumentsJSON) {
                appendLog("Command decode recovered from truncated payload")
                Task {
                    await evaluateCommand(recovered, source: source)
                }
                return
            }

            appendLog("Command decode failed: \(error.localizedDescription)")
            appendLog("Raw command payload: \(argumentsJSON)")
        }
    }

    private func recoverCommandFromPossiblyTruncatedJSON(_ rawJSON: String) -> SlideCommand? {
        var candidate = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.hasPrefix("{") else { return nil }

        if !candidate.hasSuffix("}") {
            candidate.append("}")
        }

        candidate = candidate.replacingOccurrences(
            of: ",\\s*}",
            with: "}",
            options: .regularExpression
        )

        guard hasBalancedUnescapedDoubleQuotes(candidate) else { return nil }
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(SlideCommand.self, from: data)
    }

    private func hasBalancedUnescapedDoubleQuotes(_ text: String) -> Bool {
        var isEscaped = false
        var quoteCount = 0

        for scalar in text.unicodeScalars {
            if isEscaped {
                isEscaped = false
                continue
            }
            if scalar == "\\" {
                isEscaped = true
                continue
            }
            if scalar == "\"" {
                quoteCount += 1
            }
        }

        return quoteCount.isMultiple(of: 2)
    }

    private func evaluateCommand(_ command: SlideCommand, source: String) async {
        defer {
            if isSessionActive, !isSpeechDetected {
                sessionPhase = .listening
                if statusLine == "Processing speech" || statusLine == "Speaking" {
                    statusLine = "Listening"
                }
            }
        }

        let slideIndices = deck?.slideIndices ?? []
        let currentMarkableSegments = deck?.slide(at: currentSlideIndex)?.markableSegments() ?? []

        let (gotoResolvedCommand, gotoRecoveryNote) = recoverGotoTargetIfMissing(
            command: command,
            validSlideIndices: slideIndices
        )
        if let gotoRecoveryNote {
            appendLog("[RECOVERED][\(source)] \(gotoRecoveryNote)")
        }

        let (resolvedCommand, markRecoveryNote) = recoverMarkIndexIfMissing(
            command: gotoResolvedCommand,
            markableSegments: currentMarkableSegments
        )
        if let markRecoveryNote {
            appendLog("[RECOVERED][\(source)] \(markRecoveryNote)")
        }

        applyHighlightPhrases(from: resolvedCommand, source: source)

        let policy = CommandPolicy(
            confidenceThreshold: settings.confidenceThreshold,
            cooldownSeconds: settings.cooldownSeconds,
            dwellSeconds: settings.dwellSeconds
        )

        let decision = await safetyGate.evaluate(command: resolvedCommand, validSlideIndices: slideIndices, policy: policy)
        let commandSummary = summarize(command: decision.command)

        if decision.accepted {
            appendLog("[ACCEPTED][\(source)] \(commandSummary) | \(decision.reason)")
            appendActivity(activitySummary(for: decision.command), level: .success)
            await applyAcceptedCommand(decision.command, source: source)
        } else if decision.command.action == .stay && decision.reason == "model requested stay" {
            statusLine = "Model hold: no slide change"
            appendLog("[NOOP][\(source)] \(commandSummary) | \(decision.reason)")
            appendActivity("AI held position", detail: "No slide change")
        } else {
            appendLog("[REJECTED][\(source)] \(commandSummary) | \(decision.reason)")
            appendActivity(
                "AI action rejected",
                detail: "Reason: \(friendlyDecisionReason(decision.reason))",
                level: .warning
            )
        }
    }

    private func applyAcceptedCommand(_ command: SlideCommand, source: String) async {
        guard let deck else {
            statusLine = "Accepted command ignored: no deck"
            appendLog("[APPLIED][\(source)] ignored accepted \(command.action.rawValue): no deck loaded")
            appendActivity("Accepted action ignored", detail: "No deck loaded", level: .warning)
            return
        }

        let previousIndex = currentSlideIndex

        switch command.action {
        case .next:
            let nextIndex = deck.clampedSlideIndex(currentSlideIndex + 1)
            if nextIndex == previousIndex {
                statusLine = "Accepted next (already at last slide)"
                appendLog("[APPLIED][\(source)] next ignored: already at last slide \(previousIndex)")
                appendActivity("AI requested next", detail: "Already on last slide")
                return
            }

            currentSlideIndex = nextIndex
            statusLine = "Accepted next: slide \(nextIndex)"
            appendLog("[APPLIED][\(source)] moved to slide \(nextIndex) via next")
            appendActivity("Moved to slide \(nextIndex)", detail: "AI requested next")
            pushContextUpdate(reason: "model next")
        case .previous:
            let previousSlideIndex = deck.clampedSlideIndex(currentSlideIndex - 1)
            if previousSlideIndex == previousIndex {
                statusLine = "Accepted previous (already at first slide)"
                appendLog("[APPLIED][\(source)] previous ignored: already at first slide \(previousIndex)")
                appendActivity("AI requested previous", detail: "Already on first slide")
                return
            }

            currentSlideIndex = previousSlideIndex
            statusLine = "Accepted previous: slide \(previousSlideIndex)"
            appendLog("[APPLIED][\(source)] moved to slide \(previousSlideIndex) via previous")
            appendActivity("Moved to slide \(previousSlideIndex)", detail: "AI requested previous")
            pushContextUpdate(reason: "model previous")
        case .goto:
            guard let targetSlide = command.targetSlide else {
                statusLine = "Accepted goto ignored: missing target"
                appendLog("[APPLIED][\(source)] goto ignored: accepted command missing target_slide")
                appendActivity("AI goto ignored", detail: "Missing destination slide", level: .warning)
                return
            }
            guard deck.slideIndices.contains(targetSlide) else {
                statusLine = "Accepted goto ignored: invalid target"
                appendLog("[APPLIED][\(source)] goto ignored: target \(targetSlide) outside loaded deck")
                appendActivity("AI goto ignored", detail: "Slide \(targetSlide) is not in this deck", level: .warning)
                return
            }
            if targetSlide == previousIndex {
                statusLine = "Accepted goto: already on slide \(targetSlide)"
                appendLog("[APPLIED][\(source)] goto ignored: already on slide \(targetSlide)")
                appendActivity("AI requested slide \(targetSlide)", detail: "Already on that slide")
                return
            }

            currentSlideIndex = targetSlide
            statusLine = "Accepted goto: slide \(targetSlide)"
            appendLog("[APPLIED][\(source)] moved to slide \(targetSlide) via goto")
            appendActivity("Moved to slide \(targetSlide)", detail: "AI requested goto")
            pushContextUpdate(reason: "model goto")
        case .mark:
            guard let markIndex = command.markIndex else {
                statusLine = "Accepted mark ignored: missing mark_index"
                appendLog("[APPLIED][\(source)] mark ignored: accepted command missing mark_index")
                appendActivity("AI mark ignored", detail: "Missing segment index", level: .warning)
                return
            }
            let slideIndex = currentSlideIndex
            guard let slide = deck.slide(at: slideIndex) else {
                statusLine = "Accepted mark ignored: no current slide"
                appendLog("[APPLIED][\(source)] mark ignored: no current slide loaded")
                appendActivity("AI mark ignored", detail: "No current slide", level: .warning)
                return
            }
            let segments = slide.markableSegments()
            let validIndices = Set(segments.map(\.index))
            guard validIndices.contains(markIndex) else {
                statusLine = "Accepted mark ignored: invalid index"
                appendLog("[APPLIED][\(source)] mark ignored: mark_index \(markIndex) outside current slide segments")
                appendActivity("AI mark ignored", detail: "Segment \(markIndex) is not on this slide", level: .warning)
                return
            }

            var markedIndices = markedSegmentIndicesBySlide[slideIndex] ?? []
            let isNewMark = markedIndices.insert(markIndex).inserted
            markedSegmentIndicesBySlide[slideIndex] = markedIndices
            statusLine = "Marked segment \(markIndex) on slide \(slideIndex)"
            if isNewMark {
                appendLog("[APPLIED][\(source)] marked segment \(markIndex) on slide \(slideIndex)")
                appendActivity("Marked covered content", detail: "Slide \(slideIndex), segment \(markIndex)")
            } else {
                appendLog("[APPLIED][\(source)] segment \(markIndex) already marked on slide \(slideIndex)")
                appendActivity("Segment already marked", detail: "Slide \(slideIndex), segment \(markIndex)")
            }

            let nonTitleIndices = Set(segments.filter { $0.kind != "title" }.map(\.index))
            let requiredIndicesForAdvance = nonTitleIndices.isEmpty ? validIndices : nonTitleIndices
            let allRequiredMarked = !requiredIndicesForAdvance.isEmpty && markedIndices.isSuperset(of: requiredIndicesForAdvance)
            let lastSegmentIndex = segments.map(\.index).max()
            let markedLastSegment = (lastSegmentIndex == markIndex)
            if allRequiredMarked || markedLastSegment {
                let nextIndex = deck.clampedSlideIndex(slideIndex + 1)
                if nextIndex != slideIndex {
                    let shouldDelayAdvance =
                        markedLastSegment
                        && (
                            (command.highlightPhrases?.isEmpty == false)
                            || (command.utteranceExcerpt?.isEmpty == false)
                        )
                    if shouldDelayAdvance {
                        try? await Task.sleep(for: .seconds(1))
                        guard currentSlideIndex == slideIndex else {
                            appendLog("[AUTO][\(source)] auto-advance canceled: slide changed during highlight hold")
                            return
                        }
                    }
                    currentSlideIndex = nextIndex
                    statusLine = "All segments marked on slide \(slideIndex): auto-advanced to \(nextIndex)"
                    if markedLastSegment && !allRequiredMarked {
                        appendLog("[AUTO][\(source)] last segment \(markIndex) marked on slide \(slideIndex); advanced to slide \(nextIndex)")
                    } else if nonTitleIndices.isEmpty {
                        appendLog("[AUTO][\(source)] all \(validIndices.count) segments marked on slide \(slideIndex); advanced to slide \(nextIndex)")
                    } else {
                        appendLog("[AUTO][\(source)] all non-title segments marked on slide \(slideIndex); advanced to slide \(nextIndex)")
                    }
                    appendActivity(
                        "Auto-advanced to slide \(nextIndex)",
                        detail: "Slide \(slideIndex) coverage complete"
                    )
                    pushContextUpdate(reason: "auto advance after full coverage")
                } else {
                    statusLine = "All segments marked on final slide \(slideIndex)"
                    if markedLastSegment && !allRequiredMarked {
                        appendLog("[AUTO][\(source)] last segment \(markIndex) marked on final slide \(slideIndex)")
                    } else if nonTitleIndices.isEmpty {
                        appendLog("[AUTO][\(source)] all \(validIndices.count) segments marked on final slide \(slideIndex)")
                    } else {
                        appendLog("[AUTO][\(source)] all non-title segments marked on final slide \(slideIndex)")
                    }
                    appendActivity("Slide coverage complete", detail: "Final slide \(slideIndex)")
                }
            }
        case .stay:
            statusLine = "Accepted stay: no slide change"
            appendLog("[APPLIED][\(source)] stay applied: no slide change (slide \(currentSlideIndex))")
            appendActivity("AI chose to stay", detail: "No slide change")
        }
    }

    private func summarize(command: SlideCommand) -> String {
        var parts = [
            "action=\(command.action.rawValue)",
            "confidence=\(formatLogNumber(command.confidence))"
        ]
        if let targetSlide = command.targetSlide {
            parts.append("target=\(targetSlide)")
        }
        if let markIndex = command.markIndex {
            parts.append("mark=\(markIndex)")
        }
        if let highlightPhrases = command.highlightPhrases, !highlightPhrases.isEmpty {
            parts.append("highlights=\(highlightPhrases.count)")
        }
        if !command.rationale.isEmpty {
            parts.append("rationale=\(command.rationale)")
        }
        return parts.joined(separator: " ")
    }

    private func applyHighlightPhrases(from command: SlideCommand, source: String) {
        let phraseCandidates = command.highlightPhrases ?? []
        let candidates: [String]
        if phraseCandidates.isEmpty {
            candidates = command.utteranceExcerpt.map { [$0] } ?? []
        } else {
            candidates = phraseCandidates
        }
        let sanitized = sanitizeHighlightPhrases(candidates)

        guard !sanitized.isEmpty else {
            return
        }

        let slideIndex = currentSlideIndex
        var existing = highlightedPhrasesBySlide[slideIndex] ?? []
        var existingKeys = Set(existing.map { $0.lowercased() })
        var addedCount = 0

        for phrase in sanitized {
            let key = phrase.lowercased()
            guard !existingKeys.contains(key) else {
                continue
            }
            existing.append(phrase)
            existingKeys.insert(key)
            addedCount += 1
        }

        guard addedCount > 0 else {
            return
        }

        let maxHighlightsPerSlide = 20
        if existing.count > maxHighlightsPerSlide {
            existing = Array(existing.suffix(maxHighlightsPerSlide))
        }
        highlightedPhrasesBySlide[slideIndex] = existing
        appendLog("[HIGHLIGHT][\(source)] slide \(slideIndex) +\(addedCount)")
    }

    private func sanitizeHighlightPhrases(_ phrases: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []

        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else {
                continue
            }
            guard trimmed.count <= 120 else {
                continue
            }

            let key = trimmed.lowercased()
            guard !seen.contains(key) else {
                continue
            }

            seen.insert(key)
            output.append(trimmed)
        }

        let maxHighlightsPerTurn = 5
        if output.count > maxHighlightsPerTurn {
            return Array(output.prefix(maxHighlightsPerTurn))
        }
        return output
    }

    private func recoverGotoTargetIfMissing(
        command: SlideCommand,
        validSlideIndices: Set<Int>
    ) -> (command: SlideCommand, recoveryNote: String?) {
        guard command.action == .goto else {
            return (command, nil)
        }

        guard command.targetSlide == nil else {
            return (command, nil)
        }

        guard let deck else {
            return (command, nil)
        }

        let analysisText = [command.utteranceExcerpt, command.rationale]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        guard !analysisText.isEmpty else {
            return (command, nil)
        }

        let inferredTarget: Int?
        let sourceLabel: String

        if mentionsFirstSlide(in: analysisText) {
            inferredTarget = deck.firstSlideIndex
            sourceLabel = "first-slide phrase"
        } else if mentionsLastSlide(in: analysisText) {
            inferredTarget = deck.lastSlideIndex
            sourceLabel = "last-slide phrase"
        } else if let referencedNumber = extractReferencedSlideNumber(from: analysisText) {
            inferredTarget = referencedNumber
            sourceLabel = "numeric slide reference"
        } else {
            inferredTarget = nil
            sourceLabel = ""
        }

        guard let inferredTarget, validSlideIndices.contains(inferredTarget) else {
            return (command, nil)
        }

        let recoveredCommand = SlideCommand(
            action: .goto,
            targetSlide: inferredTarget,
            markIndex: nil,
            confidence: command.confidence,
            rationale: command.rationale,
            utteranceExcerpt: command.utteranceExcerpt,
            highlightPhrases: command.highlightPhrases
        )

        let note = "Inferred goto target=\(inferredTarget) from \(sourceLabel)"
        return (recoveredCommand, note)
    }

    private func recoverMarkIndexIfMissing(
        command: SlideCommand,
        markableSegments: [SlideMarkSegment]
    ) -> (command: SlideCommand, recoveryNote: String?) {
        guard command.action == .mark else {
            return (command, nil)
        }

        guard command.markIndex == nil else {
            return (command, nil)
        }

        let validMarkIndices = Set(markableSegments.map(\.index))
        guard !validMarkIndices.isEmpty else {
            return (command, nil)
        }

        let analysisText = [command.utteranceExcerpt, command.rationale]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        if !analysisText.isEmpty,
           let inferredMarkIndex = extractReferencedMarkNumber(from: analysisText),
           validMarkIndices.contains(inferredMarkIndex) {
            let recoveredCommand = SlideCommand(
                action: .mark,
                targetSlide: nil,
                markIndex: inferredMarkIndex,
                confidence: command.confidence,
                rationale: command.rationale,
                utteranceExcerpt: command.utteranceExcerpt,
                highlightPhrases: command.highlightPhrases
            )
            return (recoveredCommand, "Inferred mark_index=\(inferredMarkIndex) from numeric reference")
        }

        if let contentInferredIndex = inferMarkIndexFromContent(
            command: command,
            markableSegments: markableSegments
        ) {
            let recoveredCommand = SlideCommand(
                action: .mark,
                targetSlide: nil,
                markIndex: contentInferredIndex,
                confidence: command.confidence,
                rationale: command.rationale,
                utteranceExcerpt: command.utteranceExcerpt,
                highlightPhrases: command.highlightPhrases
            )
            return (recoveredCommand, "Inferred mark_index=\(contentInferredIndex) from slide text match")
        }

        if !analysisText.isEmpty,
           let hintedMarkIndex = inferMarkIndexFromRationaleHints(
               analysisText,
               markableSegments: markableSegments
           ) {
            let recoveredCommand = SlideCommand(
                action: .mark,
                targetSlide: nil,
                markIndex: hintedMarkIndex,
                confidence: command.confidence,
                rationale: command.rationale,
                utteranceExcerpt: command.utteranceExcerpt,
                highlightPhrases: command.highlightPhrases
            )
            return (recoveredCommand, "Inferred mark_index=\(hintedMarkIndex) from rationale hint")
        }

        if let fallbackIndex = fallbackMarkIndex(from: markableSegments) {
            let recoveredCommand = SlideCommand(
                action: .mark,
                targetSlide: nil,
                markIndex: fallbackIndex,
                confidence: command.confidence,
                rationale: command.rationale,
                utteranceExcerpt: command.utteranceExcerpt,
                highlightPhrases: command.highlightPhrases
            )
            return (recoveredCommand, "Inferred mark_index=\(fallbackIndex) from deterministic fallback")
        }
        return (command, nil)
    }

    private func mentionsFirstSlide(in text: String) -> Bool {
        text.contains("first slide")
            || text.contains("slide one")
            || text.contains("slide 1")
            || text.contains("back to the start")
            || text.contains("go to the start")
            || text.contains("back to start")
            || text.contains("start of the deck")
    }

    private func mentionsLastSlide(in text: String) -> Bool {
        text.contains("last slide")
            || text.contains("final slide")
            || text.contains("go to the end")
            || text.contains("end of the deck")
    }

    private func extractReferencedSlideNumber(from text: String) -> Int? {
        let patterns = [
            #"(?i)\bslide\s*(?:number\s*)?(\d{1,3})\b"#,
            #"(?i)\b(\d{1,3})(?:st|nd|rd|th)\s+slide\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else {
                continue
            }

            guard
                match.numberOfRanges > 1,
                let numberRange = Range(match.range(at: 1), in: text),
                let number = Int(text[numberRange])
            else {
                continue
            }

            return number
        }

        return nil
    }

    private func extractReferencedMarkNumber(from text: String) -> Int? {
        let patterns = [
            #"(?i)\bmark\s*(?:segment\s*)?(\d{1,3})\b"#,
            #"(?i)\bsegment\s*(\d{1,3})\b"#,
            #"(?i)\bhighlight\s*(?:segment\s*)?(\d{1,3})\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else {
                continue
            }

            guard
                match.numberOfRanges > 1,
                let numberRange = Range(match.range(at: 1), in: text),
                let number = Int(text[numberRange])
            else {
                continue
            }

            return number
        }

        return nil
    }

    private func inferMarkIndexFromContent(
        command: SlideCommand,
        markableSegments: [SlideMarkSegment]
    ) -> Int? {
        guard !markableSegments.isEmpty else {
            return nil
        }

        var candidatePhrases = sanitizeHighlightPhrases(command.highlightPhrases ?? [])
        if let excerpt = command.utteranceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !excerpt.isEmpty {
            candidatePhrases.append(excerpt)
        }
        let rationale = command.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rationale.isEmpty {
            candidatePhrases.append(rationale)
        }

        var dedupedCandidates: [String] = []
        var seenCandidates: Set<String> = []
        for phrase in candidatePhrases {
            let key = phrase.lowercased()
            guard !seenCandidates.contains(key) else {
                continue
            }
            seenCandidates.insert(key)
            dedupedCandidates.append(phrase)
        }

        guard !dedupedCandidates.isEmpty else {
            return nil
        }

        var bestContainment: (index: Int, score: Int)?
        for candidate in dedupedCandidates {
            let normalizedCandidate = normalizeForMarkMatching(candidate)
            guard normalizedCandidate.count >= 2 else {
                continue
            }

            for segment in markableSegments {
                let normalizedSegment = normalizeForMarkMatching(segment.text)
                guard !normalizedSegment.isEmpty else {
                    continue
                }

                if normalizedSegment.contains(normalizedCandidate) || normalizedCandidate.contains(normalizedSegment) {
                    let score = min(normalizedCandidate.count, normalizedSegment.count)
                    if let current = bestContainment {
                        if score > current.score {
                            bestContainment = (segment.index, score)
                        }
                    } else {
                        bestContainment = (segment.index, score)
                    }
                }
            }
        }

        if let bestContainment {
            return bestContainment.index
        }

        var bestOverlap: (index: Int, overlapCount: Int, tokenCount: Int)?
        for candidate in dedupedCandidates {
            let candidateTokens = tokenSet(for: candidate)
            guard candidateTokens.count >= 2 else {
                continue
            }

            for segment in markableSegments {
                let segmentTokens = tokenSet(for: segment.text)
                guard !segmentTokens.isEmpty else {
                    continue
                }

                let overlapCount = candidateTokens.intersection(segmentTokens).count
                guard overlapCount >= 2 else {
                    continue
                }

                let tokenCount = min(candidateTokens.count, segmentTokens.count)
                if let current = bestOverlap {
                    if overlapCount > current.overlapCount
                        || (overlapCount == current.overlapCount && tokenCount > current.tokenCount) {
                        bestOverlap = (segment.index, overlapCount, tokenCount)
                    }
                } else {
                    bestOverlap = (segment.index, overlapCount, tokenCount)
                }
            }
        }

        return bestOverlap?.index
    }

    private func inferMarkIndexFromRationaleHints(
        _ analysisText: String,
        markableSegments: [SlideMarkSegment]
    ) -> Int? {
        guard !analysisText.isEmpty else {
            return nil
        }
        guard !markableSegments.isEmpty else {
            return nil
        }

        if analysisText.contains("subtitle"),
           let index = firstMarkIndex(ofKindContaining: "subtitle", in: markableSegments) {
            return index
        }
        if analysisText.contains("title"),
           let index = firstMarkIndex(ofKindContaining: "title", in: markableSegments) {
            return index
        }
        if analysisText.contains("quote"),
           let index = firstMarkIndex(ofKindContaining: "quote", in: markableSegments) {
            return index
        }
        if analysisText.contains("attribution"),
           let index = firstMarkIndex(ofKindContaining: "attribution", in: markableSegments) {
            return index
        }
        if analysisText.contains("caption"),
           let index = firstMarkIndex(ofKindContaining: "caption", in: markableSegments) {
            return index
        }
        if analysisText.contains("image"),
           let index = firstMarkIndex(ofKindContaining: "image", in: markableSegments) {
            return index
        }
        if analysisText.contains("bullet"),
           let index = inferBulletMarkIndex(from: analysisText, markableSegments: markableSegments) {
            return index
        }

        return nil
    }

    private func inferBulletMarkIndex(
        from text: String,
        markableSegments: [SlideMarkSegment]
    ) -> Int? {
        let bulletSegments = markableSegments.filter { $0.kind.contains("bullet") }
        guard !bulletSegments.isEmpty else {
            return nil
        }

        let requestedOrdinal = extractBulletOrdinal(from: text)
        guard let requestedOrdinal,
              requestedOrdinal > 0,
              requestedOrdinal <= bulletSegments.count else {
            return nil
        }

        return bulletSegments[requestedOrdinal - 1].index
    }

    private func extractBulletOrdinal(from text: String) -> Int? {
        if let regex = try? NSRegularExpression(pattern: #"(?i)\b(\d{1,3})(?:st|nd|rd|th)?\s+bullet\b"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let numberRange = Range(match.range(at: 1), in: text),
               let value = Int(text[numberRange]) {
                return value
            }
        }

        let ordinalWords: [(String, Int)] = [
            ("first", 1),
            ("second", 2),
            ("third", 3),
            ("fourth", 4),
            ("fifth", 5),
            ("sixth", 6),
            ("seventh", 7),
            ("eighth", 8),
            ("ninth", 9),
            ("tenth", 10),
            ("eleventh", 11),
            ("twelfth", 12)
        ]

        for (word, value) in ordinalWords {
            if text.contains("\(word) bullet") || text.contains("bullet \(word)") {
                return value
            }
        }

        return nil
    }

    private func firstMarkIndex(
        ofKindContaining kindSubstring: String,
        in markableSegments: [SlideMarkSegment]
    ) -> Int? {
        markableSegments.first { $0.kind.contains(kindSubstring) }?.index
    }

    private func fallbackMarkIndex(from markableSegments: [SlideMarkSegment]) -> Int? {
        guard !markableSegments.isEmpty else {
            return nil
        }

        let existingMarks = markedSegmentIndicesBySlide[currentSlideIndex] ?? []
        if let firstUnmarked = markableSegments.first(where: { !existingMarks.contains($0.index) }) {
            return firstUnmarked.index
        }

        return markableSegments.first?.index
    }

    private func normalizeForMarkMatching(_ text: String) -> String {
        let lowercased = text.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        return lowercased
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func tokenSet(for text: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        let tokens = text.lowercased()
            .components(separatedBy: separators)
            .filter { $0.count >= 3 }
        return Set(tokens)
    }

    private func formatLogNumber(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(2))
                .locale(Self.logNumberLocale)
        )
    }

    private func activitySummary(for command: SlideCommand) -> String {
        switch command.action {
        case .next:
            return "Move to the next slide"
        case .previous:
            return "Move to the previous slide"
        case .goto:
            if let targetSlide = command.targetSlide {
                return "Jump to slide \(targetSlide)"
            }
            return "Jump to a specific slide"
        case .mark:
            if let markIndex = command.markIndex {
                return "Mark segment \(markIndex) as covered"
            }
            return "Mark a covered segment"
        case .stay:
            return "Stay on the current slide"
        }
    }

    private func friendlyDecisionReason(_ reason: String) -> String {
        let lowercased = reason.lowercased()
        if lowercased.contains("confidence") {
            return "Low confidence"
        }
        if lowercased.contains("cooldown") {
            return "Cooldown is active"
        }
        if lowercased.contains("dwell") {
            return "Waiting for stronger confirmation"
        }
        if lowercased.contains("invalid") {
            return "Command did not match the current deck state"
        }
        if lowercased.contains("model requested stay") {
            return "Model requested no slide change"
        }
        return reason
    }

    private func appendActivity(
        _ title: String,
        detail: String? = nil,
        level: ActivityFeedLevel = .info
    ) {
        let entry = ActivityFeedEntry(
            timestamp: Date(),
            title: title,
            detail: detail,
            level: level
        )
        activityEntries.append(entry)
        if activityEntries.count > maxActivityEntries {
            let overflow = activityEntries.count - maxActivityEntries
            activityEntries.removeFirst(overflow)
        }
    }

    private func pushContextUpdate(reason: String, shouldLogResult: Bool = true) {
        guard let deck else { return }
        guard isSessionActive else { return }

        let instructions = deck.instructionBlock(currentSlideIndex: currentSlideIndex)
        Task {
            do {
                try await bridge.updateInstructions(instructions)
                if shouldLogResult {
                    appendLog("Context updated for slide \(currentSlideIndex) (\(reason))")
                }
            } catch {
                if shouldLogResult {
                    appendLog("Context update failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func isCurrentEventArrowKeyNavigation() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        guard event.type == .keyDown else { return false }
        return event.keyCode == 123 || event.keyCode == 124
    }

    private func bootstrapDeckPath() {
        let normalizedMeetupDeck = URL(fileURLWithPath: "/Users/ap/Desktop/Meetup136.json")
        if FileManager.default.fileExists(atPath: normalizedMeetupDeck.path) {
            deckFilePath = normalizedMeetupDeck.path
            loadDeckFromPath()
            appendLog("Loaded normalized Meetup deck from Desktop")
            return
        }

        let externalExample = URL(fileURLWithPath: "/Users/ap/Projects/MeTube/documentation/presentation.json")
        if FileManager.default.fileExists(atPath: externalExample.path) {
            deckFilePath = externalExample.path
            loadDeckFromPath()
            appendLog("Loaded example deck from MeTube documentation")
            return
        }

        let workspaceSample = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("presentation.sample.json")

        if FileManager.default.fileExists(atPath: workspaceSample.path) {
            deckFilePath = workspaceSample.path
            loadDeckFromPath()
            return
        }

        if let bundledSample = Bundle.main.url(forResource: "presentation.sample", withExtension: "json") {
            deckFilePath = bundledSample.path
            loadDeckFromPath()
        }
    }

    private func loadAPIKeyFromKnownLocations() {
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLog("Using OPENAI_API_KEY from environment")
            return
        }

        let dotFileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".api-keys")
        guard FileManager.default.fileExists(atPath: dotFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: dotFileURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                appendLog("~/.api-keys exists but is not a JSON object")
                return
            }
            guard let loadedKey = object["OPENAI_API_KEY"] as? String else {
                appendLog("~/.api-keys missing OPENAI_API_KEY")
                return
            }
            let trimmedKey = loadedKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else {
                appendLog("OPENAI_API_KEY in ~/.api-keys is empty")
                return
            }
            apiKey = trimmedKey
            appendLog("Loaded OPENAI_API_KEY from ~/.api-keys")
        } catch {
            appendLog("Failed to read ~/.api-keys: \(error.localizedDescription)")
        }
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func beginRealtimeActivityIfNeeded() {
        guard realtimeActivityToken == nil else { return }
        let options: ProcessInfo.ActivityOptions = [
            .userInitiated,
            .idleSystemSleepDisabled
        ]
        realtimeActivityToken = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: "AutoPresenter Realtime session active"
        )
    }

    private func endRealtimeActivityIfNeeded() {
        guard let realtimeActivityToken else { return }
        ProcessInfo.processInfo.endActivity(realtimeActivityToken)
        self.realtimeActivityToken = nil
    }

    private func appendLog(_ message: String) {
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        logEntries.append(entry)
        if logEntries.count > maxLogEntries {
            let overflow = logEntries.count - maxLogEntries
            logEntries.removeFirst(overflow)
        }
        appendLogToFile(entry)
    }

    private func prepareLogFileIfNeeded() {
        guard let logFileURL else { return }

        do {
            let directoryURL = logFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: Data())
            }
            try Data().write(to: logFileURL, options: .atomic)

            let runHeader = "----- Run started \(Self.fileTimestampFormatter.string(from: Date())) -----"
            appendRawLineToLogFile(runHeader)
        } catch {
            reportLogFileErrorOnce("Failed to prepare log file: \(error.localizedDescription)")
        }
    }

    private func truncateLogFile() {
        guard let logFileURL else { return }

        do {
            try Data().write(to: logFileURL, options: .atomic)
        } catch {
            reportLogFileErrorOnce("Failed to truncate log file: \(error.localizedDescription)")
        }
    }

    private func appendLogToFile(_ entry: String) {
        appendRawLineToLogFile(entry)
    }

    private func appendRawLineToLogFile(_ line: String) {
        guard let logFileURL else { return }
        let payload = Data((line + "\n").utf8)

        do {
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: Data())
            }
            let fileHandle = try FileHandle(forWritingTo: logFileURL)
            defer {
                try? fileHandle.close()
            }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: payload)
        } catch {
            reportLogFileErrorOnce("Failed to append to log file: \(error.localizedDescription)")
        }
    }

    private func reportLogFileErrorOnce(_ message: String) {
        guard !didReportLogFileError else { return }
        didReportLogFileError = true
        NSLog("AutoPresenter log mirror error: %@", message)
    }

    private func applyLoadedDeck(_ loadedDeck: PresentationDeck, sourceURL: URL?, sourceDescription: String) {
        deck = loadedDeck
        highlightedPhrasesBySlide.removeAll(keepingCapacity: true)
        markedSegmentIndicesBySlide.removeAll(keepingCapacity: true)
        loadedDeckURL = sourceURL
        if let sourceURL {
            deckFilePath = sourceURL.path
            if sourceURL.isFileURL {
                UserDefaults.standard.set(sourceURL.path, forKey: Self.lastOpenedDeckPathDefaultsKey)
            }
        }
        currentSlideIndex = loadedDeck.clampedSlideIndex(currentSlideIndex)
        statusLine = "Loaded deck: \(loadedDeck.presentationTitle)"
        appendLog("Loaded deck from \(sourceDescription) with \(loadedDeck.slides.count) slides")
        appendActivity(
            "Deck loaded",
            detail: "\(loadedDeck.presentationTitle) (\(loadedDeck.slides.count) slides)",
            level: .success
        )
        pushContextUpdate(reason: "deck load")
    }

    private func prettyJSONString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let lastOpenedDeckPathDefaultsKey = "lastOpenedDeckPath"
    private static let logFileName = "runtime/command-log.txt"

    @discardableResult
    func restoreLastOpenedDeckIfAvailable() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: Self.lastOpenedDeckPathDefaultsKey) else {
            return false
        }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return false
        }
        guard FileManager.default.fileExists(atPath: trimmedPath) else {
            UserDefaults.standard.removeObject(forKey: Self.lastOpenedDeckPathDefaultsKey)
            appendLog("Last opened deck path no longer exists: \(trimmedPath)")
            return false
        }

        deckFilePath = trimmedPath
        loadDeckFromPath()
        appendLog("Restored last opened deck from previous session")
        return deck != nil
    }

    private static func resolveLogFileURL() -> URL? {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        var cursor = sourceFileURL.deletingLastPathComponent()

        for _ in 0..<12 {
            let projectFile = cursor.appendingPathComponent("AutoPresenter.xcodeproj")
            if FileManager.default.fileExists(atPath: projectFile.path) {
                return cursor.appendingPathComponent(logFileName)
            }

            let next = cursor.deletingLastPathComponent()
            if next.path == cursor.path {
                break
            }
            cursor = next
        }

        let fallbackRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return fallbackRoot.appendingPathComponent(logFileName)
    }
}
