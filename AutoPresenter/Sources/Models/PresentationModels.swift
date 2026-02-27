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
            "You are SlidePilot, a deterministic realtime slide command assistant.",
            "Always call the function emit_slide_command exactly once per detected speaker turn.",
            "Return only function arguments. No prose outside the tool call.",
            "Allowed actions: next, previous, goto, mark, stay.",
            "Use literal matching. Avoid creative interpretation and avoid paraphrasing.",
            "Use mark for intermediate feedback when speech matches a numbered segment on the current slide.",
            "A mark command is valid only when mark_index is present and references one segment number listed below.",
            "When action is mark, mark_index must be an explicit integer from current slide segments and target_slide must be null.",
            "When action is goto, target_slide must be an explicit integer from the deck and mark_index must be null.",
            "When action is next/previous/stay, target_slide and mark_index must be null.",
            "If you cannot map speech to one segment index, use stay (never emit mark with missing mark_index).",
            "When multiple segment matches are possible, choose the lowest matching segment index.",
            "Use stay only when no specific segment should be marked and no navigation should happen.",
            "Set confidence in [0,1].",
            "If asked for first/start slide, use action=goto with target_slide=Deck first slide index.",
            "If asked for last/final/end slide, use action=goto with target_slide=Deck last slide index.",
            "Set highlight_phrases to 0-5 short exact phrases from the current slide that match the latest speech.",
            "Keep highlight_phrases as exact slide substrings only (no paraphrases); use [] when nothing matches.",
            "Prefer mark over stay whenever a specific segment was just discussed.",
            "Use mark frequently on short pauses while the presenter is still on the same idea.",
            "If the presenter lands a thought by restating a quote or rhetorical question, prefer next over stay.",
            "Never hallucinate indices.",
            "Keep rationale plain and brief (4-10 simple words, factual, no flourish).",
            "Keep utterance_excerpt as an exact quote up to 10 words, or null when not needed.",
            "Presentation title: \(presentationTitle)",
            "Deck first slide index: \(firstSlideIndex)",
            "Deck last slide index: \(lastSlideIndex)",
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
            let segments = current.markableSegments()
            if segments.isEmpty {
                parts.append("Current slide markable segments: <none>")
            } else {
                let segmentLines = segments.prefix(80).map { segment in
                    "\(segment.index). [\(segment.kind)] \(segment.text)"
                }.joined(separator: "\n")
                parts.append("Current slide markable segments:\n\(segmentLines)")
            }
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
    let titleParagraphs: [String]
    let bullets: [String]
}

struct SlideMarkSegment: Sendable {
    let index: Int
    let kind: String
    let text: String
}

struct SlideSegmentBuckets: Sendable {
    let title: [SlideMarkSegment]
    let subtitle: [SlideMarkSegment]
    let bodyBullets: [SlideMarkSegment]
    let quote: [SlideMarkSegment]
    let attribution: [SlideMarkSegment]
    let imagePlaceholder: [SlideMarkSegment]
    let caption: [SlideMarkSegment]
    let leftTitle: [SlideMarkSegment]
    let leftBullets: [SlideMarkSegment]
    let rightTitle: [SlideMarkSegment]
    let rightBullets: [SlideMarkSegment]

    var ordered: [SlideMarkSegment] {
        title
            + subtitle
            + bodyBullets
            + quote
            + attribution
            + imagePlaceholder
            + caption
            + leftTitle
            + leftBullets
            + rightTitle
            + rightBullets
    }
}

struct PresentationSlide: Identifiable, Sendable {
    let index: Int
    let layout: SlideLayout
    let title: String
    let titleParagraphs: [String]
    let subtitle: String
    let subtitleParagraphs: [String]
    let bullets: [String]
    let speakerNotes: String
    let speakerNoteParagraphs: [String]
    let keywords: [String]
    let quote: String?
    let quoteParagraphs: [String]
    let attribution: String?
    let attributionParagraphs: [String]
    let imagePlaceholder: String?
    let imagePlaceholderParagraphs: [String]
    let caption: String?
    let captionParagraphs: [String]
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

    func markableSegments() -> [SlideMarkSegment] {
        segmentBuckets().ordered
    }

