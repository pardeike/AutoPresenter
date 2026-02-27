import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    @StateObject private var presenterBridge: AppPresenterWindowBridge
    @State private var presenterWindowManager = PresenterWindowManager()
    @State private var presentationEditorWindowManager = PresentationEditorWindowManager()

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
            presentationEditorWindowManager.close()
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
        .onReceive(NotificationCenter.default.publisher(for: AppCommandRelay.openEditorRequestNotification)) { _ in
            guard viewModel.deck != nil else {
                return
            }
            presentationEditorWindowManager.show(
                viewModel: viewModel,
                initialSlideIndex: viewModel.currentSlideIndex
            )
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
    private let headerMinHeight: CGFloat = 128

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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !segmentBuckets.title.isEmpty {
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
            }
            .frame(minHeight: headerMinHeight, alignment: .topLeading)

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
                    bulletSegments: segmentBuckets.leftBullets
                )
                slideColumn(
                    titleSegments: segmentBuckets.rightTitle,
                    bulletSegments: segmentBuckets.rightBullets
                )
                    .padding(.trailing, 10)
            }
        case .title, .bullets, .unknown:
            if !segmentBuckets.bodyBullets.isEmpty {
                ForEach(segmentBuckets.bodyBullets, id: \.index) { segment in
                    bulletSegmentRow(segment)
                }
            }
        }
    }

    @ViewBuilder
    private func slideColumn(
        titleSegments: [SlideMarkSegment],
        bulletSegments: [SlideMarkSegment]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !titleSegments.isEmpty {
                ForEach(titleSegments, id: \.index) { segment in
                    segmentTextRow(segment, font: .title3.weight(.semibold))
                }
            }

            if bulletSegments.isEmpty {
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

@MainActor
final class PresentationEditorWindowManager: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(viewModel: AppViewModel, initialSlideIndex: Int?) {
        if let window {
            if let hostingController = window.contentViewController as? NSHostingController<PresentationEditorRootView> {
                hostingController.rootView = PresentationEditorRootView(
                    viewModel: viewModel,
                    initialSlideIndex: initialSlideIndex
                )
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let editorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        editorWindow.title = "Edit Presentation"
        editorWindow.minSize = NSSize(width: 980, height: 620)
        editorWindow.isReleasedWhenClosed = false
        editorWindow.delegate = self
        editorWindow.center()

        let hostingController = NSHostingController(
            rootView: PresentationEditorRootView(
                viewModel: viewModel,
                initialSlideIndex: initialSlideIndex
            )
        )
        editorWindow.contentViewController = hostingController
        self.window = editorWindow
        editorWindow.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct PresentationEditorRootView: View {
    @ObservedObject var viewModel: AppViewModel
    private let initialSlideIndex: Int?

    @State private var selectedSlideIndex: Int?
    @State private var draft = EditableSlideDraft.empty
    @State private var loadedDraftSlideIndex: Int?

    init(viewModel: AppViewModel, initialSlideIndex: Int?) {
        self.viewModel = viewModel
        self.initialSlideIndex = initialSlideIndex
        _selectedSlideIndex = State(initialValue: initialSlideIndex)
    }

    private var slides: [PresentationSlide] {
        viewModel.editableSlides
    }

    private var selectedSlide: PresentationSlide? {
        guard let selectedSlideIndex else {
            return nil
        }
        return slides.first { $0.index == selectedSlideIndex }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedSlideIndex) {
                    ForEach(slides, id: \.index) { slide in
                        HStack(alignment: .center, spacing: 10) {
                            SlideTypeBadgeView(layout: slide.layout)
                            Text(slideListRowLabel(for: slide))
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                        .tag(Optional(slide.index))
                    }
                    .onMove(perform: moveSlides)
                    .onDelete(perform: deleteSlides(atOffsets:))
                }

                Divider()

                HStack {
                    Button("Add") {
                        addSlide()
                    }
                    Spacer()
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            if selectedSlide != nil {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Spacer()
                        Picker("", selection: $draft.layout) {
                            ForEach(EditableSlideLayout.allCases) { layout in
                                Text(layout.displayName)
                                    .tag(layout)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 520)
                        Spacer()
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            LineTextEditor(
                                title: "Title",
                                caption: "One line per title paragraph",
                                text: $draft.titleText,
                                minHeight: 56,
                                maxHeight: 56
                            )
                            if draft.layout != .image {
                                LineTextEditor(
                                    title: "Subtitle",
                                    caption: "One line per subtitle paragraph",
                                    text: $draft.subtitleText,
                                    minHeight: 56,
                                    maxHeight: 56
                                )
                            }

                            switch draft.layout {
                            case .title:
                                EmptyView()
                            case .bullets:
                                LineTextEditor(
                                    title: "Bullets",
                                    caption: "One line per bullet",
                                    text: $draft.bulletsText,
                                    minHeight: 140
                                )
                            case .quote:
                                LineTextEditor(
                                    title: "Quote",
                                    caption: "One line per quote paragraph",
                                    text: $draft.quoteText,
                                    minHeight: 120
                                )
                            case .image:
                                LineTextEditor(
                                    title: "Image Placeholder",
                                    caption: "One line per image placeholder paragraph",
                                    text: $draft.imageText,
                                    minHeight: 100
                                )
                                LineTextEditor(
                                    title: "Caption",
                                    caption: "One line per caption paragraph",
                                    text: $draft.captionText,
                                    minHeight: 100
                                )
                            case .twoColumn:
                                LineTextEditor(
                                    title: "Left Column Title",
                                    caption: "One line per left title paragraph",
                                    text: $draft.leftTitleText,
                                    minHeight: 56,
                                    maxHeight: 56
                                )
                                LineTextEditor(
                                    title: "Left Column Bullets",
                                    caption: "One line per left bullet",
                                    text: $draft.leftBulletsText,
                                    minHeight: 120
                                )
                                LineTextEditor(
                                    title: "Right Column Title",
                                    caption: "One line per right title paragraph",
                                    text: $draft.rightTitleText,
                                    minHeight: 56,
                                    maxHeight: 56
                                )
                                LineTextEditor(
                                    title: "Right Column Bullets",
                                    caption: "One line per right bullet",
                                    text: $draft.rightBulletsText,
                                    minHeight: 120
                                )
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Save") {
                            saveDraft()
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedSlideIndex == nil)
                    }
                }
                .padding(16)
            } else {
                VStack(spacing: 12) {
                    Text("No Slide Selected")
                        .font(.title3.weight(.semibold))
                    Text("Choose a slide on the left or add a new one.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            synchronizeSelectionWithSlides()
        }
        .onChange(of: slides.map(\.index)) { _, _ in
            synchronizeSelectionWithSlides()
        }
        .onChange(of: selectedSlideIndex) { _, _ in
            loadDraftForSelectedSlide(force: true)
        }
        .onDeleteCommand {
            deleteSelectedSlide()
        }
    }

    private func synchronizeSelectionWithSlides() {
        let availableIndices = Set(slides.map(\.index))
        if let selectedSlideIndex, !availableIndices.contains(selectedSlideIndex) {
            self.selectedSlideIndex = slides.first?.index
        }
        if self.selectedSlideIndex == nil {
            if let initialSlideIndex, availableIndices.contains(initialSlideIndex) {
                self.selectedSlideIndex = initialSlideIndex
            } else {
                self.selectedSlideIndex = slides.first?.index
            }
        }
        loadDraftForSelectedSlide()
    }

    private func loadDraftForSelectedSlide(force: Bool = false) {
        guard let selectedSlideIndex else {
            draft = .empty
            loadedDraftSlideIndex = nil
            return
        }
        guard let selectedSlide = slides.first(where: { $0.index == selectedSlideIndex }) else {
            draft = .empty
            loadedDraftSlideIndex = nil
            return
        }
        guard force || loadedDraftSlideIndex != selectedSlideIndex else {
            return
        }
        draft = EditableSlideDraft(slide: selectedSlide)
        loadedDraftSlideIndex = selectedSlideIndex
    }

    private func addSlide() {
        if let newIndex = viewModel.insertNewSlide(afterSlideIndex: selectedSlideIndex) {
            selectedSlideIndex = newIndex
            loadDraftForSelectedSlide(force: true)
        }
    }

    private func deleteSelectedSlide() {
        guard let selectedSlideIndex else {
            return
        }
        if let nextSelection = viewModel.deleteSlides(withIndices: [selectedSlideIndex]) {
            self.selectedSlideIndex = nextSelection
            loadDraftForSelectedSlide(force: true)
        }
    }

    private func deleteSlides(atOffsets offsets: IndexSet) {
        let indicesToDelete: Set<Int> = Set(offsets.compactMap { offset in
            guard slides.indices.contains(offset) else { return nil }
            return slides[offset].index
        })
        guard !indicesToDelete.isEmpty else {
            return
        }
        if let nextSelection = viewModel.deleteSlides(withIndices: indicesToDelete) {
            selectedSlideIndex = nextSelection
            loadDraftForSelectedSlide(force: true)
        }
    }

    private func moveSlides(from source: IndexSet, to destination: Int) {
        let oldSelection = selectedSlideIndex
        let reorderedOldIndices = viewModel.moveSlides(fromOffsets: source, toOffset: destination)
        if let oldSelection,
           let newPosition = reorderedOldIndices.firstIndex(of: oldSelection) {
            selectedSlideIndex = newPosition + 1
        }
        loadDraftForSelectedSlide(force: true)
    }

    private func saveDraft() {
        guard let selectedSlideIndex else {
            return
        }
        let updatedSlide = draft.buildSlide(index: selectedSlideIndex)
        viewModel.updateSlide(updatedSlide, atIndex: selectedSlideIndex)
        loadDraftForSelectedSlide(force: true)
    }

    private func slideListRowLabel(for slide: PresentationSlide) -> String {
        let title = slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = slide.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if subtitle.isEmpty {
            return title
        }
        if title.isEmpty {
            return subtitle
        }
        return "\(title) — \(subtitle)"
    }
}

private struct SlideTypeBadgeView: View {
    let layout: SlideLayout

    var body: some View {
        iconContent
            .frame(width: 36, height: 36)
    }

    @ViewBuilder
    private var iconContent: some View {
        switch layout {
        case .title:
            ZStack {
                Circle()
                    .fill(.white)
                Text("T")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: 24, height: 24)
        case .bullets, .unknown:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(.white)
                            .frame(width: 4, height: 4)
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(.white)
                            .frame(width: 14, height: 2)
                    }
                }
            }
        case .quote:
            ZStack {
                Circle()
                    .fill(.white)
                Text("“”")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: 24, height: 24)
        case .image:
            Image(systemName: "photo")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        case .twoColumn:
            HStack(spacing: 4) {
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(.white)
                            .frame(width: 7, height: 2)
                    }
                }
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(.white)
                            .frame(width: 7, height: 2)
                    }
                }
            }
        }
    }
}

