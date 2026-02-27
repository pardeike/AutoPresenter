import AppKit
import SwiftUI

@MainActor
final class PresenterWindowManager: NSObject, NSWindowDelegate {
    private var window: EscapeClosableWindow?

    func show(viewModel: AppViewModel) {
        if let window {
            if let hostingController = window.contentViewController as? NSHostingController<PresenterRootView> {
                hostingController.rootView = PresenterRootView(
                    viewModel: viewModel,
                    onExit: { [weak self] in
                        self?.close()
                    }
                )
            }
            configureKeyHandling(for: window, viewModel: viewModel)
            window.makeKeyAndOrderFront(nil)
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            return
        }

        let initialRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let presenterWindow = EscapeClosableWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        presenterWindow.title = "AutoPresenter"
        presenterWindow.titleVisibility = .hidden
        presenterWindow.titlebarAppearsTransparent = true
        presenterWindow.collectionBehavior = [.fullScreenPrimary]
        presenterWindow.backgroundColor = .black
        presenterWindow.isReleasedWhenClosed = false
        presenterWindow.delegate = self
        presenterWindow.center()

        let hostingController = NSHostingController(
            rootView: PresenterRootView(
                viewModel: viewModel,
                onExit: { [weak self] in
                    self?.close()
                }
            )
        )
        presenterWindow.contentViewController = hostingController
        configureKeyHandling(for: presenterWindow, viewModel: viewModel)
        window = presenterWindow

        presenterWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak presenterWindow] in
            guard let presenterWindow, presenterWindow.isVisible else { return }
            if !presenterWindow.styleMask.contains(.fullScreen) {
                presenterWindow.toggleFullScreen(nil)
            }
        }
    }

    func close() {
        guard let window else { return }
        window.close()
        self.window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func configureKeyHandling(for window: EscapeClosableWindow, viewModel: AppViewModel) {
        window.onKeyDown = { [weak self, weak viewModel] event in
            guard let self, let viewModel else { return false }
            return self.handleKeyDown(event, viewModel: viewModel)
        }
    }

    private func handleKeyDown(_ event: NSEvent, viewModel: AppViewModel) -> Bool {
        switch event.keyCode {
        case 123: // Left arrow
            viewModel.previousSlide()
            return true
        case 124: // Right arrow
            viewModel.nextSlide()
            return true
        case 49: // Space
            guard !event.isARepeat else { return true }
            viewModel.toggleRealtimeSessionFromPresenter()
            return true
        default:
            return false
        }
    }
}

private final class EscapeClosableWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
            return
        }
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

private struct PresenterRootView: View {
    @ObservedObject var viewModel: AppViewModel
    let onExit: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.07, blue: 0.10),
                    Color(red: 0.02, green: 0.02, blue: 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let slide = viewModel.deck?.slide(at: viewModel.currentSlideIndex) {
                PresenterSlideView(
                    slide: slide,
                    highlightPhrases: viewModel.currentSlideHighlightPhrases,
                    markedSegmentIndices: viewModel.currentSlideMarkedSegmentIndices
                )
            } else {
                VStack(spacing: 16) {
                    Text("No slide loaded")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                    Text("Open a presentation to start Present mode.")
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(80)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ListeningIndicatorDot(
                isSessionActive: viewModel.isSessionActive,
                isSpeechDetected: viewModel.isSpeechDetected
            )
            .padding(.trailing, 24)
            .padding(.bottom, 20)
        }
        .onExitCommand(perform: onExit)
    }
}

private struct ListeningIndicatorDot: View {
    let isSessionActive: Bool
    let isSpeechDetected: Bool

    private var fillColor: Color {
        if isSpeechDetected {
            return Color(red: 0.98, green: 0.24, blue: 0.24)
        }
        if isSessionActive {
            return Color(red: 0.68, green: 0.23, blue: 0.23)
        }
        return Color(red: 0.38, green: 0.17, blue: 0.17)
    }

    private var dotOpacity: Double {
        isSessionActive ? 0.96 : 0.42
    }

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: 16, height: 16)
            .opacity(dotOpacity)
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.26), lineWidth: 1)
            }
            .shadow(color: fillColor.opacity(0.45), radius: isSpeechDetected ? 7 : 3, x: 0, y: 0)
            .animation(.easeOut(duration: 0.12), value: isSpeechDetected)
            .animation(.easeOut(duration: 0.18), value: isSessionActive)
    }
}

private struct PresenterSlideView: View {
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
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 34) {
                header
                contentBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 88)
            .padding(.vertical, 76)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if segmentBuckets.title.isEmpty {
                Text("Untitled")
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                ForEach(segmentBuckets.title, id: \.index) { segment in
                    segmentText(segment)
                        .font(.system(size: 68, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !segmentBuckets.subtitle.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(segmentBuckets.subtitle, id: \.index) { segment in
                        segmentText(segment)
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch slide.layout {
        case .quote:
            if !segmentBuckets.quote.isEmpty {
                ForEach(segmentBuckets.quote, id: \.index) { segment in
                    segmentText(segment)
                        .font(.system(size: 56, weight: .semibold, design: .serif).italic())
                        .foregroundStyle(.white)
                }
            }
            if !segmentBuckets.attribution.isEmpty {
                ForEach(segmentBuckets.attribution, id: \.index) { segment in
                    segmentText(segment)
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
        case .image:
            if !segmentBuckets.imagePlaceholder.isEmpty {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white.opacity(0.10))
                    .overlay(
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(segmentBuckets.imagePlaceholder, id: \.index) { segment in
                                segmentText(segment)
                                    .font(.system(size: 34, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.90))
                            }
                        }
                            .padding(26)
                    )
                    .frame(minHeight: 300)
            }
            if !segmentBuckets.caption.isEmpty {
                ForEach(segmentBuckets.caption, id: \.index) { segment in
                    segmentText(segment)
                        .font(.system(size: 30, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
        case .twoColumn:
            HStack(alignment: .top, spacing: 54) {
                presenterColumn(
                    titleSegments: segmentBuckets.leftTitle,
                    bulletSegments: segmentBuckets.leftBullets,
                    fallbackTitle: "Left"
                )
                presenterColumn(
                    titleSegments: segmentBuckets.rightTitle,
                    bulletSegments: segmentBuckets.rightBullets,
                    fallbackTitle: "Right"
                )
            }
        case .title, .bullets, .unknown:
            if segmentBuckets.bodyBullets.isEmpty {
                Text("No bullet content")
                    .font(.system(size: 34, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                ForEach(segmentBuckets.bodyBullets, id: \.index) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Text("•")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                        segmentText(segment)
                            .font(.system(size: 42, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func presenterColumn(
        titleSegments: [SlideMarkSegment],
        bulletSegments: [SlideMarkSegment],
        fallbackTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if titleSegments.isEmpty {
                Text(fallbackTitle)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                ForEach(titleSegments, id: \.index) { segment in
                    segmentText(segment)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }

            if bulletSegments.isEmpty {
                Text("No bullet content")
                    .font(.system(size: 34, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                ForEach(bulletSegments, id: \.index) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Text("•")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                        segmentText(segment)
                            .font(.system(size: 34, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
            attributed[fullRange].foregroundColor = Color(red: 1.0, green: 0.93, blue: 0.35)
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
                attributed[highlightedRange].foregroundColor = Color(red: 1.0, green: 0.90, blue: 0.30)
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
