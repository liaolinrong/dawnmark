import ExtraTreeSitter
import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterYAML
import TreeSitterAsm
import TreeSitterDockerfile
import TreeSitterJulia
import TreeSitterLua
import TreeSitterMatlab
import TreeSitterObjc
import TreeSitterPHP
import TreeSitterR
import TreeSitterRuby
import TreeSitterScala
import TreeSitterTOML

enum CodeLanguage: String, CaseIterable, Sendable {
    case swift, python, javascript, typescript, tsx, bash, json, html, css, java, go, c, cpp, rust, yaml
    case csharp, kotlin, php, ruby, dart, scala, objc, sql, r, julia, matlab, powershell, lua, fish
    case verilog, systemverilog, vhdl, asm, toml, dockerfile, makefile

    var displayName: String {
        switch self {
        case .tsx, .json, .html, .css, .c, .yaml, .php, .sql, .r, .matlab, .vhdl, .toml: rawValue.uppercased()
        case .cpp: "C++"
        case .csharp: "C#"
        case .objc: "Objective-C"
        case .powershell: "PowerShell"
        case .systemverilog: "SystemVerilog"
        case .asm: "Assembly (GNU)"
        case .dockerfile: "Dockerfile"
        case .makefile: "Makefile"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        default: rawValue.capitalized
        }
    }

    init?(label: String) {
        let normalized = label.lowercased()
        switch normalized {
        case "py", "python3": self = .python
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "ts", "mts", "cts": self = .typescript
        case "sh", "shell": self = .bash
        case "c++", "cc", "cxx", "hpp": self = .cpp
        case "golang": self = .go
        case "yml": self = .yaml
        case "c#", "cs", "c-sharp": self = .csharp
        case "kt", "kts": self = .kotlin
        case "rb": self = .ruby
        case "objective-c", "objectivec", "obj-c": self = .objc
        case "jl": self = .julia
        case "ps1", "psm1", "pwsh": self = .powershell
        case "sv", "svh": self = .systemverilog
        case "vhd": self = .vhdl
        case "assembly", "gas", "gnu-asm": self = .asm
        case "docker": self = .dockerfile
        case "make", "gnumake": self = .makefile
        case "rs": self = .rust
        default: self.init(rawValue: normalized)
        }
    }

    var parserDefinition: OpaquePointer {
        switch self {
        case .swift: tree_sitter_swift()
        case .python: tree_sitter_python()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .bash: tree_sitter_bash()
        case .json: tree_sitter_json()
        case .html: tree_sitter_html()
        case .css: tree_sitter_css()
        case .java: tree_sitter_java()
        case .go: tree_sitter_go()
        case .c: tree_sitter_c()
        case .cpp: tree_sitter_cpp()
        case .rust: tree_sitter_rust()
        case .yaml: tree_sitter_yaml()
        case .toml: tree_sitter_toml()
        case .dockerfile: tree_sitter_dockerfile()
        case .makefile: tree_sitter_make()
        case .csharp: tree_sitter_c_sharp()
        case .kotlin: tree_sitter_kotlin()
        case .php: tree_sitter_php_only()
        case .ruby: tree_sitter_ruby()
        case .dart: tree_sitter_dart()
        case .scala: tree_sitter_scala()
        case .objc: tree_sitter_objc()
        case .sql: tree_sitter_sql()
        case .r: tree_sitter_r()
        case .julia: tree_sitter_julia()
        case .matlab: tree_sitter_matlab()
        case .powershell: tree_sitter_powershell()
        case .lua: tree_sitter_lua()
        case .fish: tree_sitter_fish()
        case .verilog, .systemverilog: tree_sitter_systemverilog()
        case .vhdl: tree_sitter_vhdl()
        case .asm: tree_sitter_asm()
        }
    }

    var highlightQueryURL: URL? {
        let name: String = switch self {
        case .tsx: "typescript"
        case .verilog: "systemverilog"
        case .makefile: "make"
        case .vhdl: "vhdl-basic"
        default: rawValue
        }
        return Bundle.module.url(forResource: name, withExtension: "scm", subdirectory: "CodeHighlightResources/Queries")
    }
}

struct CodeHighlight: Equatable, Sendable {
    enum Kind: String, Sendable {
        case keyword, string, comment, number, type, function, property, constant, operatorSymbol, tag

        init?(capture: String) {
            switch capture {
            case "character", "escape", "regex": self = .string
            case "boolean", "float": self = .number
            case "constructor": self = .type
            case "attribute": self = .property
            case "operator": self = .operatorSymbol
            default: self.init(rawValue: capture)
            }
        }
    }

    let range: NSRange
    let kind: Kind
}

