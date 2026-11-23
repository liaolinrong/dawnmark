import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DocumentWorkspace

@Test func directoryCreationAndPortableImages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DocumentStore()
    let location = try store.create(name: "Notes", in: root)
    #expect(try store.read(location) == "")
    #expect(!FileManager.default.fileExists(atPath: location.imagesURL.path))
    let png = try documentStoreImageData()
    let image = try store.importImage(data: png, into: location)
    #expect(image.relativePath.hasPrefix("images/"))
    try store.save(image.markdown, to: location)
    let copy = try store.duplicate(location, source: image.markdown, name: "Copy", in: root)
    #expect(try store.read(copy) == image.markdown)
    #expect(try Data(contentsOf: copy.resourceURL(relativePath: image.relativePath)) == png)
}

@Test func rejectsUnsafeNamesAndPaths() throws {
    let store = DocumentStore()
    #expect(throws: DocumentStoreError.invalidName) { try store.create(name: "../escape", in: .temporaryDirectory) }
    let location = DocumentLocation(markdownURL: URL(fileURLWithPath: "/tmp/document/note.md"))
    #expect(throws: DocumentStoreError.unsafePath) { try location.resourceURL(relativePath: "../secret") }
    #expect(throws: DocumentStoreError.invalidImage) { try store.importImage(data: Data("bad".utf8), into: location) }
}

@Suite(.serialized) @MainActor struct SecurityScopedBookmarkTests {
    @Test func sandboxEntitlementsMatchXcodeBuildSettings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entitlementURL = root.appendingPathComponent("Configuration/DawnMark.entitlements")
        let entitlements = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: entitlementURL), format: nil) as? [String: Any])
        for key in ["com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write", "com.apple.security.files.bookmarks.app-scope"] {
            #expect(entitlements[key] as? Bool == true)
        }
        let projectURL = root.appendingPathComponent("DawnMark.xcodeproj/project.pbxproj")
        let project = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: projectURL), format: nil) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: [String: Any]])
        let configurations = objects.values.compactMap { $0["buildSettings"] as? [String: Any] }.filter {
            $0["CODE_SIGN_ENTITLEMENTS"] as? String == "Configuration/DawnMark.entitlements"
        }
        #expect(configurations.count == 2)
        for settings in configurations {
            #expect(settings["ENABLE_APP_SANDBOX"] as? String == "YES")
            #expect(settings["ENABLE_USER_SELECTED_FILES"] as? String == "readwrite")
        }
    }

    private func withStore(_ body: (SecurityScopedBookmarks, UserDefaults, URL) throws -> Void) throws {
        let suite = "DawnMark.BookmarkTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try body(SecurityScopedBookmarks(defaults: defaults), defaults, root)
    }

    @Test func directoryGrantPersistsForDocumentsAndAssociatedImages() throws {
        try withStore { bookmarks, defaults, root in
            let location = try DocumentStore().create(name: "Notes", in: root)
            let data = try documentStoreImageData()
            let image = try DocumentStore().importImage(data: data, into: location)
            try DocumentStore().save(image.markdown, to: location)
            try bookmarks.remember(location.directoryURL)
            let reopened = SecurityScopedBookmarks(defaults: defaults)
            let directory = try #require(reopened.resolveDirectory(containing: location.markdownURL))
            let access = directory.startAccessingSecurityScopedResource()
            defer { if access { directory.stopAccessingSecurityScopedResource() } }
            #expect(directory.standardizedFileURL == location.directoryURL.standardizedFileURL)
            #expect(try DocumentStore().read(location) == image.markdown)
            #expect(try Data(contentsOf: location.resourceURL(relativePath: image.relativePath)) == data)
            try DocumentStore().save("Updated\n" + image.markdown, to: location)
            #expect(try DocumentStore().read(location).hasPrefix("Updated\n"))
        }
    }

    @Test func selectedFileGrantPersistsIndependentlyOfDirectoryGrant() throws {
        try withStore { bookmarks, defaults, root in
            let file = root.appendingPathComponent("note.md")
            try Data("Original".utf8).write(to: file)
            try bookmarks.remember(file)
            let reopened = SecurityScopedBookmarks(defaults: defaults)
            let resolved = try #require(reopened.resolve(file))
            let access = resolved.startAccessingSecurityScopedResource()
            defer { if access { resolved.stopAccessingSecurityScopedResource() } }
            #expect(try String(contentsOf: resolved, encoding: .utf8) == "Original")
            try Data("Updated".utf8).write(to: resolved, options: .atomic)
            #expect(try String(contentsOf: resolved, encoding: .utf8) == "Updated")
            #expect(reopened.resolveDirectory(containing: file) == nil)
        }
    }

    @Test func parentGrantCoversNestedDocumentButNotSiblingDirectory() throws {
        try withStore { bookmarks, defaults, root in
            let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
            try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
            let location = try DocumentStore().create(name: "Nested", in: allowed)
            try bookmarks.remember(allowed)
            let reopened = SecurityScopedBookmarks(defaults: defaults)
            #expect(reopened.resolveDirectory(containing: location.markdownURL)?.standardizedFileURL == allowed.standardizedFileURL)
            #expect(reopened.resolveDirectory(containing: root.appendingPathComponent("Other/note.md")) == nil)
        }
    }

    @Test func corruptedBookmarksDoNotGrantAccess() throws {
        try withStore { bookmarks, defaults, root in
            let file = root.appendingPathComponent("note.md")
            defaults.set([root.standardizedFileURL.path: Data("invalid".utf8)], forKey: "directoryBookmarks")
            #expect(bookmarks.resolve(root) == nil)
            #expect(bookmarks.resolveDirectory(containing: file) == nil)
        }
    }

    @Test func movedDirectoryBookmarkStillResolves() throws {
        try withStore { bookmarks, defaults, root in
            let original = root.appendingPathComponent("Original", isDirectory: true)
            let moved = root.appendingPathComponent("Moved", isDirectory: true)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            let location = try DocumentStore().create(name: "Notes", in: original)
            let data = try documentStoreImageData()
            let image = try DocumentStore().importImage(data: data, into: location)
            try DocumentStore().save(image.markdown, to: location)
            try bookmarks.remember(original)
            try FileManager.default.moveItem(at: original, to: moved)
            let reopened = SecurityScopedBookmarks(defaults: defaults)
            let resolved = try #require(reopened.resolve(original))
            #expect(resolved.standardizedFileURL == moved.standardizedFileURL)
            let file = try #require(reopened.resolveFile(location.markdownURL))
            let restored = DocumentLocation(markdownURL: file)
            let access = resolved.startAccessingSecurityScopedResource()
            defer { if access { resolved.stopAccessingSecurityScopedResource() } }
            #expect(try DocumentStore().read(restored) == image.markdown)
            #expect(try Data(contentsOf: restored.resourceURL(relativePath: image.relativePath)) == data)
        }
    }
}

