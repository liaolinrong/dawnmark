import Foundation
import Markdown

public struct SourceCoordinates: Sendable {
    public let source: String
    private let lineByteOffsets: [Int]

    public init(source: String) {
        self.source = source
        var offsets = [0]
        let bytes = Array(source.utf8)
        for offset in bytes.indices {
            if bytes[offset] == 10 || (bytes[offset] == 13 && (offset + 1 == bytes.count || bytes[offset + 1] != 10)) {
                offsets.append(offset + 1)
            }
        }
        lineByteOffsets = offsets
    }

    public func utf16Offset(line: Int, utf8Column: Int) -> Int? {
        guard line > 0, line <= lineByteOffsets.count, utf8Column > 0 else { return nil }
        let offset = lineByteOffsets[line - 1] + utf8Column - 1
        let limit = line < lineByteOffsets.count ? lineByteOffsets[line] : source.utf8.count
        guard offset <= limit, offset <= source.utf8.count else { return nil }
        let byteIndex = source.utf8.index(source.utf8.startIndex, offsetBy: offset)
        guard let index = String.Index(byteIndex, within: source) else { return nil }
        return index.utf16Offset(in: source)
    }

    public func nsRange(_ range: SourceRange?) -> NSRange? {
        guard let range,
              let start = utf16Offset(line: range.lowerBound.line, utf8Column: range.lowerBound.column),
              let end = utf16Offset(line: range.upperBound.line, utf8Column: range.upperBound.column),
              end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

public enum SegmentKind: Sendable {
    case text, code, inlineCode, lineBreak, decoration, attachment, tableSeparator
}

public struct MappingSegment: Sendable {
    public let displayedNSRange: NSRange
    public let sourceNSRange: NSRange
    public let kind: SegmentKind
    public let isIdentity: Bool
    public let continuationPrefix: String
    public let isListMarker: Bool

    public init(displayedNSRange: NSRange, sourceNSRange: NSRange, kind: SegmentKind, isIdentity: Bool, continuationPrefix: String = "", isListMarker: Bool = false) {
        self.displayedNSRange = displayedNSRange
        self.sourceNSRange = sourceNSRange
        self.kind = kind
        self.isIdentity = isIdentity
        self.continuationPrefix = continuationPrefix
        self.isListMarker = isListMarker
    }
}

public struct SourcePatch: Sendable, Equatable {
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public struct MappingContainer: Sendable {
    public let displayedNSRange: NSRange
    public let sourceNSRange: NSRange

    public init(displayedNSRange: NSRange, sourceNSRange: NSRange) {
        self.displayedNSRange = displayedNSRange
        self.sourceNSRange = sourceNSRange
    }
}

public struct SourceMap: Sendable {
    public let segments: [MappingSegment]
    public let containers: [MappingContainer]
    public let sourceLength: Int
    public let displayedLength: Int

    public init(segments: [MappingSegment], sourceLength: Int, displayedLength: Int, containers: [MappingContainer] = []) {
        self.segments = segments
        self.containers = containers
        self.sourceLength = sourceLength
        self.displayedLength = displayedLength
    }

    public func sourceOffset(forDisplayedOffset offset: Int, preferTrailing: Bool = false) -> Int {
        let offset = min(max(0, offset), displayedLength)
        let editable = segments.filter { $0.kind != .decoration && $0.kind != .tableSeparator }
        if let marker = segments.first(where: { $0.isListMarker && NSLocationInRange(offset, $0.displayedNSRange) }) {
            return NSMaxRange(marker.sourceNSRange)
        }
        if preferTrailing, let marker = segments.last(where: { $0.isListMarker && NSMaxRange($0.displayedNSRange) == offset }) {
            return NSMaxRange(marker.sourceNSRange)
        }
        if preferTrailing,
           let next = editable.first(where: { $0.displayedNSRange.location == offset && $0.kind == .code }),
           editable.last(where: { NSMaxRange($0.displayedNSRange) == offset })?.kind != .code {
            return next.sourceNSRange.location
        }
        if preferTrailing, let previous = editable.last(where: { NSMaxRange($0.displayedNSRange) == offset }) {
            if previous.kind == .lineBreak,
               let next = editable.first(where: { $0.displayedNSRange.location == offset }),
               next.sourceNSRange.location > NSMaxRange(previous.sourceNSRange) {
                return next.sourceNSRange.location
            }
            return NSMaxRange(previous.sourceNSRange)
        }
        if let segment = editable.first(where: { NSLocationInRange(offset, $0.displayedNSRange) }) {
            if segment.isIdentity { return segment.sourceNSRange.location + offset - segment.displayedNSRange.location }
            return segment.sourceNSRange.location
        }
        if let previous = editable.last(where: { NSMaxRange($0.displayedNSRange) <= offset }) {
            return NSMaxRange(previous.sourceNSRange)
        }
        return editable.first?.sourceNSRange.location ?? sourceLength
    }

    private func insertionSegment(at offset: Int) -> MappingSegment? {
        let editable = segments.filter { $0.kind != .decoration && $0.kind != .tableSeparator }
        let previous = editable.last(where: { NSMaxRange($0.displayedNSRange) == offset })
        let next = editable.first(where: { NSLocationInRange(offset, $0.displayedNSRange) })
        if let next, next.kind == .code && previous?.kind != .code
            || previous?.kind == .lineBreak && !next.continuationPrefix.isEmpty { return next }
        return previous ?? next
    }

    public func sourceRange(forDisplayedRange range: NSRange) -> NSRange {
        let start = sourceOffset(forDisplayedOffset: range.location, preferTrailing: range.length == 0)
        let end = range.length == 0 ? start : sourceOffset(forDisplayedOffset: NSMaxRange(range), preferTrailing: true)
        return NSRange(location: min(start, end), length: abs(end - start))
    }

    public func displayedOffset(forSourceOffset offset: Int) -> Int {
        guard offset < sourceLength else { return displayedLength }
        let editable = segments.filter { $0.kind != .decoration && $0.kind != .tableSeparator }
        if let segment = editable.first(where: { NSLocationInRange(offset, $0.sourceNSRange) }) {
            return segment.displayedNSRange.location + (segment.isIdentity ? offset - segment.sourceNSRange.location : 0)
        }
        if let previous = editable.last(where: { $0.isIdentity && NSMaxRange($0.sourceNSRange) == offset }),
           segments.contains(where: { $0.kind == .tableSeparator && $0.displayedNSRange.location == NSMaxRange(previous.displayedNSRange) }) {
            return NSMaxRange(previous.displayedNSRange)
        }
        if let next = editable.filter({ $0.sourceNSRange.location >= offset }).min(by: { $0.sourceNSRange.location < $1.sourceNSRange.location }) {
            return next.displayedNSRange.location
        }
        return displayedLength
    }

    public func displayedRange(forSourceRange range: NSRange) -> NSRange {
        let start = displayedOffset(forSourceOffset: range.location)
        let end = displayedOffset(forSourceOffset: NSMaxRange(range))
        return NSRange(location: start, length: max(0, end - start))
    }

    public func patches(forDisplayedRange range: NSRange, replacement: String, source: String) -> [SourcePatch]? {
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= displayedLength else { return nil }
        var deleted: [NSRange] = []
        var context: SegmentKind = .text
        var continuation = ""
        for segment in segments {
            let intersection = NSIntersectionRange(range, segment.displayedNSRange)
            guard intersection.length > 0 else { continue }
            if segment.isListMarker, replacement.isEmpty {
                deleted.append(segment.sourceNSRange)
                continue
            }
            guard segment.kind != .decoration && segment.kind != .tableSeparator else { return nil }
            if !segment.isIdentity && intersection != segment.displayedNSRange { return nil }
            context = deleted.isEmpty ? segment.kind : context
            if deleted.isEmpty { continuation = segment.continuationPrefix }
            var mapped = segment.isIdentity
                ? NSRange(location: segment.sourceNSRange.location + intersection.location - segment.displayedNSRange.location, length: intersection.length)
                : segment.sourceNSRange
            if segment.kind == .lineBreak && !segment.continuationPrefix.isEmpty {
                if let next = segments.first(where: { $0.displayedNSRange.location >= NSMaxRange(segment.displayedNSRange) }), next.kind == .decoration { return nil }
                let end = NSMaxRange(mapped)
                let suffix = (source as NSString).substring(from: end)
                if suffix.hasPrefix(segment.continuationPrefix) {
                    mapped.length += segment.continuationPrefix.utf16.count
                } else if !suffix.isEmpty && suffix.first != "\n" && suffix.first != "\r" { return nil }
            }
            if let last = deleted.last, NSMaxRange(last) == mapped.location {
                deleted[deleted.count - 1] = NSUnionRange(last, mapped)
            } else { deleted.append(mapped) }
        }
        if replacement.isEmpty && range.length > 0 {
            for container in containers where container.displayedNSRange.length > 0 && NSIntersectionRange(range, container.displayedNSRange) == container.displayedNSRange {
                deleted.append(container.sourceNSRange)
            }
            var merged: [NSRange] = []
            for span in deleted.sorted(by: { $0.location < $1.location }) {
                if let last = merged.last, span.location <= NSMaxRange(last) { merged[merged.count - 1] = NSUnionRange(last, span) }
                else { merged.append(span) }
            }
            deleted = merged
        }
        var insertion = deleted.first?.location ?? sourceOffset(forDisplayedOffset: range.location, preferTrailing: true)
        if range.length == 0, replacement.hasPrefix("\n") || replacement.hasPrefix("\r") {
            let original = source as NSString
            for container in containers where container.displayedNSRange.length > 0 && NSMaxRange(container.displayedNSRange) == range.location {
                let end = NSMaxRange(container.sourceNSRange)
                guard end > insertion else { continue }
                let suffix = original.substring(with: NSRange(location: insertion, length: end - insertion))
                if !suffix.contains("\n"), !suffix.contains("\r") { insertion = end }
            }
        }
        if deleted.isEmpty {
            let listMarker = segments.first(where: { $0.isListMarker && NSLocationInRange(range.location, $0.displayedNSRange) })
            let segment = insertionSegment(at: range.location)
            context = segment?.kind ?? .text
            if listMarker != nil { context = .text }
            continuation = segment?.continuationPrefix ?? ""
            if context == .inlineCode, insertion > NSMaxRange(segment?.sourceNSRange ?? NSRange(location: insertion, length: 0)) {
                context = .text
            }
            if context == .decoration || context == .tableSeparator { return nil }
            if context == .attachment { context = .text }
        }
        if deleted.isEmpty, context == .text || context == .lineBreak, !replacement.isEmpty {
            let original = source as NSString
            let lineStart = original.lineRange(for: NSRange(location: insertion, length: 0)).location
            let prefix = original.substring(with: NSRange(location: lineStart, length: insertion - lineStart))
            if prefix.allSatisfy({ $0 == " " || $0 == "\t" }), prefix.count >= 4 || prefix.contains("\t") {
                let candidate = original.replacingCharacters(in: NSRange(location: insertion, length: 0), with: replacement)
                let coordinates = SourceCoordinates(source: candidate)
                var nodes: [Markup] = [MarkdownParser.parse(candidate)]
                while let node = nodes.popLast() {
                    if node is CodeBlock, let span = coordinates.nsRange(node.range),
                              insertion >= span.location, insertion <= NSMaxRange(span) {
                        context = .code
                        break
                    }
                    nodes.append(contentsOf: node.children)
                }
            }
        }
        let isCode = context == .code || context == .inlineCode
        if context == .inlineCode && (replacement.contains("`") || replacement.contains("\n") || replacement.contains("\r")) { return nil }
        if context == .code {
            let original = source as NSString
            let lineRange = original.lineRange(for: NSRange(location: insertion, length: 0))
            let line = original.substring(with: lineRange) as NSString
            let local = NSRange(location: insertion - lineRange.location, length: min(deleted.first?.length ?? 0, NSMaxRange(lineRange) - insertion))
            let candidate = line.replacingCharacters(in: local, with: replacement)
            let fence = try! NSRegularExpression(pattern: "(?m)^ {0,3}(`{3,}|~{3,})[ \\t]*$")
            if fence.firstMatch(in: candidate, range: NSRange(location: 0, length: candidate.utf16.count)) != nil { return nil }
        }
        let escaped = isCode ? replacement : Self.escapeText(replacement).replacingOccurrences(of: "\n", with: "\n" + continuation)
        var patches = deleted.map { SourcePatch(range: $0, replacement: "") }
        if patches.isEmpty { patches = [SourcePatch(range: NSRange(location: insertion, length: 0), replacement: escaped)] }
        else { patches[0] = SourcePatch(range: patches[0].range, replacement: escaped) }
        guard patches.allSatisfy({ Range($0.range, in: source) != nil }) else { return nil }
        return patches
    }

    public static func escapeText(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_{}[]<>#|~!&+-.".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    public func replacing(displayed range: NSRange, with replacement: String, patches: [SourcePatch]) -> SourceMap {
        let displayDelta = replacement.utf16.count - range.length
        let ordered = patches.sorted { $0.range.location < $1.range.location }
        func rebased(_ offset: Int, trailing: Bool = false) -> Int {
            var delta = 0
            for patch in ordered {
                if offset < patch.range.location || (offset == patch.range.location && !trailing) { break }
                if offset <= NSMaxRange(patch.range) {
                    return patch.range.location + delta + (trailing ? patch.replacement.utf16.count : 0)
                }
                delta += patch.replacement.utf16.count - patch.range.length
            }
            return offset + delta
        }
        var updated: [MappingSegment] = []
        for segment in segments {
            let bounds = segment.displayedNSRange
            var slices: [NSRange] = []
            if bounds.location < range.location {
                slices.append(NSRange(location: bounds.location, length: min(NSMaxRange(bounds), range.location) - bounds.location))
            }
            if NSMaxRange(bounds) > NSMaxRange(range) {
                let start = max(bounds.location, NSMaxRange(range))
                slices.append(NSRange(location: start, length: NSMaxRange(bounds) - start))
            }
            for slice in slices where slice.length > 0 {
                guard segment.isIdentity || slice == bounds else { continue }
                let oldStart = segment.sourceNSRange.location + (segment.isIdentity ? slice.location - bounds.location : 0)
                let oldEnd = segment.isIdentity ? oldStart + slice.length : NSMaxRange(segment.sourceNSRange)
                let start = rebased(oldStart, trailing: slice.location >= NSMaxRange(range))
                let end = rebased(oldEnd)
                let displayed = NSRange(location: slice.location + (slice.location >= NSMaxRange(range) ? displayDelta : 0), length: slice.length)
                updated.append(MappingSegment(displayedNSRange: displayed, sourceNSRange: NSRange(location: start, length: max(0, end - start)), kind: segment.kind, isIdentity: segment.isIdentity, continuationPrefix: segment.continuationPrefix, isListMarker: segment.isListMarker))
            }
        }
        if !replacement.isEmpty, let first = ordered.first {
            let segment = insertionSegment(at: range.location)
            let context = segment?.kind ?? .text
            let continuation = segment?.continuationPrefix ?? ""
            let isCode = context == .code || context == .inlineCode
            var displayOffset = range.location
            var sourceOffset = rebased(first.range.location)
            for character in replacement {
                let value = String(character)
                let encoded = isCode ? value : Self.escapeText(value)
                updated.append(MappingSegment(displayedNSRange: NSRange(location: displayOffset, length: value.utf16.count), sourceNSRange: NSRange(location: sourceOffset, length: encoded.utf16.count), kind: isCode ? context : value == "\n" ? .lineBreak : .text, isIdentity: value == encoded, continuationPrefix: continuation))
                displayOffset += value.utf16.count
                sourceOffset += encoded.utf16.count
                if value == "\n", !isCode { sourceOffset += continuation.utf16.count }
            }
        }
        let provisional = SourceMap(segments: updated.sorted { $0.displayedNSRange.location < $1.displayedNSRange.location }, sourceLength: sourceLength + ordered.reduce(0) { $0 + $1.replacement.utf16.count - $1.range.length }, displayedLength: displayedLength + displayDelta)
        let rebasedContainers = containers.compactMap { container -> MappingContainer? in
            let start = rebased(container.sourceNSRange.location)
            let end = rebased(NSMaxRange(container.sourceNSRange), trailing: true)
            guard end > start else { return nil }
            let span = NSRange(location: start, length: end - start)
            let displayed = provisional.displayedRange(forSourceRange: span)
            guard displayed.length > 0 else { return nil }
            return MappingContainer(displayedNSRange: displayed, sourceNSRange: span)
        }
        return SourceMap(segments: provisional.segments, sourceLength: provisional.sourceLength, displayedLength: provisional.displayedLength, containers: rebasedContainers)
    }
}