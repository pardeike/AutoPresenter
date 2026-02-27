import Foundation

enum SlideAction: String, Codable, CaseIterable, Sendable {
    case next
    case previous
    case goto
    case stay
}

struct SlideCommand: Codable, Equatable, Sendable {
    let action: SlideAction
    let targetSlide: Int?
    let confidence: Double
    let rationale: String
    let utteranceExcerpt: String?

    enum CodingKeys: String, CodingKey {
        case action
        case targetSlide = "target_slide"
        case confidence
        case rationale
        case utteranceExcerpt = "utterance_excerpt"
    }

    var signature: String {
        "\(action.rawValue):\(targetSlide ?? -1)"
    }
}
