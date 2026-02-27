import Foundation

enum SlideAction: String, Codable, CaseIterable, Sendable {
    case next
    case previous
    case goto
    case mark
    case stay

    var isNavigation: Bool {
        switch self {
        case .next, .previous, .goto:
            return true
        case .mark, .stay:
            return false
        }
    }
}

struct SlideCommand: Codable, Equatable, Sendable {
    let action: SlideAction
    let targetSlide: Int?
    let markIndex: Int?
    let confidence: Double
    let rationale: String
    let utteranceExcerpt: String?
    let highlightPhrases: [String]?

    enum CodingKeys: String, CodingKey {
        case action
        case targetSlide = "target_slide"
        case markIndex = "mark_index"
        case confidence
        case rationale
        case utteranceExcerpt = "utterance_excerpt"
        case highlightPhrases = "highlight_phrases"
    }

    var signature: String {
        "\(action.rawValue):\(targetSlide ?? -1):\(markIndex ?? -1)"
    }
}

struct SlideCommandBatch: Codable, Equatable, Sendable {
    let commands: [SlideCommand]
}
