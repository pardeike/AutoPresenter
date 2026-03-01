import AppKit
import AVFoundation
import Combine
import SwiftUI

struct PresenterWindowState: Sendable {
    let slide: PresentationSlide?
    let highlightPhrases: [String]
    let markedSegmentIndices: Set<Int>
    let sessionPhase: RealtimeSessionPhase
    let isSessionTransitioning: Bool
    let canToggleSession: Bool
    let deckDirectoryPath: String?
    let quoteAudioStartDelayMilliseconds: Double
    let quoteAudioPostPlaybackWaitMilliseconds: Double

    static let empty = PresenterWindowState(
        slide: nil,
        highlightPhrases: [],
        markedSegmentIndices: [],
        sessionPhase: .idle,
        isSessionTransitioning: false,
        canToggleSession: true,
        deckDirectoryPath: nil,
        quoteAudioStartDelayMilliseconds: 900,
        quoteAudioPostPlaybackWaitMilliseconds: 2_000
    )
}

enum PresenterWindowAction: Sendable {
    case previousSlide
    case nextSlide
    case toggleSession
    case quoteAudioStarted
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
                    Color(red: 0.09, green: 0.15, blue: 0.22),
                    Color(red: 0.03, green: 0.07, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let slide = state.slide {
                PresenterSlideView(
                    slide: slide,
                    highlightPhrases: state.highlightPhrases,
                    markedSegmentIndices: state.markedSegmentIndices,
                    deckDirectoryPath: state.deckDirectoryPath,
                    quoteAudioStartDelayMilliseconds: state.quoteAudioStartDelayMilliseconds,
                    quoteAudioPostPlaybackWaitMilliseconds: state.quoteAudioPostPlaybackWaitMilliseconds,
                    onQuoteAudioStarted: {
                        stateModel.send(.quoteAudioStarted)
                    },
                    onQuoteAudioFinished: {
                        stateModel.send(.nextSlide)
                    }
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
    let deckDirectoryPath: String?
    let quoteAudioStartDelayMilliseconds: Double
    let quoteAudioPostPlaybackWaitMilliseconds: Double
    let onQuoteAudioStarted: () -> Void
    let onQuoteAudioFinished: () -> Void
    @State private var imageStageOpacity: Double = 1
    @StateObject private var quoteAudioPlayer = PresenterQuoteAudioPlayer()
    @State private var pendingQuoteAutoAdvanceWorkItem: DispatchWorkItem?
    private let steelDimText = Color(red: 0.58, green: 0.69, blue: 0.80).opacity(0.38)
    private let steelDimSecondaryText = Color(red: 0.51, green: 0.62, blue: 0.73).opacity(0.30)
    private let steelBrightText = Color(red: 0.92, green: 0.97, blue: 1.00)
    private let steelBullet = Color(red: 0.63, green: 0.74, blue: 0.85).opacity(0.48)

    private var quoteAudioStartDelaySeconds: Double {
        max(quoteAudioStartDelayMilliseconds, 0) / 1_000
    }

    private var quotePostAudioAdvanceDelaySeconds: Double {
        max(quoteAudioPostPlaybackWaitMilliseconds, 0) / 1_000
    }

    private var segmentBuckets: SlideSegmentBuckets {
        slide.segmentBuckets()
    }

    private var imageEntries: [SlideImagePathEntry] {
        SlideImagePathResolver.resolveEntries(
            from: slide.imagePlaceholderParagraphs,
            deckDirectoryPath: deckDirectoryPath
        )
    }

    private var quoteAudioURL: URL? {
        guard
            let quoteAudioPath = slide.quoteAudioPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !quoteAudioPath.isEmpty
        else {
            return nil
        }

        let entry = SlideImagePathResolver.resolveEntries(
            from: [quoteAudioPath],
            deckDirectoryPath: deckDirectoryPath
        ).first

        guard let resolvedURL = entry?.resolvedURL else {
            return nil
        }
        guard resolvedURL.pathExtension.lowercased() == "mp3" else {
            return nil
        }
        return resolvedURL
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
        Group {
            if slide.layout == .image {
                imageSlideBody
            } else if slide.layout == .quote {
                quoteSlideBody
            } else {
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
        }
        .onAppear {
            handleQuoteAudioSlideActivation()
        }
        .onChange(of: slide.id) { _, _ in
            handleQuoteAudioSlideActivation()
        }
        .onDisappear {
            quoteAudioPlayer.stop()
            cancelPendingQuoteAutoAdvance()
        }
    }

    private var quoteSlideBody: some View {
        ZStack(alignment: .topLeading) {
            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            header
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 88)
        .padding(.vertical, 76)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var imageSlideBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            imageStage
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(imageStageOpacity)
                .onAppear {
                    triggerImageFadeIn()
                }
                .onChange(of: slide.id) { _, _ in
                    triggerImageFadeIn()
                }

            if !segmentBuckets.caption.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(segmentBuckets.caption, id: \.index) { segment in
                        segmentText(segment)
                            .font(.system(size: 30, weight: .regular, design: .rounded))
                            .foregroundStyle(steelDimSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 88)
        .padding(.top, 72)
        .padding(.bottom, 40)
    }

    @ViewBuilder
    private var imageStage: some View {
        if imageEntries.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(steelDimText)
                Text("No images configured")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(steelDimText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if imageEntries.count <= 3 {
            featuredImageLayout
        } else {
            switch slide.imagePresentationStyle {
            case .scroll:
                PresenterImageMarquee(
                    imageEntries: imageEntries,
                    speed: CGFloat(max(min(slide.imageScrollSpeed, 800.0), -800.0)),
                    slideID: slide.id
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !segmentBuckets.title.isEmpty {
                ForEach(segmentBuckets.title, id: \.index) { segment in
                    segmentText(segment)
                        .font(.system(size: 68, weight: .bold, design: .rounded))
                        .foregroundStyle(steelDimText)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !segmentBuckets.subtitle.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(segmentBuckets.subtitle, id: \.index) { segment in
                        segmentText(segment)
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .foregroundStyle(steelDimSecondaryText)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var contentBody: some View {
        switch slide.layout {
        case .quote:
            if !segmentBuckets.quote.isEmpty {
                VStack(alignment: .center, spacing: 20) {
                    ForEach(segmentBuckets.quote, id: \.index) { segment in
                        segmentText(segment)
                            .font(.system(size: 56, weight: .semibold, design: .serif).italic())
                            .foregroundStyle(steelDimText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        case .image:
            EmptyView()
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
                        .foregroundStyle(steelDimSecondaryText)
                }
            } else {
                ForEach(segmentBuckets.bodyBullets, id: \.index) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Text("•")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(steelBullet)
                        segmentText(segment)
                            .font(.system(size: 42, weight: .medium, design: .rounded))
                            .foregroundStyle(steelDimText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var featuredImageLayout: some View {
        GeometryReader { proxy in
            let scales = imageScaleFactors
            let ratios = imageAspectRatios
            let spacing = featuredImageSpacing
            let horizontalGapCount = CGFloat(max(ratios.count - 1, 0))
            let availableWidth = max(proxy.size.width - spacing * horizontalGapCount, 1)
            let widthWeights = zip(ratios, scales).map { ratio, scale in
                ratio * scale
            }
            let totalWidthWeight = max(widthWeights.reduce(0, +), 0.1)
            let fittedBaseHeight = min(proxy.size.height, availableWidth / totalWidthWeight)

            HStack(alignment: .center, spacing: featuredImageSpacing) {
                ForEach(Array(imageEntries.enumerated()), id: \.offset) { index, entry in
                    presenterImageCard(entry: entry)
                        .frame(
                            width: max(1, fittedBaseHeight * widthWeights[index]),
                            height: max(1, fittedBaseHeight * scales[index])
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var featuredImageSpacing: CGFloat {
        imageEntries.count == 1 ? 0 : 14
    }

    private var imageScaleFactors: [CGFloat] {
        imageEntries.map { min(max($0.scaleFactor, 0.05), 3.0) }
    }

    private var imageAspectRatios: [CGFloat] {
        imageEntries.map { entry in
            guard
                let image = SlideImageLoader.shared.image(for: entry),
                image.size.height > 0
            else {
                return 1.25
            }
            let ratio = image.size.width / image.size.height
            return max(min(ratio, 3.0), 0.45)
        }
    }

    @ViewBuilder
    private func presenterImageCard(entry: SlideImagePathEntry) -> some View {
        if let image = SlideImageLoader.shared.image(for: entry) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(steelDimText)
                Text(entry.displayName)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundStyle(steelDimText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func triggerImageFadeIn() {
        guard slide.layout == .image else {
            imageStageOpacity = 1
            return
        }
        imageStageOpacity = 0
        withAnimation(.easeOut(duration: 0.22)) {
            imageStageOpacity = 1
        }
    }

    private func handleQuoteAudioSlideActivation() {
        quoteAudioPlayer.stop()
        cancelPendingQuoteAutoAdvance()

        guard slide.layout == .quote else {
            return
        }
        let quoteIndices = Set(segmentBuckets.quote.map(\.index))
        guard !quoteIndices.isEmpty else {
            return
        }
        guard markedSegmentIndices.isDisjoint(with: quoteIndices) else {
            return
        }
        guard let quoteAudioURL else {
            return
        }

        quoteAudioPlayer.play(
            from: quoteAudioURL,
            delaySeconds: quoteAudioStartDelaySeconds,
            onPlaybackStarted: onQuoteAudioStarted,
            onPlaybackFinished: scheduleQuoteAutoAdvance
        )
    }

    private func scheduleQuoteAutoAdvance() {
        cancelPendingQuoteAutoAdvance()
        let workItem = DispatchWorkItem {
            onQuoteAudioFinished()
        }
        pendingQuoteAutoAdvanceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + quotePostAudioAdvanceDelaySeconds,
            execute: workItem
        )
    }

    private func cancelPendingQuoteAutoAdvance() {
        pendingQuoteAutoAdvanceWorkItem?.cancel()
        pendingQuoteAutoAdvanceWorkItem = nil
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
                        .foregroundStyle(steelDimText)
                }
            } else {
                ForEach(titleSegments, id: \.index) { segment in
                    segmentText(segment)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(steelDimText)
                }
            }

            if bulletSegments.isEmpty {
                if !AppBuildFlags.strictFullscreenAudienceMode {
                    Text("No bullet content")
                        .font(.system(size: 34, weight: .regular, design: .rounded))
                        .foregroundStyle(steelDimSecondaryText)
                }
            } else {
                ForEach(bulletSegments, id: \.index) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Text("•")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(steelBullet)
                        segmentText(segment)
                            .font(.system(size: 34, weight: .medium, design: .rounded))
                            .foregroundStyle(steelDimText)
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
            attributed[fullRange].foregroundColor = steelBrightText
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
                attributed[highlightedRange].foregroundColor = steelBrightText
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
private final class PresenterQuoteAudioPlayer: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    private var pendingStartWorkItem: DispatchWorkItem?
    private var audioPlayer: AVAudioPlayer?
    private var pendingOnPlaybackStarted: (() -> Void)?
    private var pendingOnPlaybackFinished: (() -> Void)?

    func play(
        from url: URL,
        delaySeconds: Double,
        onPlaybackStarted: @escaping () -> Void,
        onPlaybackFinished: @escaping () -> Void
    ) {
        stop()
        pendingOnPlaybackStarted = onPlaybackStarted
        pendingOnPlaybackFinished = onPlaybackFinished
        let workItem = DispatchWorkItem { [weak self] in
            self?.startPlayback(from: url)
        }
        pendingStartWorkItem = workItem
        let delay = max(delaySeconds, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func stop() {
        pendingStartWorkItem?.cancel()
        pendingStartWorkItem = nil
        pendingOnPlaybackStarted = nil
        pendingOnPlaybackFinished = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func startPlayback(from url: URL) {
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let audioData = try? Data(contentsOf: url) else {
            return
        }
        guard let player = try? AVAudioPlayer(data: audioData) else {
            return
        }

        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            return
        }

        audioPlayer = player
        pendingOnPlaybackStarted?()
        pendingOnPlaybackStarted = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else {
            return
        }
        audioPlayer = nil
        guard flag else {
            pendingOnPlaybackFinished = nil
            return
        }
        pendingOnPlaybackFinished?()
        pendingOnPlaybackFinished = nil
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if player === audioPlayer {
            audioPlayer = nil
        }
        pendingOnPlaybackFinished = nil
    }
}

private struct PresenterImageMarquee: View {
    let imageEntries: [SlideImagePathEntry]
    let speed: CGFloat
    let slideID: Int

    private let spacing: CGFloat = 16
    @State private var baseTravel: CGFloat = 0
    @State private var animationStartDate: Date = .now

    private var imageAspectRatios: [CGFloat] {
        imageEntries.map { entry in
            guard
                let image = SlideImageLoader.shared.image(for: entry),
                image.size.height > 0
            else {
                return 1.25
            }
            let ratio = image.size.width / image.size.height
            return max(min(ratio, 3.0), 0.45)
        }
    }

    private var imageScaleFactors: [CGFloat] {
        imageEntries.map { min(max($0.scaleFactor, 0.05), 3.0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let cardHeight = max(proxy.size.height * 0.92, 140)
            let scales = imageScaleFactors
            let itemHeights = scales.map { max(cardHeight * $0, 24) }
            let itemWidths = zip(imageAspectRatios, itemHeights).map { ratio, height in
                let unclampedWidth = height * ratio
                return min(max(unclampedWidth, 24), max(proxy.size.width * 0.72, 280))
            }
            let rowWidth = max(
                itemWidths.reduce(0, +) + spacing * CGFloat(max(itemWidths.count - 1, 0)),
                1
            )
            let repeatCount = max(2, Int(ceil(proxy.size.width / rowWidth)) + 3)

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let travel = currentTravel(at: context.date)
                let offset = travel.truncatingRemainder(dividingBy: rowWidth)

                HStack(spacing: 0) {
                    ForEach(0..<repeatCount, id: \.self) { _ in
                        marqueeRow(itemWidths: itemWidths, itemHeights: itemHeights)
                    }
                }
                .offset(x: -offset)
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            restoreProgress()
        }
        .onDisappear {
            persistProgress()
        }
    }

    private func marqueeRow(itemWidths: [CGFloat], itemHeights: [CGFloat]) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(imageEntries.enumerated()), id: \.offset) { index, entry in
                marqueeCard(entry: entry, width: itemWidths[index], height: itemHeights[index])
            }
        }
        .padding(.trailing, spacing)
    }

    private func marqueeCard(entry: SlideImagePathEntry, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let image = SlideImageLoader.shared.image(for: entry) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "photo")
                        .font(.system(size: 40, weight: .regular))
                    Text(entry.displayName)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                }
                .foregroundStyle(.white.opacity(0.74))
            }
        }
        .frame(width: width, height: height, alignment: .center)
    }

    private func currentTravel(at date: Date) -> CGFloat {
        guard speed != 0 else {
            return baseTravel
        }
        let elapsed = CGFloat(date.timeIntervalSince(animationStartDate))
        return baseTravel + (elapsed * speed)
    }

    private func restoreProgress() {
        baseTravel = PresenterImageMarqueeProgressStore.shared.travel(for: slideID)
        animationStartDate = Date()
    }

    private func persistProgress() {
        let travel = currentTravel(at: Date())
        PresenterImageMarqueeProgressStore.shared.setTravel(travel, for: slideID)
    }
}

@MainActor
private final class PresenterImageMarqueeProgressStore {
    static let shared = PresenterImageMarqueeProgressStore()

    private var travelBySlideID: [Int: CGFloat] = [:]

    private init() {}

    func travel(for slideID: Int) -> CGFloat {
        travelBySlideID[slideID] ?? 0
    }

    func setTravel(_ travel: CGFloat, for slideID: Int) {
        travelBySlideID[slideID] = travel
    }
}
