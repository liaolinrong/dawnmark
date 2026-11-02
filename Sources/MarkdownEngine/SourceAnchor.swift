import Foundation

@MainActor public final class SourceAnchor {
    public private(set) var range: NSRange?
    private weak var session: DocumentSession?
    private var observerToken: UUID?
    private var previousSource: String

    public init(session: DocumentSession, range: NSRange) {
        self.session = session
        previousSource = session.source
        self.range = Self.isValid(range, in: session.source) ? range : nil
        if self.range != nil {
            observerToken = session.observeChanges { [weak self] session in
                self?.update(source: session.source)
            }
        }
    }

    public func stop() {
        if let observerToken {
            session?.removeObserver(observerToken)
            self.observerToken = nil
        }
    }

    deinit {
        if let observerToken {
            Task { @MainActor [weak session] in
                session?.removeObserver(observerToken)
            }
        }
    }

    private func update(source: String) {
        let previous = previousSource
        previousSource = source
        guard let range, !previous.utf16.elementsEqual(source.utf16) else { return }

        let oldCharacters = Array(previous)
        let newCharacters = Array(source)
        var prefixCount = 0
        var prefixLength = 0
        while prefixCount < min(oldCharacters.count, newCharacters.count),
              String(oldCharacters[prefixCount]).utf16.elementsEqual(String(newCharacters[prefixCount]).utf16) {
            prefixLength += String(oldCharacters[prefixCount]).utf16.count
            prefixCount += 1
        }
        var suffixCount = 0
        var suffixLength = 0
        while suffixCount < min(oldCharacters.count, newCharacters.count) - prefixCount {
            let oldCharacter = String(oldCharacters[oldCharacters.count - suffixCount - 1])
            let newCharacter = String(newCharacters[newCharacters.count - suffixCount - 1])
            guard oldCharacter.utf16.elementsEqual(newCharacter.utf16) else { break }
            suffixLength += oldCharacter.utf16.count
            suffixCount += 1
        }

        let editEnd = previous.utf16.count - suffixLength
        let delta = source.utf16.count - previous.utf16.count
        if editEnd <= range.location {
            self.range = NSRange(location: range.location + delta, length: range.length)
        } else if prefixLength < NSMaxRange(range) || (range.length == 0 && prefixLength <= range.location) {
            self.range = nil
            stop()
        }
        if let updatedRange = self.range, !Self.isValid(updatedRange, in: source) {
            self.range = nil
            stop()
        }
    }

    private static func isValid(_ range: NSRange, in source: String) -> Bool {
        let length = source.utf16.count
        guard range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location else { return false }
        let start = source.utf16.index(source.utf16.startIndex, offsetBy: range.location)
        let end = source.utf16.index(start, offsetBy: range.length)
        return start.samePosition(in: source.unicodeScalars) != nil
            && end.samePosition(in: source.unicodeScalars) != nil
    }
}