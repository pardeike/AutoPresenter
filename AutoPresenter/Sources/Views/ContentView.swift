import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    @StateObject private var presenterBridge: AppPresenterWindowBridge
    @State private var presenterWindowManager = PresenterWindowManager()

    private let commandLogBottomID = "command-log-bottom"
    private let panelGap: CGFloat = 10
    private let leftPanelRatio: CGFloat = 3.0 / 5.0
    private let minimumSlidePanelWidth: CGFloat = 520
    private let minimumSidePanelWidth: CGFloat = 320

    init(viewModel: AppViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _presenterBridge = StateObject(wrappedValue: AppPresenterWindowBridge(viewModel: viewModel))
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
        .onAppear {
            AppCommandRelay.publishPresentationVisibility(presenterWindowManager.isVisible)
        }
        .onDisappear {
            presenterWindowManager.close()
            AppCommandRelay.publishPresentationVisibility(false)
            Task {
                await viewModel.stopSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommandRelay.togglePresentationRequestNotification)) { _ in
            if presenterWindowManager.isVisible {
                presenterWindowManager.close()
            } else if viewModel.deck != nil {
                presenterWindowManager.show(bridge: presenterBridge)
            }
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
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sessionControlRow

            HStack {
                Text(viewModel.usesDebugTextLogInMainWindow ? "Command Log" : "Activity")
                    .font(.headline)
                Spacer()
                if viewModel.usesDebugTextLogInMainWindow {
                    Text("Connection: \(viewModel.connectionState)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Clear") {
                    viewModel.clearVisibleFeed()
                }
            }

            diagnosticsPanel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var sessionControlRow: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                viewModel.toggleRealtimeSession()
            } label: {
                Text(viewModel.isMicrophoneHot ? "Stop" : "Record")
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isMicrophoneHot ? .green : .red)
            .disabled(!viewModel.canToggleSession || viewModel.isSessionTransitioning)
            .help(viewModel.isMicrophoneHot ? "Stop session" : "Start session")

            Button("Present") {
                presenterWindowManager.show(bridge: presenterBridge)
            }
            .disabled(viewModel.deck == nil)
            .help("Open Present mode")
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var diagnosticsPanel: some View {
        if viewModel.usesDebugTextLogInMainWindow {
            debugLogPanel
        } else {
            activityFeedPanel
        }
    }

    private var debugLogPanel: some View {
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
    }

    private var activityFeedPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.activityFeed) { entry in
                        activityFeedRow(entry)
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
            .onChange(of: viewModel.activityFeed.count) { _, _ in
                scrollCommandLogToBottom(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func activityFeedRow(_ entry: ActivityFeedEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(activityColor(entry.level))
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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

    private func activityColor(_ level: ActivityFeedLevel) -> Color {
        switch level {
        case .info:
            return Color(red: 0.31, green: 0.52, blue: 0.86)
        case .success:
            return Color(red: 0.22, green: 0.64, blue: 0.31)
        case .warning:
            return Color(red: 0.89, green: 0.58, blue: 0.17)
        case .error:
            return Color(red: 0.86, green: 0.26, blue: 0.24)
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

@MainActor
private final class AppPresenterWindowBridge: ObservableObject, PresenterWindowBridge {
    private let viewModel: AppViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    var initialState: PresenterWindowState {
        makeState()
    }

    var stateUpdates: AnyPublisher<PresenterWindowState, Never> {
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .map { [weak self] _ in
                self?.makeState() ?? .empty
            }
            .prepend(makeState())
            .eraseToAnyPublisher()
    }

    func handlePresenterAction(_ action: PresenterWindowAction) {
        switch action {
        case .previousSlide:
            viewModel.previousSlide()
        case .nextSlide:
            viewModel.nextSlide()
        case .toggleSession:
            viewModel.toggleRealtimeSession()
        case .closed:
            break
        }
    }

    private func makeState() -> PresenterWindowState {
        PresenterWindowState(
            slide: viewModel.deck?.slide(at: viewModel.currentSlideIndex),
            highlightPhrases: viewModel.currentSlideHighlightPhrases,
            markedSegmentIndices: viewModel.currentSlideMarkedSegmentIndices,
            sessionPhase: viewModel.sessionPhase,
            isSessionTransitioning: viewModel.isSessionTransitioning,
            canToggleSession: viewModel.canToggleSession
        )
    }
}
