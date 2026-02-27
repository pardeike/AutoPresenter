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
                LargeSlidePreview(
                    slide: slide,
                    highlightPhrases: viewModel.currentSlideHighlightPhrases,
                    markedSegmentIndices: viewModel.currentSlideMarkedSegmentIndices
                )
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
    let highlightPhrases: [String]
    let markedSegmentIndices: Set<Int>

    private var segmentBuckets: SlideSegmentBuckets {
        slide.segmentBuckets()
    }

    private var normalizedHighlightPhrases: [String] {
        var seen: Set<String> = []
        let cleaned = highlightPhrases.compactMap { phrase -> String? in
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return nil }
            guard trimmed.count <= 120 else { return nil }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return trimmed
        }
        return cleaned.sorted { $0.count > $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if segmentBuckets.title.isEmpty {
                        Text("Untitled")
                            .font(.title.weight(.semibold))
                    } else {
                        ForEach(segmentBuckets.title, id: \.index) { segment in
                            segmentTextRow(segment, font: .title.weight(.semibold))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(slide.layout.rawValue.uppercased())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.08))
                    .clipShape(Capsule())
            }

            if !segmentBuckets.subtitle.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(segmentBuckets.subtitle, id: \.index) { segment in
                        segmentTextRow(segment, font: .title3.weight(.medium), secondary: true)
                    }
                }
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
            if !segmentBuckets.quote.isEmpty {
                ForEach(segmentBuckets.quote, id: \.index) { segment in
                    segmentTextRow(segment, font: .title2.italic())
                }
            }
            if !segmentBuckets.attribution.isEmpty {
                ForEach(segmentBuckets.attribution, id: \.index) { segment in
                    segmentTextRow(segment, font: .body, secondary: true)
                }
            }
        case .image:
            if !segmentBuckets.imagePlaceholder.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.06))
                    .overlay(
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(segmentBuckets.imagePlaceholder, id: \.index) { segment in
                                segmentTextRow(segment, font: .body)
                            }
                        }
                        .padding(10)
                    )
                    .frame(minHeight: 180)
            }
            if !segmentBuckets.caption.isEmpty {
                ForEach(segmentBuckets.caption, id: \.index) { segment in
                    segmentTextRow(segment, font: .body, secondary: true)
                }
            }
        case .twoColumn:
            HStack(alignment: .top, spacing: 20) {
                slideColumn(
                    titleSegments: segmentBuckets.leftTitle,
                    bulletSegments: segmentBuckets.leftBullets,
                    fallbackTitle: "Left"
                )
                slideColumn(
                    titleSegments: segmentBuckets.rightTitle,
                    bulletSegments: segmentBuckets.rightBullets,
                    fallbackTitle: "Right"
                )
                    .padding(.trailing, 10)
            }
        case .title, .bullets, .unknown:
            if segmentBuckets.bodyBullets.isEmpty {
                Text("No bullet content")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(segmentBuckets.bodyBullets, id: \.index) { segment in
                    bulletSegmentRow(segment)
                }
            }
        }
    }

    @ViewBuilder
    private func slideColumn(
        titleSegments: [SlideMarkSegment],
        bulletSegments: [SlideMarkSegment],
        fallbackTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if titleSegments.isEmpty {
                Text(fallbackTitle)
                    .font(.title3.weight(.semibold))
            } else {
                ForEach(titleSegments, id: \.index) { segment in
                    segmentTextRow(segment, font: .title3.weight(.semibold))
                }
            }

            if bulletSegments.isEmpty {
                Text("No bullet content")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bulletSegments, id: \.index) { segment in
                    bulletSegmentRow(segment)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func bulletSegmentRow(_ segment: SlideMarkSegment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            segmentIndexBadge(segment)
            Text("•")
                .font(.title3.weight(.semibold))
            segmentText(segment)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func segmentTextRow(_ segment: SlideMarkSegment, font: Font, secondary: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            segmentIndexBadge(segment)
            segmentText(segment)
                .font(font)
                .foregroundStyle(secondary ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func segmentIndexBadge(_ segment: SlideMarkSegment) -> some View {
        HStack(spacing: 4) {
            Text("\(segment.index)")
                .font(.caption2.weight(.bold))
            Text(segment.kind)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.black.opacity(0.08))
        .clipShape(Capsule())
    }

    private func segmentText(_ segment: SlideMarkSegment) -> Text {
        Text(
            makeHighlightedAttributedString(
                from: segment.text,
                isMarkedByIndex: markedSegmentIndices.contains(segment.index)
            )
        )
    }

    private func makeHighlightedAttributedString(from rawText: String, isMarkedByIndex: Bool) -> AttributedString {
        var attributed = AttributedString(rawText)

        if isMarkedByIndex {
            let fullRange = attributed.startIndex..<attributed.endIndex
            attributed[fullRange].backgroundColor = .yellow.opacity(0.75)
            attributed[fullRange].foregroundColor = .primary
        }

        for phrase in normalizedHighlightPhrases {
            let ranges = highlightRanges(of: phrase, in: rawText)
            for nsRange in ranges {
                guard
                    let stringRange = Range(nsRange, in: rawText),
                    let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                    let upper = AttributedString.Index(stringRange.upperBound, within: attributed)
                else {
                    continue
                }

                let highlightedRange = lower..<upper
                attributed[highlightedRange].backgroundColor = .yellow.opacity(0.6)
                attributed[highlightedRange].foregroundColor = .primary
            }
        }

        return attributed
    }

    private func highlightRanges(of phrase: String, in text: String) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.length > 0 {
            let foundRange = nsText.range(
                of: phrase,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )

            guard foundRange.location != NSNotFound else {
                break
            }

            ranges.append(foundRange)
            let nextLocation = foundRange.location + max(foundRange.length, 1)
            guard nextLocation < nsText.length else {
                break
            }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return ranges
    }
}
