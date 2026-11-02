import AppKit
import Testing
import MarkdownEngine
import EditorKit

@Suite(.serialized) @MainActor struct ImageLayoutTests {
    @Test func loadedImagesFitCellsAndDoNotOverlapFollowingText() throws {
        let source = "![wide](images/wide.png)\n\nAfter image\n\n| Image | Label |\n| --- | --- |\n| ![cell](images/cell.png) | Short |"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        let image = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            NSColor.systemYellow.setFill()
            NSRect(x: 20, y: 20, width: 120, height: 160).fill()
            NSColor.systemRed.setFill()
            NSRect(x: 160, y: 20, width: 220, height: 160).fill()
            return true
        }
        controller.imageProvider = { _ in image }
        let storage = try #require(controller.textView.textStorage)
        let container = try #require(controller.textView.textContainer)
        let layout = try #require(controller.textView.layoutManager)
        for width in [600.0, 300.0] {
            controller.view.setFrameSize(NSSize(width: width, height: 500))
            controller.view.layoutSubtreeIfNeeded()
            controller.textView.updateTableLayout()
            controller.textView.updateImageLayout()
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                let paragraph = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                let block = paragraph?.textBlocks.first as? NSTextTableBlock
                let expected = block?.contentWidth ?? (container.size.width - 2 * container.lineFragmentPadding)
                #expect(abs(attachment.bounds.width - expected) < 0.1)
                #expect(abs(attachment.bounds.height - expected / 2) < 0.1)
            }
            layout.ensureLayout(for: container)
            let imageRange = (storage.string as NSString).range(of: "\u{FFFC}")
            let afterRange = (storage.string as NSString).range(of: "After image")
            let imageBounds = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: imageRange, actualCharacterRange: nil), in: container)
            let afterBounds = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: afterRange, actualCharacterRange: nil), in: container)
            #expect(afterBounds.minY >= imageBounds.maxY)
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/DawnMark-image-width-\(Int(width)).png"))
            #expect(session.source == source)
        }
    }

    @Test(arguments: [NSSize(width: 40, height: 20), NSSize(width: 1600, height: 900), NSSize(width: 100, height: 300)])
    func imagesFillAvailableWidthAndPreserveAspectRatio(size: NSSize) throws {
        let source = "# Heading\n\n![photo](images/photo.png)\n\nAfter image"
        let session = DocumentSession(source: source)
        session.renderNow()
        let controller = MarkdownEditorController(session: session)
        controller.imageProvider = { _ in NSImage(size: size) }
        let split = try #require(controller.view as? NSSplitView)
        split.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        split.layoutSubtreeIfNeeded()
        let imageRange = (controller.textView.string as NSString).range(of: "\u{FFFC}")
        controller.textView.setSelectedRange(NSRange(location: imageRange.location, length: 0))
        for width in [200.0, 320.0, 140.0] {
            split.setPosition(width, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            let container = try #require(controller.textView.textContainer)
            let attachment = try #require(controller.textView.textStorage?.attribute(.attachment, at: imageRange.location, effectiveRange: nil) as? NSTextAttachment)
            #expect(abs(attachment.bounds.width - (container.size.width - 2 * container.lineFragmentPadding)) < 0.1)
            #expect(abs(attachment.bounds.height / attachment.bounds.width - size.height / size.width) < 0.001)
            #expect(controller.textView.selectedRange().location == imageRange.location)
            #expect(session.source == source)
        }
        controller.mode = .source
        #expect(controller.textView.string == source)
        controller.mode = .richText
        let attachment = try #require(controller.textView.textStorage?.attribute(.attachment, at: imageRange.location, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width > 40)
    }
}