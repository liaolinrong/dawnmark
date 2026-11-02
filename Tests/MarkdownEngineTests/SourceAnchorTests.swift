import Foundation
import Testing
import MarkdownEngine

@Suite(.serialized) @MainActor struct SourceAnchorTests {
    @Test func pendingInsertionTracksChangesBeforeAndAfter() throws {
        let session = DocumentSession(source: "\u{4E2D}\u{6587}\u{1F600} target tail")
        let anchor = SourceAnchor(session: session, range: NSRange(location: 5, length: 0))
        #expect(session.replaceSource(in: NSRange(location: 0, length: 0), with: "\u{1F469}\u{200D}\u{1F4BB}\u{524D}"))
        #expect(anchor.range == NSRange(location: 11, length: 0))
        #expect(session.replaceSource(in: NSRange(location: session.source.utf16.count, length: 0), with: "\u{540E}"))
        #expect(anchor.range == NSRange(location: 11, length: 0))
        #expect(session.replaceSource(in: NSRange(location: 6, length: 4), with: "\u{65B0}"))
        #expect(anchor.range == NSRange(location: 8, length: 0))
        #expect(session.revision == 3)
        #expect(session.replaceSource(in: try #require(anchor.range), with: "![image](image.png)"))
        #expect(session.source == "\u{1F469}\u{200D}\u{1F4BB}\u{524D}\u{65B0} ![image](image.png)target tail\u{540E}")
    }

    @Test func selectedTargetTracksUTF16Changes() {
        let session = DocumentSession(source: "\u{1F600}\u{4E2D}\u{6587} target tail")
        let anchor = SourceAnchor(session: session, range: NSRange(location: 5, length: 6))
        #expect(session.replaceSource(in: NSRange(location: 0, length: 4), with: "\u{4E2D}"))
        #expect(anchor.range == NSRange(location: 2, length: 6))
        #expect(session.replaceSource(in: NSRange(location: 8, length: 5), with: "\u{1F600}"))
        #expect(anchor.range == NSRange(location: 2, length: 6))
        #expect((session.source as NSString).substring(with: anchor.range!) == "target")
    }

    @Test func targetEditsPermanentlyCancel() {
        for edit in [NSRange(location: 3, length: 1), NSRange(location: 4, length: 0), NSRange(location: 2, length: 5)] {
            let session = DocumentSession(source: "abtargetcd")
            let anchor = SourceAnchor(session: session, range: NSRange(location: 2, length: 6))
            #expect(session.replaceSource(in: edit, with: "X"))
            #expect(anchor.range == nil)
            session.undoManager.undo()
            #expect(anchor.range == nil)
        }
    }

    @Test func cursorInsertionHasPriorityOverPendingImage() {
        let session = DocumentSession(source: "abCD")
        let anchor = SourceAnchor(session: session, range: NSRange(location: 2, length: 0))
        #expect(session.replaceSource(in: NSRange(location: 2, length: 0), with: "\u{4E2D}\u{1F600}"))
        #expect(anchor.range == NSRange(location: 5, length: 0))
        #expect(session.replaceSource(in: NSRange(location: 5, length: 0), with: "!"))
        #expect(anchor.range == NSRange(location: 6, length: 0))
    }

    @Test func editsCoveringCursorCancel() {
        for edit in [NSRange(location: 2, length: 1), NSRange(location: 1, length: 2)] {
            let session = DocumentSession(source: "abCD")
            let anchor = SourceAnchor(session: session, range: NSRange(location: 2, length: 0))
            #expect(session.replaceSource(in: edit, with: "X"))
            #expect(anchor.range == nil)
        }
    }