private enum EditableSlideLayout: String, CaseIterable, Identifiable {
    case title
    case bullets
    case quote
    case image
    case twoColumn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title:
            return "Title"
        case .bullets:
            return "Bullets"
        case .quote:
            return "Quote"
        case .image:
            return "Image"
        case .twoColumn:
            return "Two Column"
        }
    }

    init(slideLayout: SlideLayout) {
        switch slideLayout {
        case .title:
            self = .title
        case .bullets:
            self = .bullets
        case .quote:
            self = .quote
        case .image:
            self = .image
        case .twoColumn:
            self = .twoColumn
        case .unknown:
            self = .bullets
        }
    }

    var slideLayout: SlideLayout {
        switch self {
        case .title:
            return .title
        case .bullets:
            return .bullets
        case .quote:
            return .quote
        case .image:
            return .image
        case .twoColumn:
            return .twoColumn
        }
    }
}

private struct EditableSlideDraft {
    var layout: EditableSlideLayout
    var titleText: String
    var subtitleText: String
    var bulletsText: String
    var quoteText: String
    var imageText: String
    var captionText: String
    var leftTitleText: String
    var leftBulletsText: String
    var rightTitleText: String
    var rightBulletsText: String

    init(
        layout: EditableSlideLayout,
        titleText: String,
        subtitleText: String,
        bulletsText: String,
        quoteText: String,
        imageText: String,
        captionText: String,
        leftTitleText: String,
        leftBulletsText: String,
        rightTitleText: String,
        rightBulletsText: String
    ) {
        self.layout = layout
        self.titleText = titleText
        self.subtitleText = subtitleText
        self.bulletsText = bulletsText
        self.quoteText = quoteText
        self.imageText = imageText
        self.captionText = captionText
        self.leftTitleText = leftTitleText
        self.leftBulletsText = leftBulletsText
        self.rightTitleText = rightTitleText
        self.rightBulletsText = rightBulletsText
    }

