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
            "Hard output contract: emit exactly one arguments object with key commands=[...].",
            "commands must be an ordered array of atomic actions for this turn.",
            "Every command object MUST include all keys exactly: action,target_slide,mark_index,confidence,rationale,utterance_excerpt,highlight_phrases.",
            "Never omit keys. Never output extra keys. Never output partial/truncated JSON.",
            "Allowed actions per command: next, previous, goto, mark, stay.",
            "Use literal matching. Avoid creative interpretation and avoid paraphrasing.",
            "When action is mark: mark_index MUST be an explicit integer from current slide segments; target_slide MUST be null.",
            "When action is goto: target_slide MUST be an explicit integer from the deck; mark_index MUST be null.",
            "When action is next/previous/stay: target_slide MUST be null and mark_index MUST be null.",
            "If you cannot provide a valid mark_index, do not emit mark. Emit stay.",
            "If you cannot provide a valid target_slide for goto, do not emit goto. Emit stay.",
            "If multiple segments are discussed in one continuous thought, emit multiple mark commands in sequence.",
            "At most one navigation command (next/previous/goto) is allowed in commands.",
            "If a navigation command is present, it must be the last command in commands.",
            "Use stay only as a single-command batch when no specific mark or navigation is justified.",
            "Never combine stay with other actions.",
            "If you cannot map speech to any explicit segment index and cannot justify navigation, emit commands=[{action:stay,...}].",
            "When multiple segment matches are possible, choose the lowest matching segment index first.",
            "Set confidence in [0,1].",
            "If asked for first/start slide, use action=goto with target_slide=Deck first slide index.",
            "If asked for last/final/end slide, use action=goto with target_slide=Deck last slide index.",
            "Set highlight_phrases per command to 0-5 short exact phrases from the current slide that match the latest speech.",
            "Keep highlight_phrases as exact slide substrings only (no paraphrases); use [] when nothing matches.",
            "Default to stay when speech is tangent, filler, anecdotal, or not clearly tied to slide content.",
            "Do not emit mark unless the speech clearly maps to an explicit current slide segment.",
            "Do not emit navigation unless the presenter explicitly asks to move slides.",
            "Treat literal cues like 'next slide' and 'previous slide' as explicit navigation requests.",
            "Do not require extra wording like 'move to the next slide' when cue is already explicit.",
            "Do not infer navigation from vague momentum or nonverbal cues.",
            "Never emit a command just to avoid inactivity; obvious inaction is preferred.",
            "Never combine mark and navigation in the same command batch.",
            "If uncertain, choose stay.",
            "Never hallucinate indices.",
            "Keep rationale plain and brief (4-10 simple words, factual, no flourish).",
            "Keep utterance_excerpt as an exact quote up to 10 words, or null when not needed.",
            "Valid example (stay): {commands:[{action:stay,target_slide:null,mark_index:null,confidence:0.84,rationale:'tangent not tied to slide',utterance_excerpt:null,highlight_phrases:[]}]}",
            "Invalid examples (never output): mark with mark_index=null; goto with target_slide=null; next with target_slide!=null; missing required keys; partial JSON.",
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

enum ImagePresentationStyle: String, Sendable, CaseIterable {
    case scroll
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
            + imagePlaceholder
            + caption
            + leftTitle
            + leftBullets
            + rightTitle
            + rightBullets
    }
}

struct PresentationSlide: Identifiable, Sendable {
    static let defaultImageScrollSpeed: Double = 34.0

    let index: Int
    let layout: SlideLayout
    let title: String
    let titleParagraphs: [String]
    let subtitle: String
    let subtitleParagraphs: [String]
    let bullets: [String]
    let quote: String?
    let quoteParagraphs: [String]
    let imagePlaceholder: String?
    let imagePlaceholderParagraphs: [String]
    let imagePresentationStyle: ImagePresentationStyle
    let imageScrollSpeed: Double
    let caption: String?
    let captionParagraphs: [String]
    let leftColumn: SlideColumn?
    let rightColumn: SlideColumn?

    var id: Int { index }

