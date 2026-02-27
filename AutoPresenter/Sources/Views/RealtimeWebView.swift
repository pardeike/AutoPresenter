import SwiftUI
import WebKit

struct RealtimeWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        attachWebView(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attachWebView(to: nsView)
    }

    private func attachWebView(to container: NSView) {
        if container.subviews.contains(where: { $0 === webView }) {
            return
        }

        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
