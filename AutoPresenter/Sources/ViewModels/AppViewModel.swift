import AVFoundation
import AppKit
import Combine
import Foundation
import WebKit

@MainActor
final class AppViewModel: ObservableObject {
    private static let logNumberLocale = Locale(identifier: "en_US_POSIX")

    @Published var apiKey: String = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    @Published var model: String = "gpt-realtime"
    @Published var deckFilePath: String = ""

    @Published var currentSlideIndex: Int = 1

    @Published var confidenceThreshold: Double = 0.70
    @Published var cooldownSeconds: Double = 1.20
    @Published var dwellSeconds: Double = 0.00

    @Published private(set) var deck: PresentationDeck?
    @Published private(set) var loadedDeckURL: URL?
    @Published private(set) var isSessionActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var connectionState = "idle"
    @Published private(set) var statusLine = "Ready"

    let bridge: RealtimeWebBridge

    private let tokenService = OpenAIRealtimeTokenService()
    private let safetyGate = CommandSafetyGate()
    private let maxLogEntries = 600
    private let logFileURL = AppViewModel.resolveLogFileURL()
    @Published private var logEntries: [String] = []
    private var realtimeActivityToken: NSObjectProtocol?
    private var didReportLogFileError = false

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(bootstrapExampleDeck: Bool = true) {
        bridge = RealtimeWebBridge()
        bridge.onMessage = { [weak self] payload in
            self?.handleBridgePayload(payload)
        }
        prepareLogFileIfNeeded()
        loadAPIKeyFromKnownLocations()
        if bootstrapExampleDeck {
            bootstrapDeckPath()
        }
        if let logFileURL {
            appendLog("Mirroring command log to \(logFileURL.path)")
        }
        appendLog("AutoPresenter initialized")
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

    var webView: WKWebView {
        bridge.webView
    }

    var logLines: [String] {
        logEntries
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
        currentSlideIndex = deck.clampedSlideIndex(currentSlideIndex - 1)
        appendLog("Slide set to \(currentSlideIndex)")
        pushContextUpdate(reason: "manual previous")
    }

    func nextSlide() {
        guard let deck else { return }
        currentSlideIndex = deck.clampedSlideIndex(currentSlideIndex + 1)
        appendLog("Slide set to \(currentSlideIndex)")
        pushContextUpdate(reason: "manual next")
    }

    func applyContextUpdate() {
        pushContextUpdate(reason: "manual refresh")
    }

    func clearLog() {
        logEntries.removeAll(keepingCapacity: true)
        truncateLogFile()
        appendLog("Command log cleared")
    }

    func startSession() async {
        guard !isStarting else { return }
        guard let deck else {
            statusLine = "Load a presentation deck first"
            appendLog("Start blocked: no deck loaded")
            return
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            statusLine = "OpenAI API key missing"
            appendLog("Start blocked: API key is empty")
            return
        }

        let micGranted = await requestMicrophoneAccessIfNeeded()
        guard micGranted else {
            statusLine = "Microphone permission denied"
            appendLog("Start blocked: microphone permission denied")
            return
        }

        isStarting = true
        defer { isStarting = false }
        beginRealtimeActivityIfNeeded()

        do {
            let clientSecret = try await tokenService.mintClientSecret(apiKey: trimmedKey, model: model)
            let instructions = deck.instructionBlock(currentSlideIndex: currentSlideIndex)
            try await bridge.startSession(clientSecret: clientSecret, model: model, instructions: instructions)
            isSessionActive = true
            connectionState = "connecting"
            statusLine = "Realtime session started"
            appendLog("Realtime session request sent")
        } catch {
            endRealtimeActivityIfNeeded()
            statusLine = "Start failed"
            appendLog("Failed to start Realtime session: \(error.localizedDescription)")
        }
    }

    func stopSession() async {
        do {
            try await bridge.stopSession()
        } catch {
            appendLog("Stop session JS error: \(error.localizedDescription)")
        }
        isSessionActive = false
        connectionState = "stopped"
        statusLine = "Session stopped"
        await safetyGate.reset()
        endRealtimeActivityIfNeeded()
        appendLog("Realtime session stopped")
    }

    private func handleBridgePayload(_ payload: [String: Any]) {
        guard let kind = payload["kind"] as? String else {
            appendLog("Bridge payload missing kind")
            return
        }

        switch kind {
        case "log":
            let level = (payload["level"] as? String ?? "info").uppercased()
            let message = payload["message"] as? String ?? "<no message>"
            appendLog("[bridge/\(level)] \(message)")
            if message == "Realtime data channel opened" {
                statusLine = "Start speaking"
            }
        case "connection":
            let state = payload["state"] as? String ?? "unknown"
            connectionState = state
            appendLog("WebRTC state: \(state)")
            if state == "connected" {
                statusLine = "Realtime connected"
                isSessionActive = true
                beginRealtimeActivityIfNeeded()
            }
            if state == "closed" || state == "failed" {
                statusLine = "Realtime disconnected"
                isSessionActive = false
                endRealtimeActivityIfNeeded()
            }
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
        case "input_audio_buffer.speech_started":
            appendLog("Speech detected")
        case "input_audio_buffer.speech_stopped":
            appendLog("Speech ended")
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
        let slideIndices = deck?.slideIndices ?? []
        let policy = CommandPolicy(
            confidenceThreshold: confidenceThreshold,
            cooldownSeconds: cooldownSeconds,
            dwellSeconds: dwellSeconds
        )

        let decision = await safetyGate.evaluate(command: command, validSlideIndices: slideIndices, policy: policy)
        let commandSummary = summarize(command: decision.command)

        if decision.accepted {
            appendLog("[ACCEPTED][\(source)] \(commandSummary) | \(decision.reason)")
            applyAcceptedCommand(decision.command, source: source)
        } else if decision.command.action == .stay && decision.reason == "model requested stay" {
            statusLine = "Model hold: no slide change"
            appendLog("[NOOP][\(source)] \(commandSummary) | \(decision.reason)")
        } else {
            appendLog("[REJECTED][\(source)] \(commandSummary) | \(decision.reason)")
        }
    }

    private func applyAcceptedCommand(_ command: SlideCommand, source: String) {
        guard let deck else {
            statusLine = "Accepted command ignored: no deck"
            appendLog("[APPLIED][\(source)] ignored accepted \(command.action.rawValue): no deck loaded")
            return
        }

        let previousIndex = currentSlideIndex

        switch command.action {
        case .next:
            let nextIndex = deck.clampedSlideIndex(currentSlideIndex + 1)
            if nextIndex == previousIndex {
                statusLine = "Accepted next (already at last slide)"
                appendLog("[APPLIED][\(source)] next ignored: already at last slide \(previousIndex)")
                return
            }

            currentSlideIndex = nextIndex
            statusLine = "Accepted next: slide \(nextIndex)"
            appendLog("[APPLIED][\(source)] moved to slide \(nextIndex) via next")
            pushContextUpdate(reason: "model next")
        case .previous:
            let previousSlideIndex = deck.clampedSlideIndex(currentSlideIndex - 1)
            if previousSlideIndex == previousIndex {
                statusLine = "Accepted previous (already at first slide)"
                appendLog("[APPLIED][\(source)] previous ignored: already at first slide \(previousIndex)")
                return
            }

            currentSlideIndex = previousSlideIndex
            statusLine = "Accepted previous: slide \(previousSlideIndex)"
            appendLog("[APPLIED][\(source)] moved to slide \(previousSlideIndex) via previous")
            pushContextUpdate(reason: "model previous")
        case .goto:
            guard let targetSlide = command.targetSlide else {
                statusLine = "Accepted goto ignored: missing target"
                appendLog("[APPLIED][\(source)] goto ignored: accepted command missing target_slide")
                return
            }
            guard deck.slideIndices.contains(targetSlide) else {
                statusLine = "Accepted goto ignored: invalid target"
                appendLog("[APPLIED][\(source)] goto ignored: target \(targetSlide) outside loaded deck")
                return
            }
            if targetSlide == previousIndex {
                statusLine = "Accepted goto: already on slide \(targetSlide)"
                appendLog("[APPLIED][\(source)] goto ignored: already on slide \(targetSlide)")
                return
            }

            currentSlideIndex = targetSlide
            statusLine = "Accepted goto: slide \(targetSlide)"
            appendLog("[APPLIED][\(source)] moved to slide \(targetSlide) via goto")
            pushContextUpdate(reason: "model goto")
        case .stay:
            statusLine = "Accepted stay: no slide change"
            appendLog("[APPLIED][\(source)] stay applied: no slide change (slide \(currentSlideIndex))")
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
        if !command.rationale.isEmpty {
            parts.append("rationale=\(command.rationale)")
        }
        return parts.joined(separator: " ")
    }

    private func formatLogNumber(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(2))
                .locale(Self.logNumberLocale)
        )
    }

    private func pushContextUpdate(reason: String) {
        guard let deck else { return }
        guard isSessionActive else { return }

        let instructions = deck.instructionBlock(currentSlideIndex: currentSlideIndex)
        Task {
            do {
                try await bridge.updateInstructions(instructions)
                appendLog("Context updated for slide \(currentSlideIndex) (\(reason))")
            } catch {
                appendLog("Context update failed: \(error.localizedDescription)")
            }
        }
    }

    private func bootstrapDeckPath() {
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

            let sessionHeader = "----- Session started \(Self.fileTimestampFormatter.string(from: Date())) -----"
            appendRawLineToLogFile(sessionHeader)
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
