import Foundation
import Markdown

public struct DocumentImage: Sendable {
    public let url: URL
    public let source: String
    public let alt: String
    public let title: String?
    public let range: NSRange

    func markdown(relativePath: String) -> String {
        let path = relativePath.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "/-._~")))!
        let caption = title.map { " \"" + escaped($0) + "\"" } ?? ""
        return "![" + escaped(alt) + "](" + path + caption + ")"
    }

    private func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_{}[]()#+-.!<>\"".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

public extension DocumentStore {
    func collectImages(source: String, in location: DocumentLocation) throws -> [DocumentImage] {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for index in bytes.indices {
            if bytes[index] == 10 { lineStarts.append(index + 1) }
            else if bytes[index] == 13, index + 1 == bytes.count || bytes[index + 1] != 10 {
                lineStarts.append(index + 1)
            }
        }
        func stringIndex(_ position: SourceLocation) throws -> String.Index {
            guard position.line > 0, position.line <= lineStarts.count, position.column > 0 else {
                throw DocumentStoreError.unsafePath
            }
            let offset = lineStarts[position.line - 1] + position.column - 1
            guard offset <= bytes.count else { throw DocumentStoreError.unsafePath }
            let utf8Index = source.utf8.index(source.utf8.startIndex, offsetBy: offset)
            guard let result = String.Index(utf8Index, within: source) else { throw DocumentStoreError.unsafePath }
            return result
        }
        var images: [DocumentImage] = []
        func visit(_ markup: any Markup) throws {
            if let image = markup as? Image {
                guard let path = image.source, let decoded = path.removingPercentEncoding,
                      let range = image.range else { throw DocumentStoreError.unsafePath }
                if decoded.lowercased().hasPrefix("http:") || decoded.lowercased().hasPrefix("https:") || decoded.hasPrefix("//") {
                    throw DocumentStoreError.externalRemoteResource
                }
                guard !path.contains("?"), !path.contains("#") else { throw DocumentStoreError.unsafePath }
                let url = try location.resourceURL(relativePath: decoded)
                let lower = try stringIndex(range.lowerBound)
                let upper = try stringIndex(range.upperBound)
                guard lower <= upper else { throw DocumentStoreError.unsafePath }
                images.append(DocumentImage(url: url, source: path, alt: image.plainText, title: image.title,
                                            range: NSRange(lower..<upper, in: source)))
            } else {
                for child in markup.children { try visit(child) }
            }
        }
        try visit(document)
        return images
    }
}