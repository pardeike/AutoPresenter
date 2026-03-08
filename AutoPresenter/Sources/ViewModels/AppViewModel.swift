import AVFoundation
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
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
    @Published private(set) var hasUnsavedDeckChanges = false
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
    private let maxCommandsPerTurn = 6
    private let preNavigationVisibilityHoldSeconds: Double = 1.0
    private let logFileURL = AppViewModel.resolveLogFileURL()
    @Published private var logEntries: [String] = []
    @Published private var activityEntries: [ActivityFeedEntry] = []
    private var realtimeActivityToken: NSObjectProtocol?
    private var commandProcessingTask: Task<Void, Never>?
    private var settingsChangeToken: AnyCancellable?
    private var realtimeTimingChangeToken: AnyCancellable?
    private var didReportLogFileError = false
    private var lastNewMarkEvent: (slideIndex: Int, at: Date)?
    private var functionCallArgumentsBufferByID: [String: String] = [:]
    private var lastParsedSignatureByFunctionCallID: [String: String] = [:]

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(settings: AppSettings) {
        self.settings = settings
        bridge = RealtimeWebBridge()
        bridge.onMessage = { [weak self] payload in
            self?.handleBridgePayload(payload)
        }
        settingsChangeToken = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        realtimeTimingChangeToken = Publishers.CombineLatest(
            settings.$realtimeSilenceDurationMilliseconds.removeDuplicates(),
            settings.$realtimeMaxOutputTokens.removeDuplicates()
        )
        .dropFirst()
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] _, _ in
            self?.applyRealtimeTimingUpdateIfNeeded()
        }
        webViewHost.attach(bridge.webView)
        prepareLogFileIfNeeded()
        loadAPIKeyFromKnownLocations()
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

    var isMicrophoneHot: Bool {
        switch sessionPhase {
        case .listening, .speaking, .processing:
            return true
        case .idle, .starting, .connecting, .stopped, .error:
            return false
        }
    }

    var currentSlideHighlightPhrases: [String] {
        highlightedPhrasesBySlide[currentSlideIndex] ?? []
    }

    var currentSlideMarkedSegmentIndices: Set<Int> {
        let explicitMarks = markedSegmentIndicesBySlide[currentSlideIndex] ?? []
        guard let currentSlide = deck?.slide(at: currentSlideIndex) else {
            return explicitMarks
        }

        let autoMarkedTitleIndices = Set(
            currentSlide
                .segmentBuckets()
                .ordered
                .filter(\.isTitleKind)
                .map(\.index)
        )
        return explicitMarks.union(autoMarkedTitleIndices)
    }

    var quoteAudioStartDelayMilliseconds: Double {
        settings.quoteAudioStartDelayMilliseconds
    }

    var quoteAudioPostPlaybackWaitMilliseconds: Double {
        settings.quoteAudioPostPlaybackWaitMilliseconds
    }

    func chooseDeckFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            loadDeckFromURL(url)
        }
    }

    func loadDeckFromPath() {
        let trimmedPath = deckFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            statusLine = "Deck path is empty"
            appendLog("Deck load skipped: empty path")
            return
        }
        loadDeckFromURL(URL(fileURLWithPath: trimmedPath))
    }

    func loadDeckFromURL(_ url: URL) {
        do {
            let loadedDeck = try PresentationDeckLoader.load(from: url)
            applyLoadedDeck(loadedDeck, sourceURL: url, sourceDescription: url.path)
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

    func saveDeckToCurrentLocation() {
        guard deck != nil else {
            appendActivity("Save skipped", detail: "No deck loaded", level: .warning)
            appendLog("Save skipped: no deck loaded")
            return
        }
        if let loadedDeckURL {
            persistDeck(to: loadedDeckURL, updateLoadedURL: false)
        } else {
            saveDeckAs()
        }
    }

    func saveDeckAs() {
        guard deck != nil else {
            appendActivity("Save As skipped", detail: "No deck loaded", level: .warning)
            appendLog("Save As skipped: no deck loaded")
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedDeckFileName()

        if let existingDeckURL = currentDeckFileURLForSavePanel() {
            let directoryURL: URL
            if existingDeckURL.hasDirectoryPath {
                directoryURL = existingDeckURL
            } else {
                directoryURL = existingDeckURL.deletingLastPathComponent()
                let existingFileName = existingDeckURL.lastPathComponent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !existingFileName.isEmpty {
                    panel.nameFieldStringValue = existingFileName
                }
            }

            if FileManager.default.fileExists(atPath: directoryURL.path) {
                panel.directoryURL = directoryURL
            }
        }

        guard panel.runModal() == .OK, let saveURL = panel.url else {
            appendLog("Save As cancelled")
            return
        }
        persistDeck(to: saveURL, updateLoadedURL: true)
    }

    var editableSlides: [PresentationSlide] {
        guard let deck else {
            return []
        }
        return deck.slides.sorted { $0.index < $1.index }
    }

    @discardableResult
    func insertNewSlide(afterSlideIndex selectedSlideIndex: Int?) -> Int? {
        guard let deck else {
            return nil
        }
        var slides = deck.slides.sorted { $0.index < $1.index }
        let insertionOffset: Int
        if let selectedSlideIndex,
           let selectedOffset = slides.firstIndex(where: { $0.index == selectedSlideIndex }) {
            insertionOffset = selectedOffset + 1
        } else {
            insertionOffset = slides.count
        }

        slides.insert(Self.makeDefaultSlide(index: insertionOffset + 1), at: insertionOffset)
        let reindexed = Self.reindexedSlides(slides)
        applyEditedSlides(
            reindexed,
            reason: "slide inserted at position \(insertionOffset + 1)"
        )

        let newSelectionIndex = min(max(1, insertionOffset + 1), reindexed.count)
        currentSlideIndex = newSelectionIndex
        return newSelectionIndex
    }

    @discardableResult
    func deleteSlides(withIndices indices: Set<Int>) -> Int? {
        guard let deck, !indices.isEmpty else {
            return nil
        }

        var slides = deck.slides.sorted { $0.index < $1.index }
        slides.removeAll { indices.contains($0.index) }

        if slides.isEmpty {
            slides = [Self.makeDefaultSlide(index: 1)]
        }

        let reindexed = Self.reindexedSlides(slides)
        applyEditedSlides(reindexed, reason: "deleted \(indices.count) slide(s)")

        let preferredIndex = indices.min() ?? 1
        let nextSelection = min(max(1, preferredIndex), reindexed.count)
        currentSlideIndex = nextSelection
        return nextSelection
    }

    func moveSlides(fromOffsets: IndexSet, toOffset: Int) -> [Int] {
        guard let deck else {
            return []
        }
        var slides = deck.slides.sorted { $0.index < $1.index }
        Self.moveElements(in: &slides, fromOffsets: fromOffsets, toOffset: toOffset)
        let reorderedOldIndices = slides.map(\.index)
        let reindexed = Self.reindexedSlides(slides)
        applyEditedSlides(reindexed, reason: "reordered slides")
        currentSlideIndex = deck.clampedSlideIndex(currentSlideIndex)
        return reorderedOldIndices
    }

    func updateSlide(_ slide: PresentationSlide, atIndex slideIndex: Int) {
        guard let deck else {
            return
        }
        var slides = deck.slides.sorted { $0.index < $1.index }
        guard let offset = slides.firstIndex(where: { $0.index == slideIndex }) else {
            return
        }

        slides[offset] = slide.withIndex(slideIndex)
        let reindexed = Self.reindexedSlides(slides)
        applyEditedSlides(reindexed, reason: "updated slide \(slideIndex)")
        currentSlideIndex = deck.clampedSlideIndex(currentSlideIndex)
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

    func restartPresentation() {
        guard let deck else { return }

        markedSegmentIndicesBySlide.removeAll(keepingCapacity: true)
        lastNewMarkEvent = nil

        let firstSlideIndex = deck.firstSlideIndex
        let movedToFirstSlide = currentSlideIndex != firstSlideIndex
        currentSlideIndex = firstSlideIndex

        statusLine = "Presentation restarted on slide \(firstSlideIndex)"
        appendLog("Presentation restarted: cleared all marked items and moved to slide \(firstSlideIndex)")
        appendActivity("Presentation restarted", detail: "Cleared marks and returned to slide \(firstSlideIndex)")

        Task {
            await safetyGate.reset()
        }

        let reason = movedToFirstSlide ? "manual restart to first slide" : "manual restart cleared marks"
        pushContextUpdate(reason: reason)
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

    func markQuoteSegmentsFromPresenterAudioStart() {
        guard let slide = deck?.slide(at: currentSlideIndex) else {
            return
        }

        let quoteIndices = slide.segmentBuckets().quote.map(\.index)
        guard !quoteIndices.isEmpty else {
            return
        }

        var marked = markedSegmentIndicesBySlide[currentSlideIndex] ?? []
        let initialCount = marked.count
        for index in quoteIndices {
            marked.insert(index)
        }

        guard marked.count != initialCount else {
            return
        }

        markedSegmentIndicesBySlide[currentSlideIndex] = marked
        lastNewMarkEvent = (slideIndex: currentSlideIndex, at: Date())
        statusLine = "Quote audio started on slide \(currentSlideIndex)"
        appendLog("[PRESENTER] quote audio started: marked \(quoteIndices.count) quote segment(s) on slide \(currentSlideIndex)")
        appendActivity("Quote marked from audio", detail: "Slide \(currentSlideIndex)")
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
            let manualCommitIntervalMilliseconds = Int(settings.realtimeSilenceDurationMilliseconds.rounded())
            let maxOutputTokens = Int(settings.realtimeMaxOutputTokens.rounded())
            try await bridge.startSession(
                clientSecret: clientSecret,
                model: model,
                instructions: instructions,
                manualCommitIntervalMilliseconds: manualCommitIntervalMilliseconds,
                maxOutputTokens: maxOutputTokens
            )
            isSessionActive = true
            connectionState = "connecting"
            sessionPhase = .connecting
            statusLine = "Connecting to Realtime..."
            appendLog("Realtime start request sent")
            appendLog(
                "Realtime timing: commit_interval_ms=\(manualCommitIntervalMilliseconds), max_output_tokens=\(maxOutputTokens)"
            )
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
        commandProcessingTask?.cancel()
        commandProcessingTask = nil
        functionCallArgumentsBufferByID.removeAll(keepingCapacity: true)
        lastParsedSignatureByFunctionCallID.removeAll(keepingCapacity: true)
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
            functionCallArgumentsBufferByID.removeAll(keepingCapacity: true)
            lastParsedSignatureByFunctionCallID.removeAll(keepingCapacity: true)
            endRealtimeActivityIfNeeded()
            if previousState != "closed" {
                appendActivity("Realtime disconnected")
            }
        case "failed":
            statusLine = "Connection failed"
            isSessionActive = false
            isSpeechDetected = false
            sessionPhase = .error
            functionCallArgumentsBufferByID.removeAll(keepingCapacity: true)
            lastParsedSignatureByFunctionCallID.removeAll(keepingCapacity: true)
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
        case "response.function_call_arguments.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else {
                return
            }
            let functionCallID = functionCallIdentifier(from: event)
            if let functionCallID {
                var accumulated = functionCallArgumentsBufferByID[functionCallID] ?? ""
                accumulated.append(delta)
                functionCallArgumentsBufferByID[functionCallID] = accumulated
                handleCommand(
                    argumentsJSON: accumulated,
                    source: "\(type)#\(functionCallID)",
                    dedupeKey: functionCallID,
                    isPartial: true
                )
            } else {
                handleCommand(argumentsJSON: delta, source: type, isPartial: true)
            }
        case "response.function_call_arguments.done":
            let functionCallID = functionCallIdentifier(from: event)
            let finalArguments: String
            if let arguments = event["arguments"] as? String, !arguments.isEmpty {
                finalArguments = arguments
            } else if let functionCallID,
                      let buffered = functionCallArgumentsBufferByID[functionCallID],
                      !buffered.isEmpty {
                finalArguments = buffered
            } else {
                return
            }

            if let functionCallID {
                functionCallArgumentsBufferByID.removeValue(forKey: functionCallID)
            }
            handleCommand(
                argumentsJSON: finalArguments,
                source: functionCallID.map { "\(type)#\($0)" } ?? type,
                dedupeKey: functionCallID
            )
        case "response.output_item.done":
            guard
                let item = event["item"] as? [String: Any],
                let itemType = item["type"] as? String,
                itemType == "function_call",
                let arguments = item["arguments"] as? String
            else {
                return
            }
            let functionCallID = (item["call_id"] as? String)
                ?? (item["id"] as? String)
                ?? functionCallIdentifier(from: event)
            if let functionCallID {
                functionCallArgumentsBufferByID.removeValue(forKey: functionCallID)
            }
            handleCommand(argumentsJSON: arguments, source: type, dedupeKey: functionCallID)
        case "response.done":
            functionCallArgumentsBufferByID.removeAll(keepingCapacity: true)
            lastParsedSignatureByFunctionCallID.removeAll(keepingCapacity: true)
            if isSessionActive, !isSpeechDetected {
                sessionPhase = .listening
                if statusLine == "Processing speech" || statusLine == "Speaking" {
                    statusLine = "Listening"
                }
            }
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

    private func functionCallIdentifier(from event: [String: Any]) -> String? {
        if let callID = event["call_id"] as? String, !callID.isEmpty {
            return callID
        }
        if let itemID = event["item_id"] as? String, !itemID.isEmpty {
            return itemID
        }
        if let responseID = event["response_id"] as? String, !responseID.isEmpty {
            return responseID
        }
        if let item = event["item"] as? [String: Any] {
            if let callID = item["call_id"] as? String, !callID.isEmpty {
                return callID
            }
            if let itemID = item["id"] as? String, !itemID.isEmpty {
                return itemID
            }
        }
        return nil
    }

    private func commandPayloadSignature(_ commands: [SlideCommand]) -> String {
        commands
            .map { command in
                "\(command.action.rawValue):\(command.targetSlide ?? -1):\(command.markIndex ?? -1)"
            }
            .joined(separator: "|")
    }

    private func handleCommand(
        argumentsJSON: String,
        source: String,
        dedupeKey: String? = nil,
        isPartial: Bool = false
    ) {
        // Never execute partial streamed payloads. Wait for completed function-call arguments
        // to avoid premature marks/navigation from incomplete JSON fragments.
        if isPartial {
            return
        }

        guard let payload = parseCommandPayload(argumentsJSON: argumentsJSON, source: source, isPartial: isPartial) else {
            return
        }

        let commandsToEvaluate = payload.commands

        if let dedupeKey {
            let signature = commandPayloadSignature(commandsToEvaluate)
            if signature == "mark:-1:-1",
               let previousSignature = lastParsedSignatureByFunctionCallID[dedupeKey],
               previousSignature.hasPrefix("mark:-1:"),
               previousSignature != signature {
                // Ignore degraded duplicate payloads for the same function call when
                // a stronger mark payload was already processed.
                return
            }
            if lastParsedSignatureByFunctionCallID[dedupeKey] == signature {
                return
            }
            lastParsedSignatureByFunctionCallID[dedupeKey] = signature
        }

        for note in payload.normalizationNotes {
            appendLog("[NORMALIZED][\(source)] \(note)")
        }

        if payload.recoveredFromTruncation {
            appendLog("[PARSE][\(source)] command decode recovered from truncated payload")
        }
        if payload.format == .legacySingle {
            appendLog("[PARSE][\(source)] accepted legacy single-command payload")
        }
        if commandsToEvaluate.count > 1 {
            appendLog("[TURN][\(source)] executing \(commandsToEvaluate.count) commands")
        }

        let priorTask = commandProcessingTask
        commandProcessingTask = Task { @MainActor in
            await priorTask?.value
            for (offset, command) in commandsToEvaluate.enumerated() {
                guard !Task.isCancelled else { return }
                let commandSource = commandsToEvaluate.count > 1
                    ? "\(source)#\(offset + 1)/\(commandsToEvaluate.count)"
                    : source
                let allowsAutoAdvance = (offset == commandsToEvaluate.count - 1)
                await evaluateCommand(
                    command,
                    source: commandSource,
                    allowsAutoAdvance: allowsAutoAdvance,
                    isPartial: isPartial
                )
            }
        }
    }

    private enum CommandPayloadFormat: String {
        case batch
        case legacySingle
    }

    private struct ParsedCommandPayload {
        let commands: [SlideCommand]
        let format: CommandPayloadFormat
        let recoveredFromTruncation: Bool
        let normalizationNotes: [String]
    }

    private struct DelimiterBalance {
        let unmatchedCurlyOpen: Int
        let unmatchedSquareOpen: Int
        let hasInvalidClosure: Bool
        let hasOpenString: Bool
    }

    private func parseCommandPayload(argumentsJSON: String, source: String, isPartial: Bool = false) -> ParsedCommandPayload? {
        guard let jsonData = argumentsJSON.data(using: .utf8) else {
            if !isPartial {
                appendLog("Command decode failed: invalid UTF-8")
            }
            return nil
        }

        if let decoded = decodeCommandPayload(from: jsonData) {
            let normalized = normalizeCommandSequence(decoded.commands)
            return ParsedCommandPayload(
                commands: normalized.commands,
                format: decoded.format,
                recoveredFromTruncation: false,
                normalizationNotes: normalized.notes
            )
        }

        if let recovered = recoverCommandsFromPossiblyTruncatedJSON(argumentsJSON) {
            let normalized = normalizeCommandSequence(recovered.commands)
            return ParsedCommandPayload(
                commands: normalized.commands,
                format: recovered.format,
                recoveredFromTruncation: true,
                normalizationNotes: normalized.notes
            )
        }

        if !isPartial {
            appendLog("Command decode failed: payload did not match command schema")
            appendLog("Raw command payload [\(source)]: \(argumentsJSON)")
        }
        return nil
    }

    private func decodeCommandPayload(from data: Data) -> (commands: [SlideCommand], format: CommandPayloadFormat)? {
        if let batch = try? jsonDecoder.decode(SlideCommandBatch.self, from: data),
           !batch.commands.isEmpty {
            return (batch.commands, .batch)
        }

        if let single = try? jsonDecoder.decode(SlideCommand.self, from: data) {
            return ([single], .legacySingle)
        }

        return nil
    }

    private func normalizeCommandSequence(_ commands: [SlideCommand]) -> (commands: [SlideCommand], notes: [String]) {
        var normalized = commands
        var notes: [String] = []

        if normalized.count > maxCommandsPerTurn {
            let dropped = normalized.count - maxCommandsPerTurn
            normalized = Array(normalized.prefix(maxCommandsPerTurn))
            notes.append("Dropped \(dropped) command(s) beyond max batch size \(maxCommandsPerTurn)")
        }

        if normalized.count > 1 {
            let withoutStay = normalized.filter { $0.action != .stay }
            if !withoutStay.isEmpty && withoutStay.count != normalized.count {
                let dropped = normalized.count - withoutStay.count
                normalized = withoutStay
                notes.append("Dropped \(dropped) stay command(s) from mixed batch")
            }
        }

        if normalized.isEmpty, let fallback = commands.first {
            normalized = [fallback]
        }

        var filtered: [SlideCommand] = []
        var navigationSeen = false
        var droppedNavigation = 0

        for command in normalized {
            if command.action.isNavigation {
                if navigationSeen {
                    droppedNavigation += 1
                    continue
                }
                navigationSeen = true
            }
            filtered.append(command)
        }

        if droppedNavigation > 0 {
            notes.append("Dropped \(droppedNavigation) extra navigation command(s); kept first")
        }
        normalized = filtered

        if let firstNavigationIndex = normalized.firstIndex(where: { $0.action.isNavigation }),
           firstNavigationIndex < normalized.count - 1 {
            let dropped = normalized.count - firstNavigationIndex - 1
            normalized = Array(normalized.prefix(firstNavigationIndex + 1))
            notes.append("Dropped \(dropped) trailing command(s) after navigation")
        }

        if normalized.isEmpty {
            let fallback = SlideCommand(
                action: .stay,
                targetSlide: nil,
                markIndex: nil,
                confidence: 1,
                rationale: "normalized to stay fallback",
                utteranceExcerpt: nil,
                highlightPhrases: []
            )
            normalized = [fallback]
            notes.append("Inserted fallback stay due empty command batch")
        }

        return (normalized, notes)
    }

    private func recoverCommandsFromPossiblyTruncatedJSON(_ rawJSON: String) -> (commands: [SlideCommand], format: CommandPayloadFormat)? {
        if let candidate = repairedJSONCandidate(from: rawJSON),
           let data = candidate.data(using: .utf8),
           let decoded = decodeCommandPayload(from: data) {
            return decoded
        }

        if let recoveredSingle = recoverCommandFromPartialJSON(rawJSON) {
            return ([recoveredSingle], .legacySingle)
        }

        return nil
    }

    private func repairedJSONCandidate(from rawJSON: String) -> String? {
        var candidate = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.hasPrefix("{") else { return nil }

        candidate = candidate.replacingOccurrences(
            of: ",\\s*([}\\]])",
            with: "$1",
            options: .regularExpression
        )

        let balance = structuralDelimiterBalance(in: candidate)
        guard !balance.hasInvalidClosure else { return nil }
        guard !balance.hasOpenString else { return nil }

        if balance.unmatchedSquareOpen > 0 {
            candidate.append(String(repeating: "]", count: balance.unmatchedSquareOpen))
        }
        if balance.unmatchedCurlyOpen > 0 {
            candidate.append(String(repeating: "}", count: balance.unmatchedCurlyOpen))
        }

        return candidate
    }

    private func structuralDelimiterBalance(in text: String) -> DelimiterBalance {
        var unmatchedCurlyOpen = 0
        var unmatchedSquareOpen = 0
        var hasInvalidClosure = false
        var isInsideString = false
        var isEscaped = false

        for character in text {
            if isEscaped {
                isEscaped = false
                continue
            }

            if character == "\\" {
                if isInsideString {
                    isEscaped = true
                }
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            if isInsideString {
                continue
            }

            switch character {
            case "{":
                unmatchedCurlyOpen += 1
            case "}":
                if unmatchedCurlyOpen == 0 {
                    hasInvalidClosure = true
                } else {
                    unmatchedCurlyOpen -= 1
                }
            case "[":
                unmatchedSquareOpen += 1
            case "]":
                if unmatchedSquareOpen == 0 {
                    hasInvalidClosure = true
                } else {
                    unmatchedSquareOpen -= 1
                }
            default:
                continue
            }

            if hasInvalidClosure {
                break
            }
        }

        return DelimiterBalance(
            unmatchedCurlyOpen: unmatchedCurlyOpen,
            unmatchedSquareOpen: unmatchedSquareOpen,
            hasInvalidClosure: hasInvalidClosure,
            hasOpenString: isInsideString
        )
    }

    private func recoverCommandFromPartialJSON(_ rawJSON: String) -> SlideCommand? {
        guard
            let actionRaw = extractFirstRegexCapture(
                pattern: #""action"\s*:\s*"(next|previous|goto|mark|stay)""#,
                in: rawJSON
            ),
            let action = SlideAction(rawValue: actionRaw)
        else {
            return nil
        }

        let targetSlide = extractOptionalIntegerValue(forKey: "target_slide", in: rawJSON)
        let markIndex = extractOptionalIntegerValue(forKey: "mark_index", in: rawJSON)
        let confidence = extractDoubleValue(forKey: "confidence", in: rawJSON) ?? 1
        let rationale = extractStringValue(forKey: "rationale", in: rawJSON) ?? "recovered partial payload"
        let utteranceExcerpt = extractStringValue(forKey: "utterance_excerpt", in: rawJSON)
        let highlightPhrases = extractStringArrayValue(forKey: "highlight_phrases", in: rawJSON)

        return SlideCommand(
            action: action,
            targetSlide: targetSlide,
            markIndex: markIndex,
            confidence: confidence,
            rationale: rationale,
            utteranceExcerpt: utteranceExcerpt,
            highlightPhrases: highlightPhrases
        )
    }

    private func extractOptionalIntegerValue(forKey key: String, in text: String) -> Int? {
        let pattern = #"""# + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*(null|-?\d+)"#
        guard let rawValue = extractFirstRegexCapture(pattern: pattern, in: text) else {
            return nil
        }
        if rawValue == "null" {
            return nil
        }
        return Int(rawValue)
    }

    private func extractDoubleValue(forKey key: String, in text: String) -> Double? {
        let pattern = #"""# + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*(-?\d+(?:\.\d+)?)"#
        guard let rawValue = extractFirstRegexCapture(pattern: pattern, in: text) else {
            return nil
        }
        return Double(rawValue)
    }

    private func extractStringValue(forKey key: String, in text: String) -> String? {
        let pattern = #"""# + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*"((?:[^"\\]|\\.)*)""#
        guard let rawValue = extractFirstRegexCapture(pattern: pattern, in: text) else {
            return nil
        }
        return decodeJSONStringLiteral(rawValue)
    }

    private func extractStringArrayValue(forKey key: String, in text: String) -> [String]? {
        let pattern = #"""# + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*\[(.*?)\]"#
        guard let arrayBody = extractFirstRegexCapture(
            pattern: pattern,
            in: text,
            options: [.dotMatchesLineSeparators]
        ) else {
            return nil
        }

        guard let regex = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#) else {
            return nil
        }
        let nsRange = NSRange(arrayBody.startIndex..<arrayBody.endIndex, in: arrayBody)
        var values: [String] = []
        for match in regex.matches(in: arrayBody, options: [], range: nsRange) {
            guard
                match.numberOfRanges > 1,
                let valueRange = Range(match.range(at: 1), in: arrayBody),
                let decoded = decodeJSONStringLiteral(String(arrayBody[valueRange]))
            else {
                continue
            }
            values.append(decoded)
        }
        return values
    }

    private func decodeJSONStringLiteral(_ literalBody: String) -> String? {
        let wrapped = "\"\(literalBody)\""
        guard let data = wrapped.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private func extractFirstRegexCapture(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: searchRange) else {
            return nil
        }
        guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    private func evaluateCommand(
        _ command: SlideCommand,
        source: String,
        allowsAutoAdvance: Bool,
        isPartial: Bool = false
    ) async {
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
        let markingMode = settings.markingStrictnessMode

        let (gotoResolvedCommand, gotoRecoveryNote) = recoverGotoTargetIfMissing(
            command: command,
            validSlideIndices: slideIndices
        )
        if let gotoRecoveryNote {
            appendLog("[RECOVERED][\(source)] \(gotoRecoveryNote)")
        }

        let (resolvedCommand, markRecoveryNote) = recoverMarkIndexIfMissing(
            command: gotoResolvedCommand,
            markableSegments: currentMarkableSegments,
            allowHeuristicRecovery: !isPartial && markingMode.allowsHeuristicRecovery,
            allowDeterministicFallback: !isPartial && markingMode.allowsDeterministicFallback
        )
        if let markRecoveryNote {
            appendLog("[RECOVERED][\(source)] \(markRecoveryNote)")
        }

        if let navigationRejectionReason = explicitNavigationRejectionReason(for: resolvedCommand) {
            let commandSummary = summarize(command: resolvedCommand)
            appendLog("[REJECTED][\(source)] \(commandSummary) | \(navigationRejectionReason)")
            appendActivity(
                "AI action rejected",
                detail: "Reason: \(navigationRejectionReason)",
                level: .warning
            )
            return
        }

        if isPartial && markingMode.requiresExplicitSpokenEvidence {
            // Strict mode requires spoken evidence excerpts which are often incomplete
            // in streamed delta fragments. Evaluate strict evidence only on final payloads.
            return
        }

        if let markRejectionReason = explicitMarkRejectionReason(
            for: resolvedCommand,
            markableSegments: currentMarkableSegments,
            mode: markingMode
        ) {
            let commandSummary = summarize(command: resolvedCommand)
            appendLog("[REJECTED][\(source)] \(commandSummary) | \(markRejectionReason)")
            appendActivity(
                "AI mark rejected",
                detail: "Reason: spoken evidence does not match segment",
                level: .warning
            )
            return
        }

        let didApplyHighlights = applyHighlightPhrases(from: resolvedCommand, source: source)

        let policy = CommandPolicy(
            confidenceThreshold: settings.confidenceThreshold,
            cooldownSeconds: settings.cooldownSeconds,
            dwellSeconds: settings.dwellSeconds,
            markCooldownSeconds: settings.realtimeMarkCooldownMilliseconds / 1_000
        )

        let decision = await safetyGate.evaluate(command: resolvedCommand, validSlideIndices: slideIndices, policy: policy)
        let commandSummary = summarize(command: decision.command)

        if decision.accepted {
            appendLog("[ACCEPTED][\(source)] \(commandSummary) | \(decision.reason)")
            appendActivity(activitySummary(for: decision.command), level: .success)
            await applyAcceptedCommand(
                decision.command,
                source: source,
                allowsAutoAdvance: allowsAutoAdvance,
                didApplyHighlights: didApplyHighlights
            )
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

    private func explicitNavigationRejectionReason(for command: SlideCommand) -> String? {
        guard command.action.isNavigation else {
            return nil
        }

        guard let utteranceExcerpt = command.utteranceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !utteranceExcerpt.isEmpty
        else {
            return "navigation requires non-empty utterance_excerpt"
        }

        let utteranceText = normalizedNavigationText(utteranceExcerpt)
        guard !utteranceText.isEmpty else {
            return "navigation requires non-empty utterance_excerpt"
        }

        return hasExplicitNavigationDirective(for: command.action, in: utteranceText)
            ? nil
            : "navigation phrase missing or not command-like"
    }

    private func normalizedNavigationText(_ text: String?) -> String {
        guard let text else {
            return ""
        }
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else {
            return ""
        }

        let withoutPunctuation = trimmed.replacingOccurrences(
            of: #"[^a-z0-9äöüß\s]"#,
            with: " ",
            options: .regularExpression
        )
        return withoutPunctuation.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasExplicitNavigationDirective(for action: SlideAction, in text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }

        switch action {
        case .next:
            return mentionsNextSlideDirective(in: text)
        case .previous:
            return mentionsPreviousSlideDirective(in: text)
        case .goto:
            if mentionsNextSlideDirective(in: text) || mentionsPreviousSlideDirective(in: text) {
                return true
            }
            let indexedSlidePatterns = [
                #"^(?:please\s+)?go\s+to\s+slide(?:s)?\s*(?:number\s*)?\d{1,3}(?:\s+please)?$"#,
                #"^(?:please\s+)?slide(?:s)?\s*(?:number\s*)?\d{1,3}(?:\s+please)?$"#,
                #"^(?:please\s+)?folie\s+\d{1,3}(?:\s+please)?$"#
            ]
            if indexedSlidePatterns.contains(where: { matchesNavigationPattern($0, in: text) }) {
                return true
            }

            let edgeSlidePatterns = [
                #"^(?:please\s+)?(?:first|start)\s+slide(?:\s+please)?$"#,
                #"^(?:please\s+)?(?:last|final|end)\s+slide(?:\s+please)?$"#,
                #"^(?:please\s+)?erste\s+folie(?:\s+please)?$"#,
                #"^(?:please\s+)?letzte\s+folie(?:\s+please)?$"#
            ]
            if edgeSlidePatterns.contains(where: { matchesNavigationPattern($0, in: text) }) {
                return true
            }

            return false
        case .mark, .stay:
            return false
        }
    }

    private func mentionsNextSlideDirective(in text: String) -> Bool {
        let commandPatterns = [
            #"^(?:please\s+)?next(?:\s+slide)?(?:\s+please)?$"#,
            #"^(?:please\s+)?go\s+to\s+next\s+slide(?:\s+please)?$"#,
            #"^(?:please\s+)?advance(?:\s+slide)?(?:\s+please)?$"#,
            #"^(?:please\s+)?forward(?:\s+slide)?(?:\s+please)?$"#,
            #"^(?:please\s+)?n(?:ä|ae)chste\s+folie(?:\s+please)?$"#,
            #"^(?:please\s+)?weiter(?:\s+please)?$"#
        ]
        return commandPatterns.contains(where: { matchesNavigationPattern($0, in: text) })
    }

    private func mentionsPreviousSlideDirective(in text: String) -> Bool {
        let commandPatterns = [
            #"^(?:please\s+)?previous(?:\s+slide)?(?:\s+please)?$"#,
            #"^(?:please\s+)?go\s+to\s+previous\s+slide(?:\s+please)?$"#,
            #"^(?:please\s+)?go\s+back(?:\s+please)?$"#,
            #"^(?:please\s+)?back(?:\s+please)?$"#,
            #"^(?:please\s+)?zur(?:ü|ue)ck(?:\s+please)?$"#,
            #"^(?:please\s+)?vorherige\s+folie(?:\s+please)?$"#
        ]
        return commandPatterns.contains(where: { matchesNavigationPattern($0, in: text) })
    }

    private func matchesNavigationPattern(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func applyAcceptedCommand(
        _ command: SlideCommand,
        source: String,
        allowsAutoAdvance: Bool,
        didApplyHighlights: Bool
    ) async {
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
            guard await waitForPreNavigationVisibilityIfNeeded(
                shouldWaitForHighlights: didApplyHighlights,
                source: source,
                fromSlideIndex: previousIndex
            ) else {
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
            guard await waitForPreNavigationVisibilityIfNeeded(
                shouldWaitForHighlights: didApplyHighlights,
                source: source,
                fromSlideIndex: previousIndex
            ) else {
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
            guard await waitForPreNavigationVisibilityIfNeeded(
                shouldWaitForHighlights: didApplyHighlights,
                source: source,
                fromSlideIndex: previousIndex
            ) else {
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
            if isNewMark {
                lastNewMarkEvent = (slideIndex: slideIndex, at: Date())
            }
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
            // Auto-advance must be triggered by a newly covered segment.
            // Repeated marks on already-covered content must not move slides.
            if allRequiredMarked && isNewMark {
                guard allowsAutoAdvance else {
                    appendLog("[AUTO][\(source)] coverage reached; auto-advance deferred until final command in turn")
                    return
                }
                let nextIndex = deck.clampedSlideIndex(slideIndex + 1)
                if nextIndex != slideIndex {
                    guard await waitForPreNavigationVisibilityIfNeeded(
                        shouldWaitForHighlights: didApplyHighlights,
                        source: source,
                        fromSlideIndex: slideIndex
                    ) else {
                        return
                    }
                    currentSlideIndex = nextIndex
                    statusLine = "All segments marked on slide \(slideIndex): auto-advanced to \(nextIndex)"
                    if nonTitleIndices.isEmpty {
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
                    if nonTitleIndices.isEmpty {
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
        if let excerpt = command.utteranceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !excerpt.isEmpty {
            parts.append("excerpt=\(excerpt)")
        }
        if let highlightPhrases = command.highlightPhrases, !highlightPhrases.isEmpty {
            parts.append("highlights=\(highlightPhrases.count)")
        }
        if !command.rationale.isEmpty {
            parts.append("rationale=\(command.rationale)")
        }
        return parts.joined(separator: " ")
    }

    private func applyHighlightPhrases(from command: SlideCommand, source: String) -> Bool {
        let phraseCandidates = command.highlightPhrases ?? []
        let candidates: [String]
        if phraseCandidates.isEmpty {
            candidates = command.utteranceExcerpt.map { [$0] } ?? []
        } else {
            candidates = phraseCandidates
        }
        let sanitized = sanitizeHighlightPhrases(candidates)

        guard !sanitized.isEmpty else {
            return false
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
            return false
        }

        let maxHighlightsPerSlide = 20
        if existing.count > maxHighlightsPerSlide {
            existing = Array(existing.suffix(maxHighlightsPerSlide))
        }
        highlightedPhrasesBySlide[slideIndex] = existing
        appendLog("[HIGHLIGHT][\(source)] slide \(slideIndex) +\(addedCount)")
        return true
    }

    private func waitForHighlightVisibilityIfNeeded(
        shouldWait: Bool,
        source: String,
        fromSlideIndex: Int
    ) async -> Bool {
        guard shouldWait else {
            return true
        }

        appendLog("[NAV][\(source)] delaying navigation 1.00s for highlight visibility")
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else {
            appendLog("[NAV][\(source)] delayed navigation canceled: command task canceled")
            return false
        }
        guard currentSlideIndex == fromSlideIndex else {
            appendLog("[NAV][\(source)] delayed navigation canceled: slide changed during highlight hold")
            return false
        }
        return true
    }

    private func waitForPreNavigationVisibilityIfNeeded(
        shouldWaitForHighlights: Bool,
        source: String,
        fromSlideIndex: Int
    ) async -> Bool {
        let highlightHold = shouldWaitForHighlights ? preNavigationVisibilityHoldSeconds : 0
        let markHold = remainingMarkVisibilityHoldSeconds(forSlideIndex: fromSlideIndex)
        let totalHold = max(highlightHold, markHold)

        guard totalHold > 0 else {
            return true
        }

        if markHold > 0 {
            appendLog(
                "[NAV][\(source)] delaying navigation \(formatLogNumber(totalHold))s for mark/highlight visibility"
            )
        } else {
            appendLog(
                "[NAV][\(source)] delaying navigation \(formatLogNumber(totalHold))s for highlight visibility"
            )
        }

        try? await Task.sleep(for: .seconds(totalHold))
        guard !Task.isCancelled else {
            appendLog("[NAV][\(source)] delayed navigation canceled: command task canceled")
            return false
        }
        guard currentSlideIndex == fromSlideIndex else {
            appendLog("[NAV][\(source)] delayed navigation canceled: slide changed during visibility hold")
            return false
        }
        return true
    }

    private func remainingMarkVisibilityHoldSeconds(forSlideIndex slideIndex: Int) -> Double {
        guard let lastNewMarkEvent else {
            return 0
        }
        guard lastNewMarkEvent.slideIndex == slideIndex else {
            return 0
        }
        let elapsed = Date().timeIntervalSince(lastNewMarkEvent.at)
        return max(0, preNavigationVisibilityHoldSeconds - elapsed)
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

        let analysisText = normalizedNavigationText(command.utteranceExcerpt)

        guard !analysisText.isEmpty else {
            return (command, nil)
        }

        if mentionsNextSlideDirective(in: analysisText) {
            let recoveredCommand = SlideCommand(
                action: .next,
                targetSlide: nil,
                markIndex: nil,
                confidence: command.confidence,
                rationale: command.rationale,
                utteranceExcerpt: command.utteranceExcerpt,
                highlightPhrases: command.highlightPhrases
            )
            return (recoveredCommand, "Normalized goto to next from next-slide phrase")
        }

        if mentionsPreviousSlideDirective(in: analysisText) {
            let recoveredCommand = SlideCommand(
                action: .previous,
                targetSlide: nil,
                markIndex: nil,
                confidence: command.confidence,
                rationale: command.rationale,
                utteranceExcerpt: command.utteranceExcerpt,
                highlightPhrases: command.highlightPhrases
            )
            return (recoveredCommand, "Normalized goto to previous from previous-slide phrase")
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
        markableSegments: [SlideMarkSegment],
        allowHeuristicRecovery: Bool = true,
        allowDeterministicFallback: Bool = true
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

        if allowHeuristicRecovery {
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
        }

        if allowHeuristicRecovery {
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
        }

        if allowDeterministicFallback, let fallbackIndex = fallbackMarkIndex(from: markableSegments) {
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

    private func explicitMarkRejectionReason(
        for command: SlideCommand,
        markableSegments: [SlideMarkSegment],
        mode: MarkingStrictnessMode
    ) -> String? {
        guard command.action == .mark else {
            return nil
        }
        guard mode.requiresExplicitSpokenEvidence else {
            return nil
        }

        guard let markIndex = command.markIndex else {
            return "strict mark mode requires explicit mark_index"
        }
        guard let segment = markableSegments.first(where: { $0.index == markIndex }) else {
            return "strict mark mode could not resolve current-slide segment for mark_index"
        }
        guard let utteranceExcerpt = command.utteranceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !utteranceExcerpt.isEmpty
        else {
            return "strict mark mode requires non-empty utterance_excerpt"
        }
        guard hasStrongSpokenMarkEvidence(utteranceExcerpt, segmentText: segment.text) else {
            return "strict mark mode requires lexical overlap between speech excerpt and target segment"
        }
        return nil
    }

    private func hasStrongSpokenMarkEvidence(_ utteranceExcerpt: String, segmentText: String) -> Bool {
        let normalizedExcerpt = normalizeForMarkMatching(utteranceExcerpt)
        let normalizedSegment = normalizeForMarkMatching(segmentText)

        if normalizedExcerpt.count >= 6,
           (normalizedSegment.contains(normalizedExcerpt) || normalizedExcerpt.contains(normalizedSegment)) {
            return true
        }

        let excerptTokens = Set(tokenSet(for: utteranceExcerpt).filter { !$0.isEmpty })
        let segmentTokens = Set(tokenSet(for: segmentText).filter { !$0.isEmpty })
        let overlap = excerptTokens.intersection(segmentTokens)
        if overlap.count >= 2 {
            return true
        }
        if overlap.contains(where: { $0.count >= 6 }) {
            return true
        }

        return false
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
        let manualCommitIntervalMilliseconds = Int(settings.realtimeSilenceDurationMilliseconds.rounded())
        let maxOutputTokens = Int(settings.realtimeMaxOutputTokens.rounded())
        Task {
            do {
                try await bridge.updateInstructions(
                    instructions,
                    manualCommitIntervalMilliseconds: manualCommitIntervalMilliseconds,
                    maxOutputTokens: maxOutputTokens
                )
                if shouldLogResult {
                    appendLog(
                        "Context updated for slide \(currentSlideIndex) (\(reason)) [commit_interval=\(manualCommitIntervalMilliseconds)ms, max_tokens=\(maxOutputTokens)]"
                    )
                }
            } catch {
                if shouldLogResult {
                    appendLog("Context update failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func applyRealtimeTimingUpdateIfNeeded() {
        guard isSessionActive else { return }
        pushContextUpdate(reason: "realtime timing changed")
    }

    private func isCurrentEventArrowKeyNavigation() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        guard event.type == .keyDown else { return false }
        return event.keyCode == 123 || event.keyCode == 124
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
        hasUnsavedDeckChanges = false
        if let sourceURL {
            deckFilePath = sourceURL.path
            if sourceURL.isFileURL {
                persistLastOpenedDeckReference(sourceURL)
            }
        }
        preflightImageFileAccess(for: loadedDeck, sourceURL: sourceURL)
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

    private func preflightImageFileAccess(for deck: PresentationDeck, sourceURL: URL?) {
        let deckDirectoryURL: URL? = {
            guard let sourceURL, sourceURL.isFileURL else {
                return nil
            }
            return sourceURL.deletingLastPathComponent().standardizedFileURL
        }()

        var attemptedPaths = 0
        var successfulPaths = 0
        var visitedPaths = Set<String>()

        for slide in deck.slides {
            guard slide.layout == .image else {
                continue
            }

            for rawPath in slide.imagePlaceholderParagraphs {
                let normalized = normalizeImagePathForPreflight(rawPath)
                guard !normalized.isEmpty else {
                    continue
                }
                guard let fileURL = resolveImageFileURLForPreflight(normalized, deckDirectoryURL: deckDirectoryURL) else {
                    continue
                }

                let standardizedPath = fileURL.standardizedFileURL.path
                guard visitedPaths.insert(standardizedPath).inserted else {
                    continue
                }

                attemptedPaths += 1
                let didStartSecurityScope = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if didStartSecurityScope {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let fileHandle = try FileHandle(forReadingFrom: fileURL)
                    try fileHandle.close()
                    successfulPaths += 1
                } catch {
                    // Access denial is expected when TCC prompt is declined or not yet granted.
                }
            }
        }

        if attemptedPaths > 0 {
            appendLog("Preflighted image access for \(attemptedPaths) path(s), readable: \(successfulPaths)")
        }
    }

    private func normalizeImagePathForPreflight(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let dequoted: String
        if trimmed.count >= 2,
           ((trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
               (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))) {
            dequoted = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            dequoted = trimmed
        }

        guard dequoted.hasSuffix("%"), let suffixStart = dequoted.lastIndex(of: ":") else {
            return dequoted
        }
        let numberStart = dequoted.index(after: suffixStart)
        let numberEnd = dequoted.index(before: dequoted.endIndex)
        guard numberStart < numberEnd else {
            return dequoted
        }
        let numberText = dequoted[numberStart..<numberEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percentage = Double(numberText), percentage > 0 else {
            return dequoted
        }

        let stripped = String(dequoted[..<suffixStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? dequoted : stripped
    }

    private func resolveImageFileURLForPreflight(_ path: String, deckDirectoryURL: URL?) -> URL? {
        if let parsedURL = URL(string: path), parsedURL.isFileURL {
            return parsedURL.standardizedFileURL
        }

        if path.hasPrefix("~") {
            let expandedPath = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }

        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        if let deckDirectoryURL {
            return URL(fileURLWithPath: path, relativeTo: deckDirectoryURL).standardizedFileURL
        }

        let currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return URL(fileURLWithPath: path, relativeTo: currentDirectoryURL).standardizedFileURL
    }

    private func applyEditedSlides(_ slides: [PresentationSlide], reason: String) {
        guard let deck else {
            return
        }
        let normalizedSlides = Self.reindexedSlides(slides)
        self.deck = PresentationDeck(
            presentationTitle: deck.presentationTitle,
            subtitle: deck.subtitle,
            author: deck.author,
            language: deck.language,
            slides: normalizedSlides
        )
        highlightedPhrasesBySlide.removeAll(keepingCapacity: true)
        markedSegmentIndicesBySlide.removeAll(keepingCapacity: true)
        currentSlideIndex = min(max(1, currentSlideIndex), max(normalizedSlides.count, 1))
        hasUnsavedDeckChanges = true
        appendLog("Deck edited: \(reason)")
        appendActivity("Deck updated", detail: reason)
        pushContextUpdate(reason: reason)
    }

    private func persistDeck(to url: URL, updateLoadedURL: Bool) {
        guard let deck else {
            appendLog("Save failed: no deck in memory")
            return
        }

        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try PresentationDeckWriter.encode(deck: deck)
            try data.write(to: url, options: .atomic)
            if updateLoadedURL {
                loadedDeckURL = url
                deckFilePath = url.path
            }
            if url.isFileURL {
                persistLastOpenedDeckReference(url)
            }
            hasUnsavedDeckChanges = false
            appendLog("Saved deck to \(url.path)")
            appendActivity("Deck saved", detail: url.lastPathComponent, level: .success)
        } catch {
            appendLog("Save failed: \(error.localizedDescription)")
            appendActivity("Save failed", detail: error.localizedDescription, level: .error)
        }
    }

    private func suggestedDeckFileName() -> String {
        let title = deck?.presentationTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Presentation"
        let fallback = "Presentation"
        let normalizedTitle = title.isEmpty ? fallback : title
        let sanitized = normalizedTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        return sanitized.hasSuffix(".json") ? sanitized : "\(sanitized).json"
    }

    private func currentDeckFileURLForSavePanel() -> URL? {
        if let loadedDeckURL, loadedDeckURL.isFileURL {
            return loadedDeckURL.standardizedFileURL
        }

        let trimmedPath = deckFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmedPath).standardizedFileURL
    }

    private static func reindexedSlides(_ slides: [PresentationSlide]) -> [PresentationSlide] {
        slides.enumerated().map { offset, slide in
            slide.withIndex(offset + 1)
        }
    }

    private static func makeDefaultSlide(index: Int) -> PresentationSlide {
        let titleParagraphs = ["New Slide"]
        return PresentationSlide(
            index: index,
            layout: .bullets,
            title: titleParagraphs.joined(separator: " "),
            titleParagraphs: titleParagraphs,
            subtitle: "",
            subtitleParagraphs: [],
            bullets: ["Add bullet text"],
            quote: nil,
            quoteParagraphs: [],
            quoteAudioPath: nil,
            imagePlaceholder: nil,
            imagePlaceholderParagraphs: [],
            imagePresentationStyle: .scroll,
            imageScrollSpeed: PresentationSlide.defaultImageScrollSpeed,
            caption: nil,
            captionParagraphs: [],
            leftColumn: nil,
            rightColumn: nil
        )
    }

    private static func moveElements(
        in slides: inout [PresentationSlide],
        fromOffsets: IndexSet,
        toOffset: Int
    ) {
        guard !fromOffsets.isEmpty else {
            return
        }
        let movingElements = fromOffsets.map { slides[$0] }
        for offset in fromOffsets.sorted(by: >) {
            slides.remove(at: offset)
        }

        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let adjustedDestination = toOffset - removedBeforeDestination
        let destination = min(max(0, adjustedDestination), slides.count)
        slides.insert(contentsOf: movingElements, at: destination)
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
    private static let lastOpenedDeckBookmarkDefaultsKey = "lastOpenedDeckBookmark"
    private static let logFileName = "runtime/command-log.txt"

    static func clearLastOpenedDeckReference() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastOpenedDeckPathDefaultsKey)
        defaults.removeObject(forKey: lastOpenedDeckBookmarkDefaultsKey)
    }

    func debugLog(_ message: String) {
        appendLog(message)
    }

    func shouldPreferLastOpenedDeck(over incomingDocumentURL: URL?) -> Bool {
        guard let incomingDocumentURL else {
            return true
        }
        guard incomingDocumentURL.isFileURL else {
            return false
        }
        guard let storedPath = UserDefaults.standard.string(forKey: Self.lastOpenedDeckPathDefaultsKey) else {
            return false
        }
        let normalizedIncomingPath = incomingDocumentURL.standardizedFileURL.path
        let normalizedStoredPath = URL(fileURLWithPath: storedPath).standardizedFileURL.path
        return normalizedIncomingPath == normalizedStoredPath
    }

    @discardableResult
    func restoreLastOpenedDeckIfAvailable() -> Bool {
        guard let url = resolveLastOpenedDeckURL() else {
            appendLog("Last deck restore skipped: no resolved URL")
            return false
        }

        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        appendLog("Attempting last deck restore from \(url.path), didStartSecurityScope=\(didStartSecurityScope)")
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let loadedDeck = try PresentationDeckLoader.load(from: url)
            applyLoadedDeck(loadedDeck, sourceURL: url, sourceDescription: url.path)
            appendLog("Restored last opened deck from previous session")
            return true
        } catch {
            appendLog("Failed to restore last opened deck: \(error.localizedDescription)")
            return false
        }
    }

    private func persistLastOpenedDeckReference(_ url: URL) {
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: Self.lastOpenedDeckPathDefaultsKey)

        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmarkData, forKey: Self.lastOpenedDeckBookmarkDefaultsKey)
        } catch {
            appendLog("Failed to persist last opened deck bookmark: \(error.localizedDescription)")
            defaults.removeObject(forKey: Self.lastOpenedDeckBookmarkDefaultsKey)
        }
    }

    private func resolveLastOpenedDeckURL() -> URL? {
        let defaults = UserDefaults.standard

        if let bookmarkData = defaults.data(forKey: Self.lastOpenedDeckBookmarkDefaultsKey) {
            var bookmarkIsStale = false
            do {
                let bookmarkedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withoutUI, .withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &bookmarkIsStale
                )

                guard bookmarkedURL.isFileURL else {
                    defaults.removeObject(forKey: Self.lastOpenedDeckBookmarkDefaultsKey)
                    return nil
                }

                guard FileManager.default.fileExists(atPath: bookmarkedURL.path) else {
                    defaults.removeObject(forKey: Self.lastOpenedDeckBookmarkDefaultsKey)
                    defaults.removeObject(forKey: Self.lastOpenedDeckPathDefaultsKey)
                    appendLog("Last opened deck no longer exists: \(bookmarkedURL.path)")
                    return nil
                }

                if bookmarkIsStale {
                    persistLastOpenedDeckReference(bookmarkedURL)
                }

                return bookmarkedURL
            } catch {
                defaults.removeObject(forKey: Self.lastOpenedDeckBookmarkDefaultsKey)
                appendLog("Failed to resolve last opened deck bookmark: \(error.localizedDescription)")
            }
        }

        guard let path = defaults.string(forKey: Self.lastOpenedDeckPathDefaultsKey) else {
            return nil
        }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: trimmedPath) else {
            defaults.removeObject(forKey: Self.lastOpenedDeckPathDefaultsKey)
            appendLog("Last opened deck path no longer exists: \(trimmedPath)")
            return nil
        }
        return URL(fileURLWithPath: trimmedPath)
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
