import AppKit
import SwiftUI

@main
struct AutoPresenterApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var viewModel: AppViewModel
    @StateObject private var commandState = AppCommandState()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appLifecycleDelegate

    init() {
        let appSettings = AppSettings()
        _settings = StateObject(wrappedValue: appSettings)
        _viewModel = StateObject(wrappedValue: AppViewModel(settings: appSettings, bootstrapExampleDeck: false))

        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        AppLifecycleDelegate.clearSavedApplicationStateIfPresent()
        Task { @MainActor in
            MainWindowFramePersistence.shared.startIfNeeded()
            AppMenuPruner.shared.startIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindowContent(viewModel: viewModel)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    AppCommandRelay.requestOpenDeck()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button(commandState.isPresentationVisible ? "Hide Presentation" : "Show Presentation") {
                    AppCommandRelay.requestTogglePresentation()
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(viewModel.deck == nil && !commandState.isPresentationVisible)

                Button(viewModel.isRecordingControlActive ? "Stop Recording" : "Start Recording") {
                    AppCommandRelay.requestToggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!viewModel.canToggleSession || (viewModel.deck == nil && !viewModel.isRecordingControlActive))
                Divider()
            }
        }

        Settings {
            SafetyGateSettingsView(settings: settings)
        }
    }
}

enum AppCommandRelay {
    static let openDeckRequestNotification = Notification.Name("AutoPresenter.OpenDeckRequest")
    static let togglePresentationRequestNotification = Notification.Name("AutoPresenter.TogglePresentationRequest")
    static let toggleRecordingRequestNotification = Notification.Name("AutoPresenter.ToggleRecordingRequest")
    static let presentationVisibilityDidChangeNotification = Notification.Name("AutoPresenter.PresentationVisibilityDidChange")

    static func requestOpenDeck() {
        NotificationCenter.default.post(name: openDeckRequestNotification, object: nil)
    }

    static func requestTogglePresentation() {
        NotificationCenter.default.post(name: togglePresentationRequestNotification, object: nil)
    }

    static func requestToggleRecording() {
        NotificationCenter.default.post(name: toggleRecordingRequestNotification, object: nil)
    }

    static func publishPresentationVisibility(_ isVisible: Bool) {
        NotificationCenter.default.post(
            name: presentationVisibilityDidChangeNotification,
            object: NSNumber(value: isVisible)
        )
    }
}

@MainActor
private final class AppCommandState: ObservableObject {
    @Published var isPresentationVisible = false

    init() {
        _ = NotificationCenter.default.addObserver(
            forName: AppCommandRelay.presentationVisibilityDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let value = notification.object as? NSNumber else {
                return
            }
            Task { @MainActor [weak self] in
                self?.isPresentationVisible = value.boolValue
            }
        }
    }
}

private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.clearSavedApplicationStateIfPresent()
    }

    static func clearSavedApplicationStateIfPresent() {
        let savedStateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Saved Application State")
            .appendingPathComponent("com.ap.autopresenter.savedState", isDirectory: true)
        try? FileManager.default.removeItem(at: savedStateDirectory)
    }
}

private struct MainWindowContent: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var hasAttemptedStartupRestore = false

    var body: some View {
        ContentView(viewModel: viewModel)
            .onAppear {
                if let activeWindow = NSApp.mainWindow ?? NSApp.keyWindow,
                   shouldManageMainWindow(activeWindow) {
                    MainWindowFramePersistence.shared.attach(window: activeWindow)
                }
                Task { @MainActor in
                    AppMenuPruner.shared.pruneNow()
                }
                guard !hasAttemptedStartupRestore else {
                    return
                }
                hasAttemptedStartupRestore = true
                if viewModel.restoreLastOpenedDeckIfAvailable() {
                    viewModel.debugLog("Startup load path: restored last deck")
                } else {
                    viewModel.debugLog("Startup load path: no last deck to restore")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { notification in
                guard let window = notification.object as? NSWindow else {
                    return
                }
                guard shouldManageMainWindow(window) else {
                    return
                }
                MainWindowFramePersistence.shared.attach(window: window)
            }
            .onReceive(NotificationCenter.default.publisher(for: AppCommandRelay.openDeckRequestNotification)) { _ in
                viewModel.chooseDeckFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: AppCommandRelay.toggleRecordingRequestNotification)) { _ in
                viewModel.toggleRealtimeSession()
            }
            .onOpenURL { url in
                guard url.isFileURL else {
                    return
                }
                viewModel.loadDeckFromURL(url)
            }
    }

    private func shouldManageMainWindow(_ window: NSWindow) -> Bool {
        !(window.delegate is PresenterWindowManager)
    }
}

@MainActor
private final class MainWindowFramePersistence: ObservableObject {
    static let shared = MainWindowFramePersistence()

    private var hasStarted = false
    private var observedWindowNumbers: Set<Int> = []
    private var observersByWindowNumber: [Int: [NSObjectProtocol]] = [:]
    private var globalObserverTokens: [NSObjectProtocol] = []
    private let frameDefaultsKey = "AutoPresenter.MainWindow.FrameString"

    private init() {}

