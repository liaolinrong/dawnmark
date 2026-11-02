import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

public enum DocumentStoreError: Error, Equatable {
    case invalidName
    case alreadyExists
    case invalidImage
    case unsafePath
    case externalRemoteResource
    case imageTooLarge
}

public struct DocumentLocation: Sendable, Equatable {
    public let markdownURL: URL
    public var directoryURL: URL { markdownURL.deletingLastPathComponent() }
    public var imagesURL: URL { directoryURL.appendingPathComponent("images", isDirectory: true) }

    public init(markdownURL: URL) { self.markdownURL = markdownURL }

    public func resourceURL(relativePath: String) throws -> URL {
          guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains(":"), !relativePath.contains("\\"),
              !relativePath.contains("\0"), !relativePath.split(separator: "/").contains("..") else {
            throw DocumentStoreError.unsafePath
        }
        let root = directoryURL.resolvingSymlinksInPath().standardizedFileURL
        let resolved = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else { throw DocumentStoreError.unsafePath }
        return resolved
    }
}

public struct ImportedImage: Sendable {
    public let url: URL
    public let relativePath: String
    public var markdown: String { "![](\(relativePath))" }
}

public struct DocumentStore: Sendable {
    public init() {}

    public func create(name: String, in parent: URL) throws -> DocumentLocation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\0") else {
            throw DocumentStoreError.invalidName
        }
        let directory = parent.appendingPathComponent(trimmed, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw DocumentStoreError.alreadyExists }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let location = DocumentLocation(markdownURL: directory.appendingPathComponent(trimmed + ".md"))
        do {
            try Data().write(to: location.markdownURL, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return location
    }

    public func read(_ location: DocumentLocation) throws -> String {
        try String(contentsOf: location.markdownURL, encoding: .utf8)
    }

    public func save(_ source: String, to location: DocumentLocation) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: location.markdownURL, options: .forReplacing, error: &coordinationError) { url in
            do { try Data(source.utf8).write(to: url, options: .atomic) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    public func importImage(data: Data, into location: DocumentLocation) throws -> ImportedImage {
        let (imageData, suffix) = try preparedImage(data)
        let images = try location.resourceURL(relativePath: "images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for _ in 0..<5 {
            let name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "." + suffix
            let destination = images.appendingPathComponent(name)
            do {
                try publish(imageData, to: destination)
                return ImportedImage(url: destination, relativePath: "images/" + name)
            } catch CocoaError.fileWriteFileExists { continue }
        }
        throw DocumentStoreError.alreadyExists
    }

    public func duplicate(_ location: DocumentLocation, source: String, name: String, in parent: URL) throws -> DocumentLocation {
        let references = try collectImages(source: source, in: location)
        let destination = try create(name: name, in: parent)
        do {
            var copied: [URL: String] = [:]
            for relativePath in try standardImagePaths(in: location) {
                let original = try location.resourceURL(relativePath: relativePath)
                let target = try destination.resourceURL(relativePath: relativePath)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try publish(try imageFileData(at: original, in: location), to: target)
                copied[original] = relativePath
            }
            var rewritten = source
            for reference in references.sorted(by: { $0.range.location > $1.range.location }) {
                let relativePath: String
                if let existing = copied[reference.url] {
                    relativePath = existing
                } else {
                    let imported = try importImage(data: imageFileData(at: reference.url, in: location), into: destination)
                    relativePath = imported.relativePath
                    copied[reference.url] = relativePath
                }
                guard let range = Range(reference.range, in: rewritten) else { throw DocumentStoreError.unsafePath }
                rewritten.replaceSubrange(range, with: reference.markdown(relativePath: relativePath))
            }
            try save(rewritten, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination.directoryURL)
            throw error
        }
    }

    private func preparedImage(_ data: Data) throws -> (Data, String) {
        guard data.count <= 50 * 1024 * 1024 else { throw DocumentStoreError.imageTooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image),
              let suffix = type.preferredFilenameExtension else { throw DocumentStoreError.invalidImage }
        var totalPixels: Double = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw DocumentStoreError.invalidImage
            }
            let pixels = width.doubleValue * height.doubleValue
            guard width.doubleValue > 0, height.doubleValue > 0,
                  pixels.isFinite, pixels <= 100_000_000 else { throw DocumentStoreError.imageTooLarge }
            totalPixels += pixels
            guard totalPixels <= 100_000_000 else { throw DocumentStoreError.imageTooLarge }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DocumentStoreError.invalidImage }
        guard type.conforms(to: .tiff) else { return (data, suffix) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw DocumentStoreError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DocumentStoreError.invalidImage }
        guard output.length <= 50 * 1024 * 1024 else { throw DocumentStoreError.imageTooLarge }
        return (output as Data, "png")
    }

    private func imageFileData(at url: URL, in location: DocumentLocation) throws -> Data {
        let root = location.directoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw DocumentStoreError.unsafePath }
        let components = url.path.dropFirst(root.path.count + 1).split(separator: "/")
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = openat(descriptor, String(component), flags)
            guard next >= 0 else {
                if errno == ELOOP || errno == ENOTDIR { throw DocumentStoreError.unsafePath }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            close(descriptor)
            descriptor = next
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw DocumentStoreError.unsafePath }
        let limit = 50 * 1024 * 1024
        guard metadata.st_size >= 0, metadata.st_size <= limit else { throw DocumentStoreError.imageTooLarge }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var result = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - result.count)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= limit else { throw DocumentStoreError.imageTooLarge }
        }
        return result
    }

    func publish(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".image-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.close()
        let result = temporary.withUnsafeFileSystemRepresentation { temporaryPath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(temporaryPath!, destinationPath!, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            if errno == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func standardImagePaths(in location: DocumentLocation) throws -> [String] {
        let images = try location.resourceURL(relativePath: "images")
        guard FileManager.default.fileExists(atPath: images.path) else { return [] }
        var paths: [String] = []
        func visit(_ directory: URL, prefix: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) {
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw DocumentStoreError.unsafePath }
                let relative = prefix + "/" + child.lastPathComponent
                _ = try location.resourceURL(relativePath: relative)
                if values.isDirectory == true { try visit(child, prefix: relative) }
                else if values.isRegularFile == true { paths.append(relative) }
                else { throw DocumentStoreError.unsafePath }
            }
        }
        try visit(images, prefix: "images")
        return paths.sorted()
    }
}