    func segmentBuckets() -> SlideSegmentBuckets {
        var nextIndex = 1

        func makeSegments(kind: String, from textParts: [String]) -> [SlideMarkSegment] {
            var segments: [SlideMarkSegment] = []
            for part in textParts.cleanedParagraphs() {
                segments.append(
                    SlideMarkSegment(
                        index: nextIndex,
                        kind: kind,
                        text: part
                    )
                )
                nextIndex += 1
            }
            return segments
        }

        let titleSegments = makeSegments(kind: "title", from: titleParagraphs)
        let subtitleSegments = makeSegments(kind: "subtitle", from: subtitleParagraphs)

        var bodyBulletSegments: [SlideMarkSegment] = []
        var quoteSegments: [SlideMarkSegment] = []
        var attributionSegments: [SlideMarkSegment] = []
        var imageSegments: [SlideMarkSegment] = []
        var captionSegments: [SlideMarkSegment] = []
        var leftTitleSegments: [SlideMarkSegment] = []
        var leftBulletSegments: [SlideMarkSegment] = []
        var rightTitleSegments: [SlideMarkSegment] = []
        var rightBulletSegments: [SlideMarkSegment] = []

        switch layout {
        case .title, .bullets:
            bodyBulletSegments = makeSegments(kind: "bullet", from: bullets)
        case .quote:
            quoteSegments = makeSegments(kind: "quote", from: quoteParagraphs)
            attributionSegments = makeSegments(kind: "attribution", from: attributionParagraphs)
        case .image:
            imageSegments = makeSegments(kind: "image", from: imagePlaceholderParagraphs)
            captionSegments = makeSegments(kind: "caption", from: captionParagraphs)
        case .twoColumn:
            if let leftColumn {
                leftTitleSegments = makeSegments(kind: "left-title", from: leftColumn.titleParagraphs)
                leftBulletSegments = makeSegments(kind: "left-bullet", from: leftColumn.bullets)
            }
            if let rightColumn {
                rightTitleSegments = makeSegments(kind: "right-title", from: rightColumn.titleParagraphs)
                rightBulletSegments = makeSegments(kind: "right-bullet", from: rightColumn.bullets)
            }
        case .unknown:
            bodyBulletSegments = makeSegments(kind: "bullet", from: bullets)
            quoteSegments = makeSegments(kind: "quote", from: quoteParagraphs)
            attributionSegments = makeSegments(kind: "attribution", from: attributionParagraphs)
            imageSegments = makeSegments(kind: "image", from: imagePlaceholderParagraphs)
            captionSegments = makeSegments(kind: "caption", from: captionParagraphs)
            if let leftColumn {
                leftTitleSegments = makeSegments(kind: "left-title", from: leftColumn.titleParagraphs)
                leftBulletSegments = makeSegments(kind: "left-bullet", from: leftColumn.bullets)
            }
            if let rightColumn {
                rightTitleSegments = makeSegments(kind: "right-title", from: rightColumn.titleParagraphs)
                rightBulletSegments = makeSegments(kind: "right-bullet", from: rightColumn.bullets)
            }
        }

        return SlideSegmentBuckets(
            title: titleSegments,
            subtitle: subtitleSegments,
            bodyBullets: bodyBulletSegments,
            quote: quoteSegments,
            attribution: attributionSegments,
            imagePlaceholder: imageSegments,
            caption: captionSegments,
            leftTitle: leftTitleSegments,
            leftBullets: leftBulletSegments,
            rightTitle: rightTitleSegments,
            rightBullets: rightBulletSegments
        )
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
        let titleParagraphs = [title].cleanedParagraphs()
        let finalTitleParagraphs = titleParagraphs.isEmpty ? ["Slide \(index)"] : titleParagraphs
        let subtitleParagraphs: [String] = []
        let bulletItems = (bullets ?? []).cleanedParagraphs()
        let noteParagraphs = ParagraphValue.splitParagraphs(notes ?? "")

        return PresentationSlide(
            index: index,
            layout: .bullets,
            title: finalTitleParagraphs.joined(separator: " "),
            titleParagraphs: finalTitleParagraphs,
            subtitle: "",
            subtitleParagraphs: subtitleParagraphs,
            bullets: bulletItems,
            speakerNotes: noteParagraphs.joined(separator: "\n"),
            speakerNoteParagraphs: noteParagraphs,
            keywords: keywords ?? [],
            quote: nil,
            quoteParagraphs: [],
            attribution: nil,
            attributionParagraphs: [],
            imagePlaceholder: nil,
            imagePlaceholderParagraphs: [],
            caption: nil,
            captionParagraphs: [],
            leftColumn: nil,
            rightColumn: nil
        )
    }
}

private struct RichDeckFile: Decodable {
    let deckTitle: ParagraphValue?
    let subtitle: ParagraphValue?
    let author: ParagraphValue?
    let slides: [RichSlideFile]

