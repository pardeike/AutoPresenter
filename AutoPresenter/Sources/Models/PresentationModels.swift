import Foundation

struct PresentationDeck: Sendable {
    let presentationTitle: String
    let subtitle: String?
    let author: String?
    let language: String?
    let slides: [PresentationSlide]

    var slideIndices: Set<Int> {
        Set(slides.map(\.index))
    }

    var firstSlideIndex: Int {
        slides.map(\.index).min() ?? 1
    }

    var lastSlideIndex: Int {
        slides.map(\.index).max() ?? 1
    }

    func slide(at index: Int) -> PresentationSlide? {
        slides.first { $0.index == index }
    }

    func clampedSlideIndex(_ requestedIndex: Int) -> Int {
        guard !slides.isEmpty else { return requestedIndex }
        return min(max(requestedIndex, firstSlideIndex), lastSlideIndex)
    }

    func instructionBlock(currentSlideIndex: Int) -> String {
        let sortedSlides = slides.sorted { $0.index < $1.index }
        let current = slide(at: currentSlideIndex)
        let previous = slide(at: currentSlideIndex - 1)
        let next = slide(at: currentSlideIndex + 1)

        let outline = sortedSlides.prefix(40).map { slide in
            "\(slide.index). \(slide.promptSummary)"
        }.joined(separator: "\n")

        var parts: [String] = [
            "You are SlidePilot, a realtime slide command assistant for a live presentation.",
            "Always call the function emit_slide_command exactly once per detected speaker turn.",
            "Allowed actions: next, previous, goto, stay.",
            "Use stay when uncertain. Set confidence in [0,1].",
            "If the presenter lands a thought by restating a quote or rhetorical question, prefer next over stay.",
            "Use stay mainly when the presenter is clearly still elaborating the current slide.",
            "Never hallucinate slide indices.",
            "Keep rationale short and actionable (max 18 words).",
            "Keep utterance_excerpt brief (max 20 words), or null when not needed.",
            "Presentation title: \(presentationTitle)",
            "Current slide index: \(currentSlideIndex)",
            "Deck outline:",
            outline
        ]

        if let subtitle, !subtitle.isEmpty {
            parts.append("Deck subtitle: \(subtitle)")
        }

        if let author, !author.isEmpty {
            parts.append("Deck author: \(author)")
        }

        if let current {
            parts.append("Current slide details: \(current.promptDetails)")
            if !current.speakerNotes.isEmpty {
                parts.append("Speaker notes: \(current.speakerNotes)")
            }
        }

        if let previous {
            parts.append("Previous slide: [\(previous.index)] \(previous.promptSummary)")
        }

        if let next {
            parts.append("Next slide: [\(next.index)] \(next.promptSummary)")
        }

        return parts.joined(separator: "\n")
    }
}

enum SlideLayout: String, Sendable {
    case title
    case image
    case bullets
    case quote
    case twoColumn
    case unknown
}

struct SlideColumn: Sendable {
    let title: String
    let bullets: [String]
}

struct PresentationSlide: Identifiable, Sendable {
    let index: Int
    let layout: SlideLayout
    let title: String
    let subtitle: String
    let bullets: [String]
    let speakerNotes: String
    let keywords: [String]
    let quote: String?
    let attribution: String?
    let imagePlaceholder: String?
    let caption: String?
    let leftColumn: SlideColumn?
    let rightColumn: SlideColumn?

    var id: Int { index }

    var promptSummary: String {
        let titlePart = title.isEmpty ? "(untitled)" : title
        switch layout {
        case .quote:
            let quotePart = quote ?? ""
            return "\(titlePart) [quote] \(quotePart)"
        case .twoColumn:
            return "\(titlePart) [two-column]"
        case .image:
            return "\(titlePart) [image]"
        case .title:
            return subtitle.isEmpty ? titlePart : "\(titlePart) — \(subtitle)"
        case .bullets, .unknown:
            return "\(titlePart) [\(bullets.count) bullets]"
        }
    }

    var promptDetails: String {
        var chunks: [String] = []
        if !title.isEmpty {
            chunks.append("title=\(title)")
        }
        if !subtitle.isEmpty {
            chunks.append("subtitle=\(subtitle)")
        }
        if !bullets.isEmpty {
            chunks.append("bullets=\(bullets.joined(separator: " | "))")
        }
        if let quote, !quote.isEmpty {
            chunks.append("quote=\(quote)")
        }
        if let imagePlaceholder, !imagePlaceholder.isEmpty {
            chunks.append("image=\(imagePlaceholder)")
        }
        if let leftColumn {
            chunks.append("left=\(leftColumn.title): \(leftColumn.bullets.joined(separator: " | "))")
        }
        if let rightColumn {
            chunks.append("right=\(rightColumn.title): \(rightColumn.bullets.joined(separator: " | "))")
        }
        return chunks.joined(separator: "; ")
    }
}

enum DeckLoadError: Error, LocalizedError {
    case emptyData
    case noSlides
    case unsupportedSchema

