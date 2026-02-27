import AppKit
import Combine
import SwiftUI

struct PresenterWindowState: Sendable {
    let slide: PresentationSlide?
    let highlightPhrases: [String]
    let markedSegmentIndices: Set<Int>
    let sessionPhase: RealtimeSessionPhase
    let isSessionTransitioning: Bool
    let canToggleSession: Bool

    static let empty = PresenterWindowState(
        slide: nil,
        highlightPhrases: [],
        markedSegmentIndices: [],
        sessionPhase: .idle,
        isSessionTransitioning: false,
        canToggleSession: true
    )
}

enum PresenterWindowAction: Sendable {
    case previousSlide
    case nextSlide
    case toggleSession
    case closed
}

@MainActor
protocol PresenterWindowBridge: AnyObject {
    var initialState: PresenterWindowState { get }
    var stateUpdates: AnyPublisher<PresenterWindowState, Never> { get }
    func handlePresenterAction(_ action: PresenterWindowAction)
}

@MainActor
final class PresenterWindowManager: NSObject, NSWindowDelegate {
    private static let minimumWindowSize = NSSize(width: 640, height: 480)

    private var window: EscapeClosableWindow?
    private var presenterStateModel: PresenterStateModel?
    private weak var currentBridge: (any PresenterWindowBridge)?