    func toDeck() -> PresentationDeck {
        let mappedSlides = slides.enumerated().map { offset, slide in
            slide.toSlide(index: offset + 1)
        }

        let title = deckTitle?.joinedWithSpaces.nilIfBlank ?? "Untitled Deck"
        let subtitleValue = subtitle?.joinedWithSpaces.nilIfBlank
        let authorValue = author?.joinedWithSpaces.nilIfBlank

        return PresentationDeck(
            presentationTitle: title,
            subtitle: subtitleValue,
            author: authorValue,
            language: nil,
            slides: mappedSlides
        )
    }
}

private struct RichSlideFile: Decodable {
    let layout: String?
    let title: ParagraphValue?
    let subtitle: ParagraphValue?
    let bullets: [String]?
    let speakerNotes: ParagraphValue?
    let quote: ParagraphValue?
    let attribution: ParagraphValue?
    let imagePlaceholder: ParagraphValue?
    let caption: ParagraphValue?
    let left: RichSlideColumnFile?
    let right: RichSlideColumnFile?

    func toSlide(index: Int) -> PresentationSlide {
        let resolvedLayout = SlideLayout(rawValue: layout ?? "") ?? .unknown
        let leftColumn = left?.toColumn()
        let rightColumn = right?.toColumn()

        let rawTitleParagraphs = (title?.paragraphs ?? []).cleanedParagraphs()
        let finalTitleParagraphs = rawTitleParagraphs.isEmpty ? ["Slide \(index)"] : rawTitleParagraphs
        let finalTitle = finalTitleParagraphs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let subtitleParagraphs = (subtitle?.paragraphs ?? []).cleanedParagraphs()
        let bulletItems = (bullets ?? []).cleanedParagraphs()
        let noteParagraphs = (speakerNotes?.paragraphs ?? []).cleanedParagraphs()
        let quoteParagraphs = (quote?.paragraphs ?? []).cleanedParagraphs()
        let attributionParagraphs = (attribution?.paragraphs ?? []).cleanedParagraphs()
        let imageParagraphs = (imagePlaceholder?.paragraphs ?? []).cleanedParagraphs()
        let captionParagraphs = (caption?.paragraphs ?? []).cleanedParagraphs()

        var mergedBullets = bulletItems
        if resolvedLayout == .twoColumn {
            if let leftColumn {
                mergedBullets.append(contentsOf: leftColumn.bullets.map { "\(leftColumn.title): \($0)" })
            }
            if let rightColumn {
                mergedBullets.append(contentsOf: rightColumn.bullets.map { "\(rightColumn.title): \($0)" })
            }
        }

        return PresentationSlide(
            index: index,
            layout: resolvedLayout,
            title: finalTitle,
            titleParagraphs: finalTitleParagraphs,
            subtitle: subtitleParagraphs.joined(separator: " "),
            subtitleParagraphs: subtitleParagraphs,
            bullets: mergedBullets,
            speakerNotes: noteParagraphs.joined(separator: "\n"),
            speakerNoteParagraphs: noteParagraphs,
            keywords: Self.deriveKeywords(from: finalTitle, bullets: mergedBullets),
            quote: quoteParagraphs.joined(separator: " ").nilIfBlank,
            quoteParagraphs: quoteParagraphs,
            attribution: attributionParagraphs.joined(separator: " ").nilIfBlank,
            attributionParagraphs: attributionParagraphs,
            imagePlaceholder: imageParagraphs.joined(separator: " ").nilIfBlank,
            imagePlaceholderParagraphs: imageParagraphs,
            caption: captionParagraphs.joined(separator: " ").nilIfBlank,
            captionParagraphs: captionParagraphs,
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
    let title: ParagraphValue?
    let bullets: [String]?

    func toColumn() -> SlideColumn {
        let titleParagraphs = (title?.paragraphs ?? []).cleanedParagraphs()
        let finalTitleParagraphs = titleParagraphs.isEmpty ? ["Column"] : titleParagraphs
        return SlideColumn(
            title: finalTitleParagraphs.joined(separator: " "),
            titleParagraphs: finalTitleParagraphs,
            bullets: (bullets ?? []).cleanedParagraphs()
        )
    }
}

private struct ParagraphValue: Decodable {
    let paragraphs: [String]

    var joinedWithSpaces: String {
        paragraphs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            paragraphs = []
            return
        }

        if let single = try? container.decode(String.self) {
            paragraphs = Self.splitParagraphs(single)
            return
        }

        if let list = try? container.decode([String].self) {
            paragraphs = list.cleanedParagraphs()
            return
        }

        paragraphs = []
    }

    static func splitParagraphs(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .cleanedParagraphs()
    }
}

private extension Array where Element == String {
    func cleanedParagraphs() -> [String] {
        map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
