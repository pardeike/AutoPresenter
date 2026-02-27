import SwiftUI
import UniformTypeIdentifiers

@main
struct AutoPresenterApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        DocumentGroup(newDocument: PresentationDeckDocument()) { file in
            DocumentWindowContent(document: file.$document, fileURL: file.fileURL, settings: settings)
                .frame(minWidth: 1100, minHeight: 760)
        }

        Settings {
            SafetyGateSettingsView(settings: settings)
        }
    }
}

private struct DocumentWindowContent: View {
    @Binding var document: PresentationDeckDocument
    let fileURL: URL?

    @StateObject private var viewModel: AppViewModel
    @State private var hasLoadedInitialDocument = false

    init(document: Binding<PresentationDeckDocument>, fileURL: URL?, settings: AppSettings) {
        _document = document
        self.fileURL = fileURL
        _viewModel = StateObject(wrappedValue: AppViewModel(settings: settings, bootstrapExampleDeck: false))
    }

    var body: some View {
        ContentView(viewModel: viewModel)
            .onAppear {
                guard !hasLoadedInitialDocument else { return }
                hasLoadedInitialDocument = true
                if fileURL == nil, viewModel.restoreLastOpenedDeckIfAvailable() {
                    return
                }
                viewModel.loadDeckFromData(document.data, sourceURL: fileURL)
            }
            .onChange(of: document.data) { _, newData in
                if fileURL == nil, viewModel.loadedDeckURL != nil {
                    return
                }
                viewModel.loadDeckFromData(newData, sourceURL: fileURL)
            }
            .onChange(of: fileURL) { _, newURL in
                viewModel.setLoadedDeckURL(newURL)
                guard let newURL else { return }
                viewModel.loadDeckFromData(document.data, sourceURL: newURL)
            }
    }
}

private struct PresentationDeckDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init() {
        data = Self.defaultDocumentData
    }

    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw DeckLoadError.emptyData
        }
        data = fileData
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    private static let defaultDocumentData: Data = {
        let template = """
        {
          "presentation_title": "Untitled Deck",
          "language": "en",
          "slides": [
            {
              "index": 1,
              "title": "New Presentation",
              "bullets": [
                "Open a JSON deck from File > Open.",
                "Use the record control when your deck is loaded."
              ]
            }
          ]
        }
        """
        return Data(template.utf8)
    }()
}