actor CodeHighlighter {
    static let maximumBlockLength = 64 * 1024
    private static let maximumCacheLength = 256 * 1024
    private static let kindKey = NSAttributedString.Key("CodeHighlightKind")

    private struct Grammar {
        let parser: Parser
        let queries: [Query]
    }

    private struct Key: Hashable {
        let language: CodeLanguage
        let text: Data
    }

    private struct Entry {
        let tree: Tree
        let highlights: [CodeHighlight]
    }

    private var grammars: [CodeLanguage: Grammar] = [:]
    private var unavailable: Set<CodeLanguage> = []
    private var cache: [Key: Entry] = [:]
    private var previousBlocks: [Int: Key] = [:]

    func highlights(in snapshot: RenderSnapshot) -> [CodeHighlight] {
        let text = snapshot.text as NSString
        var result: [CodeHighlight] = []
        var nextCache: [Key: Entry] = [:]
        var nextBlocks: [Int: Key] = [:]
        var remaining = Self.maximumCacheLength
        for (index, block) in snapshot.codeBlocks.enumerated() {
            guard !Task.isCancelled else { return [] }
            guard block.range.length <= Self.maximumBlockLength,
                  let language = CodeLanguage(label: block.language) else { continue }
            let code = text.substring(with: block.range)
            guard let bytes = code.data(using: .utf16LittleEndian) else { continue }
            let key = Key(language: language, text: bytes)
            let previous = previousBlocks[index].flatMap { $0.language == language ? $0 : nil }
            guard let entry = nextCache[key] ?? cache[key] ?? parse(code, key: key, previous: previous) else { continue }
            if nextCache[key] != nil || block.range.length <= remaining {
                if nextCache[key] == nil { remaining -= block.range.length }
                nextCache[key] = entry
                nextBlocks[index] = key
            }
            result.append(contentsOf: entry.highlights.map {
                CodeHighlight(range: NSRange(location: $0.range.location + block.range.location, length: $0.range.length), kind: $0.kind)
            })
        }
        guard !Task.isCancelled else { return [] }
        cache = nextCache
        previousBlocks = nextBlocks
        return result
    }

    private func grammar(for language: CodeLanguage) -> Grammar? {
        if let grammar = grammars[language] { return grammar }
        guard !unavailable.contains(language) else { return nil }
        do {
            let definition = Language(language.parserDefinition)
            guard let url = language.highlightQueryURL else {
                unavailable.insert(language)
                return nil
            }
            let query = try Query(language: definition, url: url)
            let parser = Parser()
            try parser.setLanguage(definition)
            var queries: [Query] = []
            let base: CodeLanguage? = language == .cpp ? .c : ([.typescript, .tsx].contains(language) ? .javascript : nil)
            if let url = base?.highlightQueryURL, let baseQuery = try? Query(language: definition, url: url) {
                queries.append(baseQuery)
            }
            queries.append(query)
            let grammar = Grammar(parser: parser, queries: queries)
            grammars[language] = grammar
            return grammar
        } catch {
            unavailable.insert(language)
            return nil
        }
    }

    private func parse(_ code: String, key: Key, previous: Key?) -> Entry? {
        guard let grammar = grammar(for: key.language) else { return nil }
        let oldTree = previous.flatMap { old in cache[old]?.tree.edit(Self.edit(from: old.text, to: key.text)) }
        guard let parsed = grammar.parser.parse(tree: oldTree, readBlock: { offset, _ in
            guard offset < key.text.count else { return nil }
            return key.text.subdata(in: offset..<min(offset + 4096, key.text.count))
        }), !Task.isCancelled else { return nil }
        let spans = NSMutableAttributedString(string: code)
        for query in grammar.queries {
            let captures = query.execute(in: parsed).resolve(with: .init(string: code)).highlights()
            for capture in captures {
                guard !Task.isCancelled else { return nil }
                guard let name = capture.nameComponents.first, let kind = CodeHighlight.Kind(capture: String(name)),
                      capture.range.length > 0, NSMaxRange(capture.range) <= spans.length else { continue }
                spans.addAttribute(Self.kindKey, value: kind.rawValue, range: capture.range)
            }
        }
        var highlights: [CodeHighlight] = []
        spans.enumerateAttribute(Self.kindKey, in: NSRange(location: 0, length: spans.length)) { value, range, _ in
            if let value = value as? String, let kind = CodeHighlight.Kind(rawValue: value) {
                highlights.append(CodeHighlight(range: range, kind: kind))
            }
        }
        guard let tree = parsed.copy() else { return nil }
        return Entry(tree: tree, highlights: highlights)
    }

    private static func edit(from old: Data, to new: Data) -> InputEdit {
        func equal(_ oldIndex: Int, _ newIndex: Int) -> Bool {
            old[oldIndex] == new[newIndex] && old[oldIndex + 1] == new[newIndex + 1]
        }
        var start = 0
        while start < min(old.count, new.count), equal(start, start) { start += 2 }
        if start > 0, (0xD8...0xDB).contains(old[start - 1]) { start -= 2 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, equal(oldEnd - 2, newEnd - 2) {
            oldEnd -= 2
            newEnd -= 2
        }
        if oldEnd < old.count, (0xDC...0xDF).contains(old[oldEnd + 1]) {
            oldEnd += 2
            newEnd += 2
        }
        func point(in bytes: Data, from start: Int, to end: Int, startingAt point: Point = .zero) -> Point {
            var row = Int(point.row)
            var column = Int(point.column)
            for offset in stride(from: start, to: end, by: 2) {
                if bytes[offset] == 10, bytes[offset + 1] == 0 { row += 1; column = 0 }
                else { column += 2 }
            }
            return Point(row: row, column: column)
        }
        let startPoint = point(in: old, from: 0, to: start)
        return InputEdit(startByte: start, oldEndByte: oldEnd, newEndByte: newEnd, startPoint: startPoint,
                         oldEndPoint: point(in: old, from: start, to: oldEnd, startingAt: startPoint),
                         newEndPoint: point(in: new, from: start, to: newEnd, startingAt: startPoint))
    }
}