    func show(bridge: any PresenterWindowBridge) {
        currentBridge = bridge
        let stateModel = PresenterStateModel(bridge: bridge)
        presenterStateModel = stateModel

        if let window {
            if let hostingController = window.contentViewController as? NSHostingController<PresenterRootView> {
                hostingController.rootView = PresenterRootView(
                    stateModel: stateModel,
                    onExit: { [weak self] in
                        self?.close()
                    }
                )
            }
            configureKeyHandling(for: window, stateModel: stateModel)
            enforceMinimumSize(on: window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let minimumWindowSize = Self.minimumWindowSize
        var initialRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        initialRect.size.width = max(initialRect.size.width, minimumWindowSize.width)
        initialRect.size.height = max(initialRect.size.height, minimumWindowSize.height)
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
        presenterWindow.minSize = minimumWindowSize
        presenterWindow.delegate = self
        enforceMinimumSize(on: presenterWindow)
        presenterWindow.center()

        let hostingController = NSHostingController(
            rootView: PresenterRootView(
                stateModel: stateModel,
                onExit: { [weak self] in
                    self?.close()
                }
            )
        )
        presenterWindow.contentViewController = hostingController
        configureKeyHandling(for: presenterWindow, stateModel: stateModel)
        window = presenterWindow

        presenterWindow.makeKeyAndOrderFront(nil)
    }

    private func enforceMinimumSize(on window: NSWindow) {
        let minimumWindowSize = Self.minimumWindowSize
        window.minSize = minimumWindowSize
        if window.frame.size.width < minimumWindowSize.width || window.frame.size.height < minimumWindowSize.height {
            var correctedFrame = window.frame
            correctedFrame.size.width = max(correctedFrame.size.width, minimumWindowSize.width)
            correctedFrame.size.height = max(correctedFrame.size.height, minimumWindowSize.height)
            window.setFrame(correctedFrame, display: true, animate: false)
        }
    }

    func close() {
        currentBridge?.handlePresenterAction(.closed)
        currentBridge = nil
        presenterStateModel = nil
        guard let window else { return }
        window.close()
        self.window = nil
    }

    func windowWillClose(_ notification: Notification) {
        currentBridge?.handlePresenterAction(.closed)
        currentBridge = nil
        presenterStateModel = nil
        window = nil
    }

    private func configureKeyHandling(for window: EscapeClosableWindow, stateModel: PresenterStateModel) {
        window.onKeyDown = { [weak self, weak stateModel] event in
            guard let self, let stateModel else { return false }
            return self.handleKeyDown(event, stateModel: stateModel)
        }
    }

    private func handleKeyDown(_ event: NSEvent, stateModel: PresenterStateModel) -> Bool {
        switch event.keyCode {
        case 123: // Left arrow
            stateModel.send(.previousSlide)
            return true
        case 124: // Right arrow
            stateModel.send(.nextSlide)
            return true
        case 49: // Space
            guard !event.isARepeat else { return true }
            stateModel.send(.toggleSession)
            return true
        default:
            return false
        }
    }
}

@MainActor
private final class PresenterStateModel: ObservableObject {
    @Published private(set) var state: PresenterWindowState

    private weak var bridge: (any PresenterWindowBridge)?
    private var cancellable: AnyCancellable?

    init(bridge: any PresenterWindowBridge) {
        self.bridge = bridge
        state = bridge.initialState
        cancellable = bridge.stateUpdates
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.state = newState
            }
    }

    func send(_ action: PresenterWindowAction) {
        bridge?.handlePresenterAction(action)
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
    @ObservedObject var stateModel: PresenterStateModel
    let onExit: () -> Void

    var body: some View {
        let state = stateModel.state

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

            if let slide = state.slide {
                PresenterSlideView(
                    slide: slide,
                    highlightPhrases: state.highlightPhrases,
                    markedSegmentIndices: state.markedSegmentIndices
                )
            } else if !AppBuildFlags.strictFullscreenAudienceMode {
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
            PresenterSessionControl(
                phase: state.sessionPhase,
                isBusy: state.isSessionTransitioning,
                isEnabled: state.canToggleSession,
                onToggle: {
                    stateModel.send(.toggleSession)
                }
            )
            .padding(.trailing, 24)
            .padding(.bottom, 20)
        }
        .onExitCommand(perform: onExit)
    }
}

private struct PresenterSessionControl: View {
    let phase: RealtimeSessionPhase
    let isBusy: Bool
    let isEnabled: Bool
    let onToggle: () -> Void

    private var ledColor: Color {
        switch phase {
        case .idle:
            return Color(red: 0.38, green: 0.17, blue: 0.17)
        case .starting, .connecting:
            return Color(red: 0.95, green: 0.65, blue: 0.16)
        case .listening:
            return Color(red: 0.68, green: 0.23, blue: 0.23)
        case .speaking:
            return Color(red: 0.98, green: 0.24, blue: 0.24)
        case .processing:
            return Color(red: 0.90, green: 0.52, blue: 0.16)
        case .stopped:
            return Color(red: 0.32, green: 0.32, blue: 0.34)
        case .error:
            return Color(red: 0.85, green: 0.19, blue: 0.19)
        }
    }

    private var isActive: Bool {
        phase.showsActiveRecordingControl
    }

    private var ringColor: Color {
        isEnabled ? .white.opacity(0.58) : .white.opacity(0.30)
    }

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.20))
                    .frame(width: 38, height: 38)
                    .overlay {
                        Circle()
                            .strokeBorder(ringColor, lineWidth: 2)
                    }

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.9))
                } else {
                    Circle()
                        .fill(ledColor)
                        .frame(width: isActive ? 11 : 9, height: isActive ? 11 : 9)
                        .shadow(color: ledColor.opacity(0.45), radius: phase == .speaking ? 8 : 3, x: 0, y: 0)
                }
            }
            .animation(.easeOut(duration: 0.12), value: phase)
            .animation(.easeOut(duration: 0.12), value: isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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
                if !AppBuildFlags.strictFullscreenAudienceMode {
                    Text("Untitled")
                        .font(.system(size: 68, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
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
                    fallbackTitle: AppBuildFlags.strictFullscreenAudienceMode ? nil : "Left"
                )
                presenterColumn(
                    titleSegments: segmentBuckets.rightTitle,
                    bulletSegments: segmentBuckets.rightBullets,
                    fallbackTitle: AppBuildFlags.strictFullscreenAudienceMode ? nil : "Right"
                )
            }
        case .title, .bullets, .unknown:
            if segmentBuckets.bodyBullets.isEmpty {
                if !AppBuildFlags.strictFullscreenAudienceMode {
                    Text("No bullet content")
                        .font(.system(size: 34, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
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
        fallbackTitle: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if titleSegments.isEmpty {
                if let fallbackTitle {
                    Text(fallbackTitle)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            } else {
                ForEach(titleSegments, id: \.index) { segment in
                    segmentText(segment)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }

            if bulletSegments.isEmpty {
                if !AppBuildFlags.strictFullscreenAudienceMode {
                    Text("No bullet content")
                        .font(.system(size: 34, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
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
