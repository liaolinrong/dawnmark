import Foundation
import Testing
import MarkdownEngine

struct ClipboardMarkdownTests {
    private func extract(_ source: String, selecting text: String) -> String? {
        let snapshot = MarkdownRenderer.snapshot(source: source)
        return ClipboardMarkdown.extract(snapshot: snapshot, displayedRange: (snapshot.text as NSString).range(of: text))
    }

    @Test func inlineFullAndPartial() {
        #expect(extract("before **bold words** after", selecting: "bold words") == "**bold words**")
        #expect(extract("before **bold words** after", selecting: "old") == "**old**")
        #expect(extract("before *italic words* after", selecting: "tal") == "*tal*")
        #expect(extract("before ~~strike words~~ after", selecting: "trik") == "~~trik~~")
        #expect(extract("before `a*b` after", selecting: "*") == "`*`")
        #expect(extract("before **bold *nested words* end** after", selecting: "nested") == "***nested***")
        #expect(extract("before **bold *nested words* end** after", selecting: "old nested") == "**old *nested***")
        #expect(extract("before [link words](https://example.com) after", selecting: "ink") == "[ink](<https://example.com>)")
        #expect(extract("before [link words](https://example.com) after", selecting: "link words") == "[link words](https://example.com)")
        #expect(extract("before [link words][target] after\n\n[target]: https://example.com \"Title\"", selecting: "link words") == "[link words](<https://example.com> \"Title\")")
        #expect(extract("before [link words][target] after\n\n[target]: https://example.com", selecting: "ink") == "[ink](<https://example.com>)")
    }

    @Test func headingsAndParagraphs() {
        #expect(extract("## Heading **bold**\n\nBody words", selecting: "Heading bold") == "## Heading **bold**")
        #expect(extract("## Heading **bold**\n\nBody words", selecting: "eading") == "eading")
        #expect(extract("## Heading **bold**\n\nBody words", selecting: "Heading bold\n\nBody") == "## Heading **bold**\n\nBody")
        #expect(extract("# Heading ###\n\nBody", selecting: "Heading") == "# Heading ###")
        #expect(extract("Title\n=====\n\nBody", selecting: "Title") == "Title\n=====")
        #expect(extract("哈哈\n---\n## Kivo **深度测评**\nBody", selecting: "哈哈") == "哈哈\n---")
        #expect(extract("哈哈\n---\n## Kivo **深度测评**\nBody", selecting: "Kivo 深度测评") == "## Kivo **深度测评**")
        #expect(extract("## [Heading][target]\n\nBody\n\n[target]: https://example.com", selecting: "Heading") == "## [Heading](<https://example.com>)")
        #expect(extract("before [](https://example.com) after\n\nBody", selecting: "before  after") == "before [](https://example.com) after")
        #expect(extract("Before\n\nAfter", selecting: "\n\n") == "\n\n")
    }

    @Test func fullStructuresPreserveSource() {
        for source in ["- one\n- **two**\n", "> one\n> **two**\n", "```swift\nlet value = 1\n```\n", "| a | b |\n| --- | --- |\n| c | d |\n", "Title\n=====\n\nBody\n"] {
            let snapshot = MarkdownRenderer.snapshot(source: source)
            #expect(ClipboardMarkdown.extract(snapshot: snapshot, displayedRange: NSRange(location: 0, length: snapshot.text.utf16.count)) == source)
        }
        #expect(extract("Before\n\n- one\n- two\n\nAfter", selecting: "• one\n• two") == "- one\n- two")
        #expect(extract("Before\n\n> one\n> two\n\nAfter", selecting: "one\ntwo") == "> one\n> two")
        #expect(extract("- first\n- second", selecting: "irs") == "irs")
        #expect(extract("```swift\nlet value = 1\n```\n\nAfter", selecting: "value") == "```swift\nvalue\n```")
        #expect(extract("Before\n\n| a | b |\n| --- | --- |\n| c | d |\n\nAfter", selecting: "a\nb\nc\nd") == "| a | b |\n| --- | --- |\n| c | d |")
        #expect(extract("| alpha | beta |\n| --- | --- |\n| gamma | delta |", selecting: "lph") == "lph")
        #expect(extract("Before\n\n```swift\nlet value = 1\n```\n\nAfter", selecting: "let value = 1\n") == "```swift\nlet value = 1\n```")
        #expect(extract("before `` a`b `` after", selecting: "a`") == "`` a` ``")
    }

    @Test func escapingAndUnicode() {
        #expect(extract("before a*b # title [x] &amp; after", selecting: "a*b # title [x] &") == "a\\*b \\# title \\[x\\] \\&")
        #expect(extract("before **中文😀后** after", selecting: "😀") == "**😀**")
        #expect(extract("before **e\u{301}😀** after", selecting: "e\u{301}😀") == "**e\u{301}😀**")
        let snapshot = MarkdownRenderer.snapshot(source: "before **😀** after")
        let emoji = (snapshot.text as NSString).range(of: "😀")
        #expect(ClipboardMarkdown.extract(snapshot: snapshot, displayedRange: NSRange(location: emoji.location, length: 1)) == nil)
        #expect(extract("prefix ... suffix", selecting: "...") == "\\.\\.\\.")
        #expect(MarkdownRenderer.snapshot(source: extract("prefix ... suffix", selecting: "...")!).text == "...")
        #expect(extract("prefix ... suffix", selecting: "prefix ... suffix") == "prefix ... suffix")
    }

    @Test func rejectsAttachmentsAndInvalidRanges() {
        let snapshot = MarkdownRenderer.snapshot(source: "before ![alt](images/photo.png) after")
        #expect(ClipboardMarkdown.extract(snapshot: snapshot, displayedRange: NSRange(location: 0, length: snapshot.text.utf16.count)) == nil)
        #expect(extract(snapshot.source, selecting: "\u{FFFC}") == nil)
        #expect(extract(snapshot.source, selecting: "before") == "before")
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1), NSRange(location: 0, length: 0), NSRange(location: 0, length: Int.max), NSRange(location: snapshot.text.utf16.count, length: 1)] {
            #expect(ClipboardMarkdown.extract(snapshot: snapshot, displayedRange: range) == nil)
        }
    }

    @Test func copiedIndentationRemainsLiteralWhitespace() {
        for indentation in ["    ", "      ", "\t", " \t "] {
            let selected = indentation + "body"
            #expect(extract("prefix" + selected + " suffix", selecting: selected) == selected)
        }
    }

    @Test func inlineSelectionsRoundTripWithoutExtraContent() throws {
        for source in ["pre **bold *nested* rest** end", "pre *italic **bold** rest* end", "pre ~~strike **bold** rest~~ end", "pre [**link** words](https://example.com/a%20b) end", "pre `` a`b `` end", "pre a*b [literal] &amp; 😀 end", "pre [**link** words][target] end\n\n[target]: https://example.com"] {
            let snapshot = MarkdownRenderer.snapshot(source: source)
            for start in 0..<snapshot.text.utf16.count {
                for end in (start + 1)...snapshot.text.utf16.count {
                    let range = NSRange(location: start, length: end - start)
                    guard (snapshot.text as NSString).rangeOfComposedCharacterSequences(for: range) == range else { continue }
                    let markdown = try #require(ClipboardMarkdown.extract(snapshot: snapshot, displayedRange: range))
                    let copied = MarkdownRenderer.snapshot(source: markdown)
                    let selected = (snapshot.text as NSString).substring(with: range)
                    #expect(copied.text == selected, "Source: \(source), range: \(range), extracted: \(markdown)")
                }
            }
        }
    }
}