    var promptSummary: String {
        let titlePart = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch layout {
        case .quote:
            let quotePart = quote ?? ""
            if titlePart.isEmpty {
                return "[quote] \(quotePart)"
            }
            return "\(titlePart) [quote] \(quotePart)"
        case .twoColumn:
            return titlePart.isEmpty ? "[two-column]" : "\(titlePart) [two-column]"
        case .image:
            return titlePart.isEmpty ? "[image]" : "\(titlePart) [image]"
        case .title:
            if titlePart.isEmpty {
                return subtitle.isEmpty ? "[title]" : subtitle
            }
            return subtitle.isEmpty ? titlePart : "\(titlePart) — \(subtitle)"
        case .bullets, .unknown:
            return titlePart.isEmpty ? "[\(bullets.count) bullets]" : "\(titlePart) [\(bullets.count) bullets]"
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
        let subtitleSegments = layout == .image
            ? []
            : makeSegments(kind: "subtitle", from: subtitleParagraphs)

        var bodyBulletSegments: [SlideMarkSegment] = []
        var quoteSegments: [SlideMarkSegment] = []
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
            imagePlaceholder: imageSegments,
            caption: captionSegments,
            leftTitle: leftTitleSegments,
            leftBullets: leftBulletSegments,
            rightTitle: rightTitleSegments,
            rightBullets: rightBulletSegments
        )
    }

