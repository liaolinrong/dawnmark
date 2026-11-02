import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case portuguese = "pt-PT"
    case italian = "it"
    case dutch = "nl"
    case polish = "pl"
    case turkish = "tr"
    case indonesian = "id"

    public var nativeName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .brazilianPortuguese: "Português (Brasil)"
        case .portuguese: "Português (Portugal)"
        case .italian: "Italiano"
        case .dutch: "Nederlands"
        case .polish: "Polski"
        case .turkish: "Türkçe"
        case .indonesian: "Bahasa Indonesia"
        }
    }

    public static func resolve(preference: String = "system", preferredLanguages: [String]) -> AppLanguage {
        if let explicit = AppLanguage(rawValue: preference) { return explicit }
        for identifier in preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            if let exact = AppLanguage(rawValue: normalized) { return exact }
            let locale = Locale(identifier: normalized)
            let code = locale.language.languageCode?.identifier
            if code == "zh" {
                if locale.language.script?.identifier == "Hans" { return .simplifiedChinese }
                if locale.language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(locale.region?.identifier ?? "") {
                    return .traditionalChinese
                }
                return .simplifiedChinese
            }
            if code == "pt" { return locale.region?.identifier == "BR" ? .brazilianPortuguese : .portuguese }
            if let code, let matched = AppLanguage(rawValue: code) { return matched }
        }
        return .english
    }

    public static var current: AppLanguage {
        let preference = UserDefaults.standard.string(forKey: "language") ?? "system"
        return resolve(preference: preference, preferredLanguages: Locale.preferredLanguages)
    }

    public static func syncSystemInterfaceLanguage(preference: String, defaults: UserDefaults = .standard) {
        if let language = AppLanguage(rawValue: preference) {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}

public enum TextKey: String, CaseIterable, Sendable {
    case file, edit, format, insert, view, window, help, about, settings, purchase, restore, quit
    case newDocument, open, openRecent, clearRecent, close, save, saveAs, showInFinder
    case undo, redo, cut, copy, paste, selectAll, find, replace
    case headings, body, heading, inline, bold, italic, strike, inlineCode, lists, unordered, ordered, tasks, paragraph, quote, indent, outdent, clearFormat
    case link, image, table, codeBlock, rule, tableActions, addRow, deleteRow, addColumn, deleteColumn, deleteTable
    case richMode, sourceMode, minimize, zoom, bringAll, appHelp
    case untitled, create, documentName, chooseFolder, authorizeFolder, folderPermission, errorTitle, operationFailed, invalidName, alreadyExists, invalidImage, unsafePath
    case linkAddress, cancel, confirm, columns, rows, trialStart, trialDisclosure, priceUnavailable, buy, lifetime, checking, notStarted, trialStatus, unlocked, expired, pending, purchaseFailed, restoreSuccess, restoreEmpty
    case general, appearance, system, light, dark, language, english, chinese, spellcheck, defaultMode, version, copyright, readonly, edited, documentStatus, helpContent, unsupportedEdit
    case saveChanges, discard, unsavedChanges, resourceWarning, missingImage, collectImages, collected
    case imageTooLarge, imageImportCancelled, retry
    case outline, untitledHeading
    case languageRestartTitle, languageRestartMessage, acknowledge
    case listIndentOnly
}

public enum L10n {
    public static let tables: [AppLanguage: [String: String]] = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map { language in
        guard let url = Bundle.module.url(forResource: language.rawValue, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            preconditionFailure("Missing localization resource: \(language.rawValue)")
        }
        return (language, values)
    })

    public static func text(_ key: TextKey, language: AppLanguage = .current) -> String {
        guard let value = tables[language]?[key.rawValue] else {
            preconditionFailure("Missing localization: \(language.rawValue).\(key.rawValue)")
        }
        return value
    }

    public static func format(_ key: TextKey, _ arguments: CVarArg..., language: AppLanguage = .current) -> String {
        String(format: text(key, language: language), locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
}