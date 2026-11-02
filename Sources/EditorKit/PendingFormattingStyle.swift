import MarkdownEngine

public enum PendingFormattingStyle: String, CaseIterable, Sendable {
    case bold, italic, strikethrough, inlineCode

    init?(command: FormattingCommand) {
        switch command {
        case .bold: self = .bold
        case .italic: self = .italic
        case .strikethrough: self = .strikethrough
        case .inlineCode: self = .inlineCode
        default: return nil
        }
    }

    var command: FormattingCommand {
        switch self {
        case .bold: return .bold
        case .italic: return .italic
        case .strikethrough: return .strikethrough
        case .inlineCode: return .inlineCode
        }
    }
}