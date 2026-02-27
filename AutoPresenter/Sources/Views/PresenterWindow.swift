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
    private static let frameDefaultsKey = "AutoPresenter.PresenterWindow.FrameString"

    private var window: EscapeClosableWindow?
    private var presenterStateModel: PresenterStateModel?
    private weak var currentBridge: (any PresenterWindowBridge)?
    private var frameObserverTokens: [NSObjectProtocol] = []
    private var lastPersistedFrame: NSRect?
    private var suppressFramePersistence = false

    var isVisible: Bool {
        window?.isVisible ?? false
    }

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
            AppCommandRelay.publishPresentationVisibility(true)
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
        let restoredFrame = restorePersistedFrame(on: presenterWindow)
        enforceMinimumSize(on: presenterWindow)
        if restoredFrame == nil {
            presenterWindow.center()
        }

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
        suppressFramePersistence = true
        installFrameObservers(for: presenterWindow)

        presenterWindow.makeKeyAndOrderFront(nil)
        AppCommandRelay.publishPresentationVisibility(true)
        if let restoredFrame {
            reapplyRestoredFrame(restoredFrame, on: presenterWindow, delay: 0)
            reapplyRestoredFrame(restoredFrame, on: presenterWindow, delay: 0.25)
            reapplyRestoredFrame(restoredFrame, on: presenterWindow, delay: 0.8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.suppressFramePersistence = false
        }
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
        guard let window else { return }
        persistFrame(of: window)
        window.close()
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        persistFrame(of: window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        persistFrame(of: window)
    }

    func windowWillClose(_ notification: Notification) {
        removeFrameObservers()
        currentBridge?.handlePresenterAction(.closed)
        currentBridge = nil
        presenterStateModel = nil
        window = nil
        AppCommandRelay.publishPresentationVisibility(false)
    }

    private func restorePersistedFrame(on window: NSWindow) -> NSRect? {
        if let lastPersistedFrame, isValidPersistedFrame(lastPersistedFrame) {
            window.setFrame(lastPersistedFrame, display: true, animate: false)
            return lastPersistedFrame
        }
        guard let frameString = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) else {
            return nil
        }
        let restoredFrame = NSRectFromString(frameString)
        guard isValidPersistedFrame(restoredFrame) else {
            return nil
        }
        if looksLikeLegacyCorruptedFrame(restoredFrame) {
            UserDefaults.standard.removeObject(forKey: Self.frameDefaultsKey)
            return nil
        }
        lastPersistedFrame = restoredFrame
        window.setFrame(restoredFrame, display: true, animate: false)
        return restoredFrame
    }

    private func persistFrame(of window: NSWindow) {
        guard !suppressFramePersistence else {
            return
        }
        let frame = window.frame
        guard isValidPersistedFrame(frame) else {
            return
        }
        let minimumWindowSize = Self.minimumWindowSize
        if frame.size.width <= minimumWindowSize.width + 1,
           frame.size.height <= minimumWindowSize.height + 1,
           let existing = lastPersistedFrame,
           existing.size.width > minimumWindowSize.width + 1,
           existing.size.height > minimumWindowSize.height + 1 {
            return
        }
        lastPersistedFrame = frame
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameDefaultsKey)
    }

    private func installFrameObservers(for window: NSWindow) {
        removeFrameObservers()
        let notificationCenter = NotificationCenter.default
        let windowObject = window as AnyObject

        let moveToken = notificationCenter.addObserver(
            forName: NSWindow.didMoveNotification,
            object: windowObject,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window else { return }
                self.persistFrame(of: window)
            }
        }

        let resizeToken = notificationCenter.addObserver(
            forName: NSWindow.didResizeNotification,
            object: windowObject,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window else { return }
                self.persistFrame(of: window)
            }
        }

        frameObserverTokens = [moveToken, resizeToken]
    }

    private func removeFrameObservers() {
        guard !frameObserverTokens.isEmpty else {
            return
        }
        let notificationCenter = NotificationCenter.default
        for token in frameObserverTokens {
            notificationCenter.removeObserver(token)
        }
        frameObserverTokens.removeAll(keepingCapacity: true)
    }

    private func isValidPersistedFrame(_ frame: NSRect) -> Bool {
        frame.size.width > 64 && frame.size.height > 64
    }

    private func looksLikeLegacyCorruptedFrame(_ frame: NSRect) -> Bool {
        let minimumWindowSize = Self.minimumWindowSize
        let isMinimumSize =
            abs(frame.size.width - minimumWindowSize.width) <= 1 &&
            abs(frame.size.height - minimumWindowSize.height) <= 1
        let isNearLowerLeftCorner = frame.origin.x <= 8 && frame.origin.y <= 80
        return isMinimumSize && isNearLowerLeftCorner
    }

    private func reapplyRestoredFrame(_ frame: NSRect, on window: NSWindow, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
            guard let window else {
                return
            }
            window.setFrame(frame, display: true, animate: false)
        }
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
                    .frame(width: 30, height: 30)
                    .overlay {
                        Circle()
                            .strokeBorder(ringColor, lineWidth: 1.8)
                    }

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.9))
                } else {
                    Circle()
                        .fill(ledColor)
                        .frame(width: isActive ? 10 : 8, height: isActive ? 10 : 8)
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
