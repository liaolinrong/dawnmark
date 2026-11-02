import Testing
@testable import MarkdownEngine

@Test func parsesWithLocations() {
    let document = MarkdownParser.parse("# Hello\n\n**world**")
    #expect(document.childCount == 2)
    #expect(document.child(at: 0)?.range?.lowerBound.line == 1)
}