    func withIndex(_ index: Int) -> PresentationSlide {
        PresentationSlide(
            index: index,
            layout: layout,
            title: title,
            titleParagraphs: titleParagraphs,
            subtitle: subtitle,
            subtitleParagraphs: subtitleParagraphs,
            bullets: bullets,
            quote: quote,
            quoteParagraphs: quoteParagraphs,
            imagePlaceholder: imagePlaceholder,
            imagePlaceholderParagraphs: imagePlaceholderParagraphs,
            imagePresentationStyle: imagePresentationStyle,
            imageScrollSpeed: imageScrollSpeed,
            caption: caption,
            captionParagraphs: captionParagraphs,
            leftColumn: leftColumn,
            rightColumn: rightColumn
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

enum PresentationDeckWriter {
    static func encode(deck: PresentationDeck) throws -> Data {
        let payload = WritableDeckFile(deck: deck)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(payload)
    }
}

private struct WritableDeckFile: Encodable {
    let deckTitle: [String]
    let subtitle: [String]?
    let author: [String]?
    let language: String?
    let slides: [WritableSlideFile]

    init(deck: PresentationDeck) {
        deckTitle = ParagraphValue.splitParagraphs(deck.presentationTitle)
        subtitle = deck.subtitle.flatMap { ParagraphValue.splitParagraphs($0).nilIfEmpty }
        author = deck.author.flatMap { ParagraphValue.splitParagraphs($0).nilIfEmpty }
        language = deck.language?.nilIfBlank
        slides = deck.slides
            .sorted { $0.index < $1.index }
            .map(WritableSlideFile.init(slide:))
    }
}

private struct WritableSlideFile: Encodable {
    let layout: String
    let title: [String]
    let subtitle: [String]?
    let bullets: [String]?
    let quote: [String]?
    let imagePlaceholder: [String]?
    let imagePresentationStyle: String?
    let imageScrollSpeed: Double?
    let caption: [String]?
    let left: WritableSlideColumnFile?
    let right: WritableSlideColumnFile?

    init(slide: PresentationSlide) {
        layout = slide.layout.rawValue
        title = slide.titleParagraphs.cleanedParagraphs()
        subtitle = slide.subtitleParagraphs.cleanedParagraphs().nilIfEmpty
        quote = slide.quoteParagraphs.cleanedParagraphs().nilIfEmpty
        imagePlaceholder = slide.imagePlaceholderParagraphs.cleanedParagraphs().nilIfEmpty
        caption = slide.captionParagraphs.cleanedParagraphs().nilIfEmpty
        left = slide.leftColumn.map(WritableSlideColumnFile.init(column:))
        right = slide.rightColumn.map(WritableSlideColumnFile.init(column:))

        switch slide.layout {
        case .twoColumn:
            bullets = nil
            imagePresentationStyle = nil
            imageScrollSpeed = nil
        case .title:
            bullets = nil
            imagePresentationStyle = nil
            imageScrollSpeed = nil
        case .quote:
            bullets = nil
            imagePresentationStyle = nil
            imageScrollSpeed = nil
        case .image:
            bullets = nil
            imagePresentationStyle = slide.imagePresentationStyle.rawValue
            imageScrollSpeed = slide.imageScrollSpeed
        case .bullets, .unknown:
            bullets = slide.bullets.cleanedParagraphs().nilIfEmpty
            imagePresentationStyle = nil
            imageScrollSpeed = nil
        }
    }
}

private struct WritableSlideColumnFile: Encodable {
    let title: [String]
    let bullets: [String]?

    init(column: SlideColumn) {
        title = column.titleParagraphs.cleanedParagraphs()
        bullets = column.bullets.cleanedParagraphs().nilIfEmpty
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

    func toSlide() -> PresentationSlide {
        let finalTitleParagraphs = [title].cleanedParagraphs()
        let subtitleParagraphs: [String] = []
        let bulletItems = (bullets ?? []).cleanedParagraphs()

        return PresentationSlide(
            index: index,
            layout: .bullets,
            title: finalTitleParagraphs.joined(separator: " "),
            titleParagraphs: finalTitleParagraphs,
            subtitle: "",
            subtitleParagraphs: subtitleParagraphs,
            bullets: bulletItems,
            quote: nil,
            quoteParagraphs: [],
            imagePlaceholder: nil,
            imagePlaceholderParagraphs: [],
            imagePresentationStyle: .scroll,
            imageScrollSpeed: PresentationSlide.defaultImageScrollSpeed,
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
    let language: String?
    let slides: [RichSlideFile]

    enum CodingKeys: String, CodingKey {
        case deckTitle = "deck_title"
        case legacyDeckTitle = "deckTitle"
        case subtitle
        case author
        case language
        case slides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deckTitle = try container.decodeIfPresent(ParagraphValue.self, forKey: .deckTitle)
            ?? container.decodeIfPresent(ParagraphValue.self, forKey: .legacyDeckTitle)
        subtitle = try container.decodeIfPresent(ParagraphValue.self, forKey: .subtitle)
        author = try container.decodeIfPresent(ParagraphValue.self, forKey: .author)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        slides = try container.decode([RichSlideFile].self, forKey: .slides)
    }

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
            language: language?.nilIfBlank,
            slides: mappedSlides
        )
    }
}

private struct RichSlideFile: Decodable {
    let layout: String?
    let title: ParagraphValue?
    let subtitle: ParagraphValue?
    let bullets: [String]?
    let quote: ParagraphValue?
    let imagePlaceholder: ParagraphValue?
    let imagePresentationStyle: String?
    let imageScrollSpeed: Double?
    let caption: ParagraphValue?
    let left: RichSlideColumnFile?
    let right: RichSlideColumnFile?

    enum CodingKeys: String, CodingKey {
        case layout
        case title
        case subtitle
        case bullets
        case quote
        case imagePlaceholder = "image_placeholder"
        case legacyImagePlaceholder = "imagePlaceholder"
        case imagePresentationStyle = "image_presentation_style"
        case legacyImagePresentationStyle = "imagePresentationStyle"
        case imageScrollSpeed = "image_scroll_speed"
        case legacyImageScrollSpeed = "imageScrollSpeed"
        case caption
        case left
        case right
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decodeIfPresent(String.self, forKey: .layout)
        title = try container.decodeIfPresent(ParagraphValue.self, forKey: .title)
        subtitle = try container.decodeIfPresent(ParagraphValue.self, forKey: .subtitle)
        bullets = try container.decodeIfPresent([String].self, forKey: .bullets)
        quote = try container.decodeIfPresent(ParagraphValue.self, forKey: .quote)
        imagePlaceholder = try container.decodeIfPresent(ParagraphValue.self, forKey: .imagePlaceholder)
            ?? container.decodeIfPresent(ParagraphValue.self, forKey: .legacyImagePlaceholder)
        imagePresentationStyle = try container.decodeIfPresent(String.self, forKey: .imagePresentationStyle)
            ?? container.decodeIfPresent(String.self, forKey: .legacyImagePresentationStyle)
        imageScrollSpeed = try container.decodeIfPresent(Double.self, forKey: .imageScrollSpeed)
            ?? container.decodeIfPresent(Double.self, forKey: .legacyImageScrollSpeed)
        caption = try container.decodeIfPresent(ParagraphValue.self, forKey: .caption)
        left = try container.decodeIfPresent(RichSlideColumnFile.self, forKey: .left)
        right = try container.decodeIfPresent(RichSlideColumnFile.self, forKey: .right)
    }

    func toSlide(index: Int) -> PresentationSlide {
        let resolvedLayout = SlideLayout(rawValue: layout ?? "") ?? .unknown
        let leftColumn = left?.toColumn()
        let rightColumn = right?.toColumn()

        let finalTitleParagraphs = (title?.paragraphs ?? []).cleanedParagraphs()
        let finalTitle = finalTitleParagraphs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let subtitleParagraphs = (subtitle?.paragraphs ?? []).cleanedParagraphs()
        let resolvedSubtitleParagraphs = resolvedLayout == .image ? [] : subtitleParagraphs
        let bulletItems = (bullets ?? []).cleanedParagraphs()
        let quoteParagraphs = (quote?.paragraphs ?? []).cleanedParagraphs()
        let imageParagraphs = (imagePlaceholder?.paragraphs ?? []).cleanedParagraphs()
        let captionParagraphs = (caption?.paragraphs ?? []).cleanedParagraphs()
        let resolvedImagePresentationStyle = ImagePresentationStyle(
            rawValue: imagePresentationStyle?.lowercased() ?? ""
        ) ?? .scroll
        let resolvedImageScrollSpeed = imageScrollSpeed ?? PresentationSlide.defaultImageScrollSpeed

        var mergedBullets = bulletItems
        if resolvedLayout == .twoColumn {
            if let leftColumn {
                let leftPrefix = leftColumn.title.nilIfBlank
                mergedBullets.append(contentsOf: leftColumn.bullets.map { bullet in
                    guard let leftPrefix else { return bullet }
                    return "\(leftPrefix): \(bullet)"
                })
            }
            if let rightColumn {
                let rightPrefix = rightColumn.title.nilIfBlank
                mergedBullets.append(contentsOf: rightColumn.bullets.map { bullet in
                    guard let rightPrefix else { return bullet }
                    return "\(rightPrefix): \(bullet)"
                })
            }
        }

        return PresentationSlide(
            index: index,
            layout: resolvedLayout,
            title: finalTitle,
            titleParagraphs: finalTitleParagraphs,
            subtitle: resolvedSubtitleParagraphs.joined(separator: " "),
            subtitleParagraphs: resolvedSubtitleParagraphs,
            bullets: mergedBullets,
            quote: quoteParagraphs.joined(separator: " ").nilIfBlank,
            quoteParagraphs: quoteParagraphs,
            imagePlaceholder: imageParagraphs.joined(separator: " ").nilIfBlank,
            imagePlaceholderParagraphs: imageParagraphs,
            imagePresentationStyle: resolvedImagePresentationStyle,
            imageScrollSpeed: resolvedImageScrollSpeed,
            caption: captionParagraphs.joined(separator: " ").nilIfBlank,
            captionParagraphs: captionParagraphs,
            leftColumn: leftColumn,
            rightColumn: rightColumn
        )
    }
}

private struct RichSlideColumnFile: Decodable {
    let title: ParagraphValue?
    let bullets: [String]?

    func toColumn() -> SlideColumn {
        let finalTitleParagraphs = (title?.paragraphs ?? []).cleanedParagraphs()
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

    var nilIfEmpty: [String]? {
        isEmpty ? nil : self
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
