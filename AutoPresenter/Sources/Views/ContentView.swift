import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var showBridgeView = false

    private let commandLogBottomID = "command-log-bottom"
    private let panelGap: CGFloat = 10
    private let leftPanelRatio: CGFloat = 3.0 / 5.0
    private let minimumSlidePanelWidth: CGFloat = 520
    private let minimumSidePanelWidth: CGFloat = 320

    private var bridgeIsVisible: Bool {
        showBridgeView
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width - 32)
            let panelWidths = fixedPanelWidths(totalWidth: availableWidth)

            HStack(spacing: panelGap) {
                slidePanel
                    .frame(width: panelWidths.leftWidth)
                    .frame(maxHeight: .infinity, alignment: .topLeading)

                sidePanel
                    .frame(width: panelWidths.rightWidth)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
        }
    }

    private var slidePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let slide = viewModel.deck?.slide(at: viewModel.currentSlideIndex) {
                LargeSlidePreview(slide: slide)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .center, spacing: 8) {
                    Text("No slide loaded")
                        .font(.headline)
                    Text("Open a presentation JSON deck to render the current slide.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .background(.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.black.opacity(0.12), lineWidth: 1)
                )
            }

            HStack(spacing: 8) {
                Button("Previous") {
                    viewModel.previousSlide()
                }
                .disabled(!viewModel.canGoPrevious)
                .keyboardShortcut(.leftArrow, modifiers: [])

                Spacer()

                Text(slidePositionLabel)
                    .font(.system(.headline, design: .monospaced))

                Spacer()

                Button("Next") {
                    viewModel.nextSlide()
                }
                .disabled(!viewModel.canGoNext)
                .keyboardShortcut(.rightArrow, modifiers: [])
            }

            HStack(spacing: 8) {
                Button("Push Context Update") {
                    viewModel.applyContextUpdate()
                }
                .disabled(!viewModel.isSessionActive)
                Spacer()
            }
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(viewModel.isStarting ? "Starting..." : "Start Realtime") {
                    Task {
                        await viewModel.startSession()
                    }
                }
                .disabled(viewModel.isStarting)

                Button("Stop") {
                    Task {
                        await viewModel.stopSession()
                    }
                }
                .disabled(!viewModel.isSessionActive)

                Spacer(minLength: 8)

                Text(viewModel.statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            GroupBox("Safety Gate") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledSlider(
                        label: "Confidence Threshold",
                        value: $viewModel.confidenceThreshold,
                        range: 0.0...1.0,
                        step: 0.01
                    )
                    LabeledSlider(
                        label: "Cooldown (seconds)",
                        value: $viewModel.cooldownSeconds,
                        range: 0.0...5.0,
                        step: 0.05
                    )
                    LabeledSlider(
                        label: "Dwell (seconds)",
                        value: $viewModel.dwellSeconds,
                        range: 0.0...3.0,
                        step: 0.05
                    )
                }
                .padding(.top, 4)
            }

            HStack {
                Text("Command Log")
                    .font(.headline)
                Spacer()
                Text("Connection: \(viewModel.connectionState)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    viewModel.clearLog()
                }
                Button(showBridgeView ? "Hide Bridge" : "Show Bridge") {
                    showBridgeView.toggle()
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(commandLogBottomID)
                    }
                    .padding(10)
                }
                .onAppear {
                    scrollCommandLogToBottom(proxy, animated: false)
                }
                .onChange(of: viewModel.logLines.count) { _, _ in
                    scrollCommandLogToBottom(proxy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if bridgeIsVisible {
                Text("Embedded WebRTC Transport")
                    .font(.headline)
            }

            RealtimeWebView(webView: viewModel.webView)
                .frame(height: bridgeIsVisible ? 220 : 1)
                .opacity(bridgeIsVisible ? 1.0 : 0.01)
                .allowsHitTesting(bridgeIsVisible)
                .accessibilityHidden(!bridgeIsVisible)
                .clipShape(RoundedRectangle(cornerRadius: bridgeIsVisible ? 8 : 0))
                .overlay {
                    if bridgeIsVisible {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.black.opacity(0.12), lineWidth: 1)
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var slidePositionLabel: String {
        guard viewModel.deckSlideCount > 0 else {
            return "-/-"
        }
        return "\(viewModel.currentSlideIndex)/\(viewModel.deckSlideCount)"
    }

    private func fixedPanelWidths(totalWidth: CGFloat) -> (leftWidth: CGFloat, rightWidth: CGFloat) {
        let contentWidth = max(0, totalWidth - panelGap)
        guard contentWidth > 0 else {
            return (0, 0)
        }

        let preferredLeft = contentWidth * leftPanelRatio
        let minLeft = min(minimumSlidePanelWidth, contentWidth)
        let maxLeft = max(0, contentWidth - minimumSidePanelWidth)

        let unclampedLeft: CGFloat
        if minLeft <= maxLeft {
            unclampedLeft = min(max(preferredLeft, minLeft), maxLeft)
        } else {
            unclampedLeft = preferredLeft
        }

        let leftWidth = min(max(unclampedLeft, 0), contentWidth)
        let rightWidth = max(0, contentWidth - leftWidth)
        return (leftWidth, rightWidth)
    }

    private func scrollCommandLogToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(commandLogBottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(commandLogBottomID, anchor: .bottom)
            }
        }
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(2))))
                    .font(.system(.body, design: .monospaced))
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

private struct LargeSlidePreview: View {
    let slide: PresentationSlide

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(slide.title)
                    .font(.title.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(slide.layout.rawValue.uppercased())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.08))
                    .clipShape(Capsule())
            }

            if !slide.subtitle.isEmpty {
                Text(slide.subtitle)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    contentBody
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.black.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var contentBody: some View {
        switch slide.layout {
        case .quote:
            if let quote = slide.quote, !quote.isEmpty {
                Text("\"\(quote)\"")
                    .font(.title2.italic())
            }
            if let attribution = slide.attribution, !attribution.isEmpty {
                Text(attribution)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        case .image:
            if let imagePlaceholder = slide.imagePlaceholder, !imagePlaceholder.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.06))
                    .overlay(
                        Text(imagePlaceholder)
                            .font(.body)
                            .padding(10)
                    )
                    .frame(minHeight: 180)
            }
            if let caption = slide.caption, !caption.isEmpty {
                Text(caption)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        case .twoColumn:
            HStack(alignment: .top, spacing: 20) {
                slideColumn(title: slide.leftColumn?.title ?? "Left", bullets: slide.leftColumn?.bullets ?? [])
                slideColumn(title: slide.rightColumn?.title ?? "Right", bullets: slide.rightColumn?.bullets ?? [])
                    .padding(.trailing, 10)
            }
        case .title, .bullets, .unknown:
            if slide.bullets.isEmpty {
                Text("No bullet content")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(slide.bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.title3.weight(.semibold))
                        Text(bullet)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
private func slideColumn(title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            if bullets.isEmpty {
                Text("No bullet content")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.title3.weight(.semibold))
                        Text(bullet)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