private func documentStoreImageData(type: UTType = .png) throws -> Data {
    let pixels = Data([255, 32, 64, 255])
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

@Suite struct DocumentStorePortableTests {
    private func withDocument(_ body: (DocumentStore, DocumentLocation, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore()
        try body(store, store.create(name: "Original", in: root), root)
    }

    @Test func unicodeReferencesEscapesAndDeduplication() throws {
        try withDocument { store, location, root in
            let data = try documentStoreImageData()
            let local = location.directoryURL.appendingPathComponent("图 片(一).png")
            try data.write(to: local)
            let source = "中文😀 ![替代 *文字*][图]\r\n\r\n![再用](图%20片\\(一\\).png)\r\n\r\n[图]: <图%20片(一).png> \"标题\"\r\n"
            let images = try store.collectImages(source: source, in: location)
            #expect(images.count == 2)
            #expect(images[0].url == images[1].url)
            #expect(images[0].alt == "替代 文字")
            #expect((source as NSString).substring(with: images[0].range) == "![替代 *文字*][图]")
            let copy = try store.duplicate(location, source: source, name: "Copy", in: root)
            let rewritten = try store.read(copy)
            #expect(rewritten.hasPrefix("中文😀 ![替代 文字](images/"))
            #expect(rewritten.hasSuffix("[图]: <图%20片(一).png> \"标题\"\r\n"))
            let copied = try store.collectImages(source: rewritten, in: copy)
            #expect(copied.count == 2)
            #expect(copied[0].url == copied[1].url)
            #expect(copied[0].title == "标题")
            #expect(try Data(contentsOf: copied[0].url) == data)
            #expect(try FileManager.default.contentsOfDirectory(atPath: copy.imagesURL.path).count == 1)
        }
    }

    @Test func preservesStandardImagesAndCopiesOtherLocalImages() throws {
        try withDocument { store, location, root in
            let data = try documentStoreImageData()
            let nested = location.imagesURL.appendingPathComponent("子目录", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try data.write(to: nested.appendingPathComponent("图 像.png"))
            try data.write(to: location.imagesURL.appendingPathComponent("unused.png"))
            try data.write(to: location.directoryURL.appendingPathComponent("other.png"))
            let source = "![标准](<images/子目录/图 像.png>)\n![本地](other.png)\n`![忽略](missing.png)`"
            let copy = try store.duplicate(location, source: source, name: "Copy", in: root)
            let references = try store.collectImages(source: store.read(copy), in: copy)
            #expect(references.count == 2)
            #expect(references[0].url == copy.imagesURL.appendingPathComponent("子目录/图 像.png"))
            #expect(try Data(contentsOf: references[1].url) == data)
            #expect(try Data(contentsOf: copy.imagesURL.appendingPathComponent("unused.png")) == data)
        }
    }

    @Test func imageExportPreservesStandardLiteralPunctuation() throws {
        try withDocument { store, location, root in
            try documentStoreImageData().write(to: location.directoryURL.appendingPathComponent("image.png"))
            let source = "![\"straight\" -- --- ...](image.png \"caption -- ...\")\n"
            let images = try store.collectImages(source: source, in: location)
            #expect(images.count == 1)
            #expect(images.first?.alt == "\"straight\" -- --- ...")
            #expect(images.first?.title == "caption -- ...")
            let copy = try store.duplicate(location, source: source, name: "Copy", in: root)
            let copied = try store.collectImages(source: store.read(copy), in: copy)
            #expect(copied.first?.alt == images.first?.alt)
            #expect(copied.first?.title == images.first?.title)
        }
    }

    @Test func rejectsRemoteAndTraversalWithoutCreatingCopy() throws {
        try withDocument { store, location, root in
            for path in ["https://example.com/image.png", "http://example.com/image.png", "//example.com/image.png"] {
                #expect(throws: DocumentStoreError.externalRemoteResource) {
                    try store.duplicate(location, source: "![](\(path))", name: "Copy", in: root)
                }
            }
            for path in ["../outside.png", "%2e%2e/outside.png", "/tmp/outside.png", "file:///tmp/outside.png", "nested/../../outside.png"] {
                #expect(throws: DocumentStoreError.unsafePath) {
                    try store.duplicate(location, source: "![](\(path))", name: "Copy", in: root)
                }
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Copy").path))
        }
    }

    @Test func rejectsSymlinkMembersAndExternalReferences() throws {
        try withDocument { store, location, root in
            let outside = root.appendingPathComponent("outside.png")
            try documentStoreImageData().write(to: outside)
            let link = location.directoryURL.appendingPathComponent("link.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            #expect(throws: DocumentStoreError.unsafePath) {
                try store.duplicate(location, source: "![](link.png)", name: "Copy", in: root)
            }
            try FileManager.default.createDirectory(at: location.imagesURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: location.imagesURL.appendingPathComponent("hidden.png"), withDestinationURL: outside)
            #expect(throws: DocumentStoreError.unsafePath) {
                try store.duplicate(location, source: "no references", name: "Copy", in: root)
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Copy").path))
            try FileManager.default.removeItem(at: location.imagesURL)
            try FileManager.default.createSymbolicLink(at: location.imagesURL, withDestinationURL: root)
            #expect(throws: DocumentStoreError.unsafePath) {
                try store.duplicate(location, source: "no references", name: "Copy", in: root)
            }
        }
    }

    @Test func missingImageRollsBackAfterPartialCopy() throws {
        try withDocument { store, location, root in
            let imported = try store.importImage(data: documentStoreImageData(), into: location)
            #expect(throws: (any Error).self) {
                try store.duplicate(location, source: imported.markdown + "\n![](missing.png)", name: "Copy", in: root)
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Copy").path))
            #expect(try Data(contentsOf: imported.url) == documentStoreImageData())
        }
    }

    @Test func tiffBecomesPNGAndLeavesNoTemporaryFiles() throws {
        try withDocument { store, location, _ in
            let tiff = try documentStoreImageData(type: .tiff)
            let imported = try store.importImage(data: tiff, into: location)
            #expect(imported.url.pathExtension == "png")
            let output = try Data(contentsOf: imported.url)
            let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
            let second = try store.importImage(data: tiff, into: location)
            #expect(imported.url != second.url)
            let filenames = try FileManager.default.contentsOfDirectory(atPath: location.imagesURL.path)
            #expect(filenames.count == 2)
            #expect(!filenames.contains(where: { $0.hasPrefix(".") }))
        }
    }

    @Test func rejectsOversizedDataAndPixelBombBeforePublishing() throws {
        try withDocument { store, location, _ in
            #expect(throws: DocumentStoreError.imageTooLarge) {
                try store.importImage(data: Data(repeating: 0, count: 50 * 1024 * 1024 + 1), into: location)
            }
            let pixels = Data(repeating: 0, count: 1_251 * 10_000)
            let provider = try #require(CGDataProvider(data: pixels as CFData))
            let image = try #require(CGImage(width: 10_001, height: 10_000, bitsPerComponent: 1, bitsPerPixel: 1,
                                            bytesPerRow: 1_251, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let output = NSMutableData()
            let encoder = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(encoder, image, nil)
            #expect(CGImageDestinationFinalize(encoder))
            #expect(throws: DocumentStoreError.imageTooLarge) { try store.importImage(data: output as Data, into: location) }
            #expect(!FileManager.default.fileExists(atPath: location.imagesURL.path))
        }
    }

    @Test func publicationNeverOverwritesAndCleansUpOnCollision() throws {
        try withDocument { store, location, root in
            let original = Data("original".utf8)
            let target = location.directoryURL.appendingPathComponent("occupied.png")
            try original.write(to: target)
            #expect(throws: CocoaError(.fileWriteFileExists)) { try store.publish(Data("replacement".utf8), to: target) }
            #expect(try Data(contentsOf: target) == original)
            let outside = root.appendingPathComponent("outside.png")
            try original.write(to: outside)
            let symlink = location.directoryURL.appendingPathComponent("occupied-link.png")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
            #expect(throws: CocoaError(.fileWriteFileExists)) { try store.publish(Data("replacement".utf8), to: symlink) }
            #expect(try Data(contentsOf: outside) == original)
            #expect(!(try FileManager.default.contentsOfDirectory(atPath: location.directoryURL.path)).contains(where: { $0.hasPrefix(".image-") }))
        }
    }

    @Test func shortcutReferencesAndEscapedAltRemainImages() throws {
        try withDocument { store, location, root in
            try documentStoreImageData().write(to: location.directoryURL.appendingPathComponent("a&b.png"))
            let source = "😀 ![图]\r![图][]\r![括\\[号\\] \\*](a&amp;b.png)\r\r[图]: a&amp;b.png\r"
            let copy = try store.duplicate(location, source: source, name: "Copy", in: root)
            let rewritten = try store.read(copy)
            let collected = try store.collectImages(source: rewritten, in: copy)
            #expect(collected.count == 3)
            #expect(collected.map(\.alt) == ["图", "图", "括[号] *"])
            #expect(Set(collected.map(\.url)).count == 1)
            #expect(rewritten.hasPrefix("😀 ![图](images/"))
        }
    }

    @Test func percentEncodedReservedCharactersAreLocalFilenames() throws {
        try withDocument { store, location, root in
            try FileManager.default.createDirectory(at: location.imagesURL, withIntermediateDirectories: true)
            let filename = "图#?%.png"
            let data = try documentStoreImageData()
            try data.write(to: location.imagesURL.appendingPathComponent(filename))
            let copy = try store.duplicate(location, source: "![图](images/图%23%3F%25.png)", name: "Copy", in: root)
            let images = try store.collectImages(source: store.read(copy), in: copy)
            #expect(images.count == 1)
            #expect(images[0].url.lastPathComponent == filename)
            #expect(try Data(contentsOf: images[0].url) == data)
        }
    }
}