    func startIfNeeded() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        installGlobalObservers()
        attachExistingWindows()
    }

    func attach(window: NSWindow) {
        guard shouldManage(window) else {
            return
        }
        let windowNumber = window.windowNumber
        guard !observedWindowNumbers.contains(windowNumber) else {
            return
        }
        observedWindowNumbers.insert(windowNumber)

        restoreFrameIfAvailable(on: window)
        persistFrame(of: window)
        installObservers(for: window, windowNumber: windowNumber)
    }

    private func restoreFrameIfAvailable(on window: NSWindow) {
        guard let frameString = UserDefaults.standard.string(forKey: frameDefaultsKey) else {
            return
        }
        let restoredFrame = NSRectFromString(frameString)
        guard restoredFrame.size.width > 64, restoredFrame.size.height > 64 else {
            return
        }
        window.setFrame(restoredFrame, display: true, animate: false)
        reapplyRestoredOrigin(restoredFrame.origin, on: window, delay: 0)
        reapplyRestoredOrigin(restoredFrame.origin, on: window, delay: 0.25)
    }

    private func persistFrame(of window: NSWindow) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameDefaultsKey)
    }

    private func installObservers(for window: NSWindow, windowNumber: Int) {
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

        let closeToken = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: windowObject,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self else { return }
                if let window {
                    self.persistFrame(of: window)
                }
                self.removeObservers(for: windowNumber)
                self.observedWindowNumbers.remove(windowNumber)
            }
        }

        observersByWindowNumber[windowNumber] = [moveToken, resizeToken, closeToken]
    }

    private func installGlobalObservers() {
        let notificationCenter = NotificationCenter.default

        let becameMainToken = notificationCenter.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.attach(window: window)
            }
        }

        let becameKeyToken = notificationCenter.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.attach(window: window)
            }
        }

        globalObserverTokens.append(becameMainToken)
        globalObserverTokens.append(becameKeyToken)
    }

    private func attachExistingWindows() {
        for window in NSApp.windows {
            attach(window: window)
        }
    }

    private func shouldManage(_ window: NSWindow) -> Bool {
        !(window.delegate is PresenterWindowManager)
    }

    private func reapplyRestoredOrigin(_ origin: NSPoint, on window: NSWindow, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
            guard let window else {
                return
            }
            window.setFrameOrigin(origin)
        }
    }

    private func removeObservers(for windowNumber: Int) {
        guard let tokens = observersByWindowNumber.removeValue(forKey: windowNumber) else {
            return
        }
        let notificationCenter = NotificationCenter.default
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }
}

@MainActor
private final class AppMenuPruner {
    static let shared = AppMenuPruner()

    private var hasStarted = false
    private var observationTokens: [NSObjectProtocol] = []

    private init() {}

    func startIfNeeded() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        NSWindow.allowsAutomaticWindowTabbing = false
        installObservers()
        scheduleInitialPrunePasses()
    }

    func pruneNow() {
        pruneTargetMenuItems()
    }

    private func installObservers() {
        let notificationCenter = NotificationCenter.default
        let menuOpenToken = notificationCenter.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pruneTargetMenuItems()
            }
        }
        let appActiveToken = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pruneTargetMenuItems()
            }
        }
        let menuDidAddItemToken = notificationCenter.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pruneTargetMenuItems()
            }
        }
        let menuDidChangeItemToken = notificationCenter.addObserver(
            forName: NSMenu.didChangeItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pruneTargetMenuItems()
            }
        }
        observationTokens.append(menuOpenToken)
        observationTokens.append(appActiveToken)
        observationTokens.append(menuDidAddItemToken)
        observationTokens.append(menuDidChangeItemToken)
    }

    private func scheduleInitialPrunePasses() {
        pruneTargetMenuItems()
        DispatchQueue.main.async { [weak self] in
            self?.pruneTargetMenuItems()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pruneTargetMenuItems()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pruneTargetMenuItems()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pruneTargetMenuItems()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.pruneTargetMenuItems()
        }
    }

    private func pruneTargetMenuItems() {
        guard let mainMenu = NSApp.mainMenu else {
            return
        }
        let selectors = Set(Self.targetActionNames.map(NSSelectorFromString))
        prune(menu: mainMenu, targetTitles: Self.targetTitles, targetSelectors: selectors)
        updateFullscreenShortcut(in: mainMenu)
    }

    private func prune(menu: NSMenu, targetTitles: Set<String>, targetSelectors: Set<Selector>) {
        for index in menu.items.indices.reversed() {
            let item = menu.items[index]
            let titleMatches = targetTitles.contains(item.title)
            let actionMatches = item.action.map { targetSelectors.contains($0) } ?? false

            if titleMatches || actionMatches {
                menu.removeItem(at: index)
                continue
            }

            if let submenu = item.submenu {
                prune(menu: submenu, targetTitles: targetTitles, targetSelectors: targetSelectors)
            }
        }
    }

    private func updateFullscreenShortcut(in menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(NSWindow.toggleFullScreen(_:)) {
                item.keyEquivalentModifierMask = [.command]
                item.keyEquivalent = "f"
            }
            if let submenu = item.submenu {
                updateFullscreenShortcut(in: submenu)
            }
        }
    }

    private static let targetTitles: Set<String> = [
        "New",
        "Save",
        "Save…",
        "Save...",
        "Duplicate",
        "Duplicate…",
        "Duplicate...",
        "Show Tab Bar",
        "Show All Tabs",
        "Remove Window from Set",
        "Show Previous Tab",
        "Show Next Tab",
        "Move Tab to New Window",
        "Merge All Windows"
    ]

    private static let targetActionNames: Set<String> = [
        "newDocument:",
        "newDocumentAndDisplay:",
        "saveDocument:",
        "saveDocumentAs:",
        "saveDocumentTo:",
        "save:",
        "duplicateDocument:",
        "duplicate:",
        "toggleTabBar:",
        "showAllTabs:",
        "removeWindowFromSet:",
        "selectPreviousTab:",
        "selectNextTab:",
        "moveTabToNewWindow:",
        "mergeAllWindows:"
    ]
}