    @Test func boundaryEditsPreserveSelection() {
        let session = DocumentSession(source: "abTARGETcd")
        let anchor = SourceAnchor(session: session, range: NSRange(location: 2, length: 6))
        #expect(session.replaceSource(in: NSRange(location: 2, length: 0), with: "X"))
        #expect(anchor.range == NSRange(location: 3, length: 6))
        #expect(session.replaceSource(in: NSRange(location: 9, length: 0), with: "Y"))
        #expect(anchor.range == NSRange(location: 3, length: 6))
        #expect(session.replaceSource(in: NSRange(location: 0, length: 3), with: ""))
        #expect(anchor.range == NSRange(location: 0, length: 6))
    }

    @Test func undoAndRedoTrackSafeEdits() {
        let session = DocumentSession(source: "abCD")
        let anchor = SourceAnchor(session: session, range: NSRange(location: 2, length: 0))
        #expect(session.replaceSource(in: NSRange(location: 0, length: 0), with: "\u{1F600}"))
        #expect(anchor.range == NSRange(location: 4, length: 0))
        session.undoManager.undo()
        #expect(anchor.range == NSRange(location: 2, length: 0))
        session.undoManager.redo()
        #expect(anchor.range == NSRange(location: 4, length: 0))
    }

    @Test func multiplePatchesConservativelyCancel() {
        let session = DocumentSession(source: "abTARGETcd")
        let anchor = SourceAnchor(session: session, range: NSRange(location: 2, length: 6))
        #expect(session.apply([
            SourcePatch(range: NSRange(location: 0, length: 1), replacement: "X"),
            SourcePatch(range: NSRange(location: 9, length: 1), replacement: "Y")
        ]))
        #expect(anchor.range == nil)
        session.undoManager.undo()
        #expect(session.source == "abTARGETcd")
        #expect(anchor.range == nil)
    }

    @Test func characterDiffDoesNotSplitEmojiOrCombiningCharacters() {
        for (original, replacement) in [("\u{1F600}", "\u{1F603}"), ("e\u{301}", "e\u{302}"), ("\u{1F469}\u{200D}\u{1F4BB}", "\u{1F469}\u{200D}\u{1F52C}")] {
            let session = DocumentSession(source: original + " target")
            let anchor = SourceAnchor(session: session, range: NSRange(location: original.utf16.count + 1, length: 0))
            #expect(session.replaceSource(in: NSRange(location: 0, length: original.utf16.count), with: replacement))
            #expect(anchor.range == NSRange(location: replacement.utf16.count + 1, length: 0))
        }
        let session = DocumentSession(source: "e target")
        let anchor = SourceAnchor(session: session, range: NSRange(location: 1, length: 0))
        #expect(session.replaceSource(in: NSRange(location: 1, length: 0), with: "\u{301}"))
        #expect(anchor.range == NSRange(location: 2, length: 0))
    }

    @Test func stopAndWeakObservation() {
        let session = DocumentSession(source: "abc")
        let anchor = SourceAnchor(session: session, range: NSRange(location: 1, length: 0))
        anchor.stop()
        anchor.stop()
        #expect(session.replaceSource(in: NSRange(location: 0, length: 0), with: "X"))
        #expect(anchor.range == NSRange(location: 1, length: 0))
        weak var releasedAnchor: SourceAnchor?
        do {
            let temporary = SourceAnchor(session: session, range: NSRange(location: 0, length: 0))
            releasedAnchor = temporary
        }
        #expect(releasedAnchor == nil)
        var temporarySession: DocumentSession? = DocumentSession(source: "abc")
        weak var releasedSession = temporarySession
        let survivingAnchor = SourceAnchor(session: temporarySession!, range: NSRange(location: 0, length: 0))
        temporarySession = nil
        #expect(releasedSession == nil)
        releasedSession = nil
        survivingAnchor.stop()
    }

    @Test func invalidInitialRangesAreRejected() {
        let session = DocumentSession(source: "\u{1F600}abc")
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: 6, length: 0), NSRange(location: 1, length: 0)] {
            #expect(SourceAnchor(session: session, range: range).range == nil)
        }
    }
}