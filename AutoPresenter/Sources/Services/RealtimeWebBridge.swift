import Foundation
import WebKit

enum RealtimeWebBridgeError: LocalizedError {
    case bridgeScriptMissing
    case payloadEncodingFailed
    case bridgeNotReady

    var errorDescription: String? {
        switch self {
        case .bridgeScriptMissing:
            return "The WebRTC bridge script could not be loaded from app resources."
        case .payloadEncodingFailed:
            return "Failed to encode bridge payload to JSON."
        case .bridgeNotReady:
            return "WebRTC bridge page is not ready yet."
        }
    }
}

@MainActor
final class RealtimeWebBridge: NSObject {
    let webView: WKWebView
    var onMessage: (([String: Any]) -> Void)? {
        didSet {
            flushPendingMessages()
        }
    }

    private nonisolated let messageHandlerName = "autoPresenterBridge"
    private var isBridgeReady = false
    private var lastLoadError: RealtimeWebBridgeError?
    private var requiresReloadAfterProcessTermination = false
    private var pendingMessages: [[String: Any]] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        configuration.userContentController.add(self, name: messageHandlerName)

        loadBridgePage()
    }

    func startSession(clientSecret: String, model: String, instructions: String) async throws {
        try await waitForBridgeReady()
        let payload = StartSessionPayload(
            clientSecret: clientSecret,
            model: model,
            instructions: instructions,
            turnDetection: .init(
                type: "server_vad",
                createResponse: true,
                interruptResponse: true,
                silenceDurationMilliseconds: 180
            )
        )
        try await invokeJavaScript(functionName: "window.AutoPresenter.startSession", payload: payload)
    }

    func updateInstructions(_ instructions: String) async throws {
        try await waitForBridgeReady()
        let payload = UpdateSessionPayload(instructions: instructions)
        try await invokeJavaScript(functionName: "window.AutoPresenter.updateSession", payload: payload)
    }

    func stopSession() async throws {
        try await waitForBridgeReady()
        let script = """
        (() => {
          Promise.resolve(window.AutoPresenter.stopSession()).catch((error) => {
            window.webkit?.messageHandlers?.\(messageHandlerName)?.postMessage({
              kind: "log",
              level: "error",
              message: "window.AutoPresenter.stopSession failed: " + (error?.message ?? String(error))
            });
          });
          return "ok";
        })();
        """
        _ = try await webView.evaluateJavaScript(script)
    }

    private func loadBridgePage() {
        isBridgeReady = false
        lastLoadError = nil
        requiresReloadAfterProcessTermination = false
        emit([
            "kind": "log",
            "level": "info",
            "message": "Loading embedded bridge page"
        ])

        guard let (scriptSource, scriptLocation) = loadBridgeScriptSource() else {
            lastLoadError = .bridgeScriptMissing
            emit([
                "kind": "log",
                "level": "error",
                "message": RealtimeWebBridgeError.bridgeScriptMissing.localizedDescription
            ])
            let html = makeBridgePageHTML(statusLine: "Bridge script missing", scriptSource: nil)
            webView.loadHTMLString(html, baseURL: URL(string: "https://localhost"))
            return
        }

        emit([
            "kind": "log",
            "level": "info",
            "message": "Loaded bridge script from \(scriptLocation)"
        ])
        let html = makeBridgePageHTML(statusLine: "Realtime bridge loaded", scriptSource: scriptSource)
        webView.loadHTMLString(html, baseURL: URL(string: "https://localhost"))
    }

    private func invokeJavaScript<Payload: Encodable>(functionName: String, payload: Payload) async throws {
        let payloadData = try JSONEncoder().encode(payload)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw RealtimeWebBridgeError.payloadEncodingFailed
        }

        let script = """
        (() => {
          const payload = \(payloadJSON);
          Promise.resolve(\(functionName)(payload)).catch((error) => {
            window.webkit?.messageHandlers?.\(messageHandlerName)?.postMessage({
              kind: "log",
              level: "error",
              message: "\(functionName) failed: " + (error?.message ?? String(error))
            });
          });
          return "ok";
        })();
        """

        _ = try await webView.evaluateJavaScript(script)
    }

    private func waitForBridgeReady(timeoutSeconds: Double = 5.0) async throws {
        if isBridgeReady {
            return
        }
        if requiresReloadAfterProcessTermination || webView.url == nil {
            loadBridgePage()
        }

        var attemptsRemaining = 2
        while attemptsRemaining > 0 {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if isBridgeReady {
                    return
                }
                if await detectBridgeObject() {
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }

            attemptsRemaining -= 1
            if attemptsRemaining > 0 {
                let readyState = await javascriptDocumentReadyState()
                let location = webView.url?.absoluteString ?? "nil"
                emit([
                    "kind": "log",
                    "level": "warn",
                    "message": "Bridge did not become ready within timeout (url=\(location), isLoading=\(webView.isLoading), document.readyState=\(readyState)); reloading page"
                ])
                loadBridgePage()
            }
        }

        if let lastLoadError {
            throw lastLoadError
        }
        throw RealtimeWebBridgeError.bridgeNotReady
    }

    private func detectBridgeObject() async -> Bool {
        guard !isBridgeReady else { return true }
        do {
            let result = try await webView.evaluateJavaScript(
                "Boolean(window.AutoPresenter && typeof window.AutoPresenter.startSession === 'function')"
            )
            let ready: Bool
            if let value = result as? Bool {
                ready = value
            } else if let value = result as? NSNumber {
                ready = value.boolValue
            } else if let value = result as? NSString {
                ready = value.boolValue
            } else {
                ready = false
            }

            if ready {
                isBridgeReady = true
                return true
            }
        } catch {
            // Ignore transient probe failures while page initializes.
        }
        return false
    }

    private func javascriptDocumentReadyState() async -> String {
        do {
            let result = try await webView.evaluateJavaScript("document.readyState")
            if let state = result as? String {
                return state
            }
        } catch {
            return "unknown(error=\(error.localizedDescription))"
        }
        return "unknown"
    }

    private func loadBridgeScriptSource() -> (source: String, location: String)? {
        if let scriptURL = Bundle.main.url(forResource: "realtime-bridge", withExtension: "js"),
           let scriptSource = try? String(contentsOf: scriptURL, encoding: .utf8) {
            return (scriptSource, scriptURL.path)
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sourceRelativeBase = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fallbackCandidates = [
            currentDirectory.appendingPathComponent("AutoPresenter/Resources/realtime-bridge.js"),
            currentDirectory.appendingPathComponent("realtime-bridge.js"),
            sourceRelativeBase.appendingPathComponent("Resources/realtime-bridge.js")
        ]

        for candidate in fallbackCandidates {
            if let scriptSource = try? String(contentsOf: candidate, encoding: .utf8) {
                return (scriptSource, candidate.path)
            }
        }

        return nil
    }

    private func makeBridgePageHTML(statusLine: String, scriptSource: String?) -> String {
        let runtimeScript = scriptSource ?? ""
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1.0" />
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: #0f1115;
              color: #d9dce3;
              font: 13px Menlo, Monaco, SFMono-Regular, monospace;
            }
            #status {
              padding: 10px;
            }
          </style>
        </head>
        <body>
          <div id="status">\(statusLine)</div>
          <script>
          (() => {
            const post = (payload) => {
              window.webkit?.messageHandlers?.\(messageHandlerName)?.postMessage(payload);
            };
            post({ kind: "log", level: "info", message: "Bridge bootstrap script executed" });
            window.addEventListener("error", (event) => {
              post({
                kind: "log",
                level: "error",
                message: "Bridge JS error: " + String(event?.message ?? "unknown")
              });
            });
            window.addEventListener("unhandledrejection", (event) => {
              const reason = event?.reason;
              const reasonMessage = reason?.message ?? String(reason ?? "unknown");
              post({
                kind: "log",
                level: "error",
                message: "Bridge JS unhandled rejection: " + reasonMessage
              });
            });
          })();
          </script>
          <script>
        \(runtimeScript)
          </script>
          <script>
          (() => {
            const ready = Boolean(window.AutoPresenter && typeof window.AutoPresenter.startSession === "function");
            const post = (payload) => {
              window.webkit?.messageHandlers?.\(messageHandlerName)?.postMessage(payload);
            };
            post({
              kind: "log",
              level: ready ? "info" : "warn",
              message: ready ? "Bridge runtime object ready" : "Bridge runtime object missing"
            });
            if (ready) {
              post({ kind: "bridge_ready" });
            }
          })();
          </script>
        </body>
        </html>
        """
    }

    private func emit(_ payload: [String: Any]) {
        if let onMessage {
            onMessage(payload)
        } else {
            pendingMessages.append(payload)
        }
    }

    private func flushPendingMessages() {
        guard let onMessage else { return }
        guard !pendingMessages.isEmpty else { return }
        let messages = pendingMessages
        pendingMessages.removeAll(keepingCapacity: true)
        for payload in messages {
            onMessage(payload)
        }
    }
}

private struct StartSessionPayload: Encodable {
    let clientSecret: String
    let model: String
    let instructions: String
    let turnDetection: TurnDetectionConfig
}

private struct UpdateSessionPayload: Encodable {
    let instructions: String
}

private struct TurnDetectionConfig: Encodable {
    let type: String
    let createResponse: Bool
    let interruptResponse: Bool
    let silenceDurationMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case type
        case createResponse = "create_response"
        case interruptResponse = "interrupt_response"
        case silenceDurationMilliseconds = "silence_duration_ms"
    }
}

extension RealtimeWebBridge: WKScriptMessageHandler {
    @MainActor
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == messageHandlerName else { return }
        guard let payload = message.body as? [String: Any] else {
            emit([
                "kind": "log",
                "level": "error",
                "message": "Bridge posted a malformed payload"
            ])
            return
        }

        if let kind = payload["kind"] as? String, kind == "bridge_ready" {
            isBridgeReady = true
            lastLoadError = nil
        }
        emit(payload)
    }
}

extension RealtimeWebBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        emit([
            "kind": "log",
            "level": "info",
            "message": "Bridge navigation started"
        ])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        emit([
            "kind": "log",
            "level": "info",
            "message": "Embedded WebRTC bridge page loaded"
        ])
        Task {
            _ = await detectBridgeObject()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emit([
            "kind": "log",
            "level": "error",
            "message": "Bridge provisional navigation failed: \(error.localizedDescription)"
        ])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        emit([
            "kind": "log",
            "level": "error",
            "message": "Bridge navigation failed: \(error.localizedDescription)"
        ])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isBridgeReady = false
        requiresReloadAfterProcessTermination = true
        emit([
            "kind": "connection",
            "state": "closed"
        ])
        emit([
            "kind": "log",
            "level": "warn",
            "message": "Bridge web content process terminated; will reload bridge on next operation"
        ])
    }
}

extension RealtimeWebBridge: WKUIDelegate {
    @MainActor
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }
}
