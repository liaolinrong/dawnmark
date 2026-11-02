import Foundation
import Markdown

public enum MarkdownParser {
    public static func parse(_ source: String) -> Document {
        Document(parsing: source, options: [.disableSmartOpts])
    }
}