    static let empty = EditableSlideDraft(
        layout: .bullets,
        titleText: "",
        subtitleText: "",
        bulletsText: "",
        quoteText: "",
        imageText: "",
        captionText: "",
        leftTitleText: "",
        leftBulletsText: "",
        rightTitleText: "",
        rightBulletsText: ""
    )

    init(slide: PresentationSlide) {
        layout = EditableSlideLayout(slideLayout: slide.layout)
        titleText = slide.titleParagraphs.joined(separator: "\n")
        subtitleText = slide.layout == .image ? "" : slide.subtitleParagraphs.joined(separator: "\n")
        bulletsText = slide.bullets.joined(separator: "\n")
        quoteText = slide.quoteParagraphs.joined(separator: "\n")
        imageText = slide.imagePlaceholderParagraphs.joined(separator: "\n")
        captionText = slide.captionParagraphs.joined(separator: "\n")
        leftTitleText = slide.leftColumn?.titleParagraphs.joined(separator: "\n") ?? ""
        leftBulletsText = slide.leftColumn?.bullets.joined(separator: "\n") ?? ""
        rightTitleText = slide.rightColumn?.titleParagraphs.joined(separator: "\n") ?? ""
        rightBulletsText = slide.rightColumn?.bullets.joined(separator: "\n") ?? ""
    }

