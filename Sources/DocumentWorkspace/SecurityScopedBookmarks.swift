import Foundation

@MainActor public final class SecurityScopedBookmarks {
    public static let shared = SecurityScopedBookmarks()
    private let defaults: UserDefaults
    private let key = "directoryBookmarks"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func remember(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        bookmarks[url.standardizedFileURL.path] = data
        defaults.set(bookmarks, forKey: key)
    }

    public func resolve(_ url: URL) -> URL? {
        guard let bookmarks = defaults.dictionary(forKey: key) as? [String: Data],
              let data = bookmarks[url.standardizedFileURL.path] else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            let access = resolved.startAccessingSecurityScopedResource()
            defer { if access { resolved.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                var updated = bookmarks
                updated[url.standardizedFileURL.path] = refreshed
                updated[resolved.standardizedFileURL.path] = refreshed
                defaults.set(updated, forKey: key)
            }
        }
        return resolved
    }

    public func resolveFile(_ url: URL) -> URL? {
        if let resolved = resolve(url) { return resolved }
        guard let directory = directoryAccess(containing: url) else { return nil }
        let components = url.standardizedFileURL.pathComponents.dropFirst(directory.original.pathComponents.count)
        return components.reduce(directory.resolved) { $0.appendingPathComponent($1) }
    }

    public func resolveDirectory(containing url: URL) -> URL? {
        directoryAccess(containing: url)?.resolved
    }

    private func directoryAccess(containing url: URL) -> (original: URL, resolved: URL)? {
        var path = (url.standardizedFileURL.path as NSString).deletingLastPathComponent
        while !path.isEmpty {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            if let resolved = resolve(directory) { return (directory, resolved) }
            if path == "/" { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }
}