    var errorDescription: String? {
        switch self {
        case .emptyData:
            return "Deck JSON was empty."
        case .noSlides:
            return "Deck JSON did not include any slides."
        case .unsupportedSchema:
            return "Deck JSON format not recognized."
        }
    }
}

enum PresentationDeckLoader {
    static func load(from url: URL) throws -> PresentationDeck {
        let data = try Data(contentsOf: url)
        return try load(from: data)
    }

    static func load(from data: Data) throws -> PresentationDeck {
        guard !data.isEmpty else {
            throw DeckLoadError.emptyData
        }

        let decoder = JSONDecoder()

        if let simple = try? decoder.decode(SimpleDeckFile.self, from: data) {
            let deck = simple.toDeck()
            guard !deck.slides.isEmpty else {
                throw DeckLoadError.noSlides
            }
            return deck
        }

        if let rich = try? decoder.decode(RichDeckFile.self, from: data) {
            let deck = rich.toDeck()
            guard !deck.slides.isEmpty else {
                throw DeckLoadError.noSlides
            }
            return deck
        }

        throw DeckLoadError.unsupportedSchema
    }
}

private struct SimpleDeckFile: Decodable {
    let presentationTitle: String
    let language: String?
    let slides: [SimpleSlideFile]

    enum CodingKeys: String, CodingKey {
        case presentationTitle = "presentation_title"
        case language
        case slides
    }

    func toDeck() -> PresentationDeck {
        let mappedSlides = slides
            .sorted { $0.index < $1.index }
            .map { $0.toSlide() }

        return PresentationDeck(
            presentationTitle: presentationTitle,
            subtitle: nil,
            author: nil,
            language: language,
            slides: mappedSlides
        )
    }
}

private struct SimpleSlideFile: Decodable {
    let index: Int
    let title: String
    let bullets: [String]?
    let notes: String?
    let keywords: [String]?

    func toSlide() -> PresentationSlide {
        PresentationSlide(
            index: index,
            layout: .bullets,
            title: title,
            subtitle: "",
            bullets: bullets ?? [],
            speakerNotes: notes ?? "",
            keywords: keywords ?? [],
            quote: nil,
            attribution: nil,
            imagePlaceholder: nil,
            caption: nil,
            leftColumn: nil,
            rightColumn: nil
        )
    }
}

private struct RichDeckFile: Decodable {
    let deckTitle: String
    let subtitle: String?
    let author: String?
    let slides: [RichSlideFile]

    func toDeck() -> PresentationDeck {
        let mappedSlides = slides.enumerated().map { offset, slide in
            slide.toSlide(index: offset + 1)
        }

        return PresentationDeck(
            presentationTitle: deckTitle,
            subtitle: subtitle,
            author: author,
            language: nil,
            slides: mappedSlides
        )
    }
}

private struct RichSlideFile: Decodable {
    let layout: String?
    let title: String?
    let subtitle: String?
    let bullets: [String]?
    let speakerNotes: String?
    let quote: String?
    let attribution: String?
    let imagePlaceholder: String?
    let caption: String?
    let left: RichSlideColumnFile?
    let right: RichSlideColumnFile?

    func toSlide(index: Int) -> PresentationSlide {
        let resolvedLayout = SlideLayout(rawValue: layout ?? "") ?? .unknown
        let leftColumn = left?.toColumn()
        let rightColumn = right?.toColumn()

        var mergedBullets = bullets ?? []
        if resolvedLayout == .twoColumn {
            if let leftColumn {
                mergedBullets.append(contentsOf: leftColumn.bullets.map { "\(leftColumn.title): \($0)" })
            }
            if let rightColumn {
                mergedBullets.append(contentsOf: rightColumn.bullets.map { "\(rightColumn.title): \($0)" })
            }
        }

        let normalizedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = normalizedTitle.isEmpty ? "Slide \(index)" : normalizedTitle

        return PresentationSlide(
            index: index,
            layout: resolvedLayout,
            title: finalTitle,
            subtitle: subtitle ?? "",
            bullets: mergedBullets,
            speakerNotes: speakerNotes ?? "",
            keywords: Self.deriveKeywords(from: finalTitle, bullets: mergedBullets),
            quote: quote,
            attribution: attribution,
            imagePlaceholder: imagePlaceholder,
            caption: caption,
            leftColumn: leftColumn,
            rightColumn: rightColumn
        )
    }

    private static func deriveKeywords(from title: String, bullets: [String]) -> [String] {
        let source = ([title] + bullets.prefix(2)).joined(separator: " ")
        let separators = CharacterSet.alphanumerics.inverted
        let tokens = source
            .lowercased()
            .components(separatedBy: separators)
            .filter { $0.count >= 4 }
        return Array(Set(tokens)).sorted().prefix(8).map { String($0) }
    }
}

private struct RichSlideColumnFile: Decodable {
    let title: String?
    let bullets: [String]?

    func toColumn() -> SlideColumn {
        SlideColumn(
            title: title ?? "Column",
            bullets: bullets ?? []
        )
    }
}