    func buildSlide(index: Int) -> PresentationSlide {
        let titleParagraphs = lines(from: titleText)
        let subtitleParagraphs = lines(from: subtitleText)
        let resolvedSubtitleParagraphs = layout == .image ? [] : subtitleParagraphs
        let bulletLines = lines(from: bulletsText)
        let quoteParagraphs = lines(from: quoteText)
        let imageParagraphs = lines(from: imageText)
        let captionParagraphs = lines(from: captionText)
        let leftTitleParagraphs = lines(from: leftTitleText)
        let leftBulletLines = lines(from: leftBulletsText)
        let rightTitleParagraphs = lines(from: rightTitleText)
        let rightBulletLines = lines(from: rightBulletsText)

        let leftColumn: SlideColumn? = {
            guard !leftTitleParagraphs.isEmpty || !leftBulletLines.isEmpty else {
                return nil
            }
            return SlideColumn(
                title: leftTitleParagraphs.joined(separator: " "),
                titleParagraphs: leftTitleParagraphs,
                bullets: leftBulletLines
            )
        }()

        let rightColumn: SlideColumn? = {
            guard !rightTitleParagraphs.isEmpty || !rightBulletLines.isEmpty else {
                return nil
            }
            return SlideColumn(
                title: rightTitleParagraphs.joined(separator: " "),
                titleParagraphs: rightTitleParagraphs,
                bullets: rightBulletLines
            )
        }()

        let bullets: [String]
        switch layout {
        case .bullets:
            bullets = bulletLines
        case .twoColumn:
            var merged: [String] = []
            if let leftColumn {
                let leftPrefix = leftColumn.title.nilIfBlank
                merged.append(contentsOf: leftColumn.bullets.map { bullet in
                    guard let leftPrefix else { return bullet }
                    return "\(leftPrefix): \(bullet)"
                })
            }
            if let rightColumn {
                let rightPrefix = rightColumn.title.nilIfBlank
                merged.append(contentsOf: rightColumn.bullets.map { bullet in
                    guard let rightPrefix else { return bullet }
                    return "\(rightPrefix): \(bullet)"
                })
            }
            bullets = merged
        case .title, .quote, .image:
            bullets = []
        }

        return PresentationSlide(
            index: index,
            layout: layout.slideLayout,
            title: titleParagraphs.joined(separator: " "),
            titleParagraphs: titleParagraphs,
            subtitle: resolvedSubtitleParagraphs.joined(separator: " "),
            subtitleParagraphs: resolvedSubtitleParagraphs,
            bullets: bullets,
            quote: quoteParagraphs.joined(separator: " ").nilIfBlank,
            quoteParagraphs: quoteParagraphs,
            imagePlaceholder: imageParagraphs.joined(separator: " ").nilIfBlank,
            imagePlaceholderParagraphs: imageParagraphs,
            caption: captionParagraphs.joined(separator: " ").nilIfBlank,
            captionParagraphs: captionParagraphs,
            leftColumn: leftColumn,
            rightColumn: rightColumn
        )
    }

    private func lines(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct LineTextEditor: View {
    let title: String
    let caption: String
    @Binding var text: String
    var minHeight: CGFloat
    var maxHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .padding(6)
                .background(.black.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.black.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
