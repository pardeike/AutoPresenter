import AppKit
import WebKit

@MainActor
final class RealtimeWebViewHostWindow {
    private var hostWindow: NSPanel?

    func attach(_ webView: WKWebView) {
        let window = ensureHostWindow()
        guard let contentView = window.contentView else { return }

        if contentView.subviews.contains(where: { $0 === webView }) {
            return
        }

        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        // Keep the bridge host alive and present across spaces (including fullscreen).
        window.orderFrontRegardless()
    }

    private func ensureHostWindow() -> NSPanel {
        if let hostWindow {
            return hostWindow
        }

        let frame = NSRect(x: 8, y: 8, width: 2, height: 2)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.alphaValue = 0.001
        panel.hasShadow = false
        panel.title = ""

        hostWindow = panel
        return panel
    }
}
