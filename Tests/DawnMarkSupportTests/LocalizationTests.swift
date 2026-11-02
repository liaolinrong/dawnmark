import Foundation
import Testing
@testable import DawnMarkSupport

@Test func visualEditingNamesAreLocalizedAndHelpUsesUpdatedTerminology() {
    let expected: [AppLanguage: String] = [
        .english: "Visual Editing", .simplifiedChinese: "可视化编辑", .traditionalChinese: "視覺化編輯",
        .japanese: "見たまま編集", .korean: "보이는 대로 편집", .french: "Édition visuelle",
        .german: "Visuelle Bearbeitung", .spanish: "Edición visual", .italian: "Modifica visiva",
        .dutch: "Visuele bewerking", .polish: "Edycja wizualna", .turkish: "Görsel Düzenleme",
        .brazilianPortuguese: "Edição visual", .portuguese: "Edição visual", .indonesian: "Penyuntingan Visual"
    ]
    #expect(Set(expected.keys) == Set(AppLanguage.allCases))
    for language in AppLanguage.allCases {
        #expect(L10n.text(.richMode, language: language) == expected[language])
        #expect(L10n.text(.richMode, language: language) != L10n.text(.sourceMode, language: language))
    }
    for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese, .italian] {
        let help = L10n.text(.helpContent, language: language)
        #expect(help.lowercased().contains(L10n.text(.richMode, language: language).lowercased()))
        for oldName in ["WYSIWYG", "所见即所得", "所見即所得", "modifica visuale"] {
            #expect(!help.contains(oldName))
        }
    }
}

@Test func informationalAcknowledgementIsNotAnInsertAction() throws {
    for language in AppLanguage.allCases {
        #expect(!L10n.text(.acknowledge, language: language).isEmpty)
        #expect(L10n.text(.acknowledge, language: language) != L10n.text(.confirm, language: language))
    }
    #expect(L10n.text(.acknowledge, language: .simplifiedChinese) == "知道了")
    #expect(L10n.text(.confirm, language: .simplifiedChinese) == "插入")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let content = try String(contentsOf: root.appendingPathComponent("Sources/DawnMark/AuxiliaryViews.swift"), encoding: .utf8)
    #expect(content.contains("alert.addButton(withTitle: L10n.text(.acknowledge))"))
    #expect(!content.contains("alert.addButton(withTitle: L10n.text(.confirm))"))
}

@Test func systemInterfaceLanguageOnlyChangesTheAppPreferenceDomain() throws {
    let name = "DawnMark-LanguageTests-" + UUID().uuidString
    let otherName = "DawnMark-OtherAppTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    let other = try #require(UserDefaults(suiteName: otherName))
    defer { defaults.removePersistentDomain(forName: name); other.removePersistentDomain(forName: otherName) }
    let globalBefore = defaults.persistentDomain(forName: UserDefaults.globalDomain) as NSDictionary?
    other.set(["ja"], forKey: "AppleLanguages")
    defaults.set("preserved", forKey: "unrelated")
    for language in AppLanguage.allCases {
        AppLanguage.syncSystemInterfaceLanguage(preference: language.rawValue, defaults: defaults)
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String] == [language.rawValue])
        #expect(other.stringArray(forKey: "AppleLanguages") == ["ja"])
    }
    for preference in ["system", "invalid"] {
        defaults.set(["fr"], forKey: "AppleLanguages")
        AppLanguage.syncSystemInterfaceLanguage(preference: preference, defaults: defaults)
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
        #expect(defaults.string(forKey: "unrelated") == "preserved")
    }
    #expect(globalBefore == defaults.persistentDomain(forName: UserDefaults.globalDomain) as NSDictionary?)
    #expect(other.stringArray(forKey: "AppleLanguages") == ["ja"])
}

@Test func everyLanguageHasEveryKey() {
    let expected = Set(TextKey.allCases.map(\.rawValue))
    for language in AppLanguage.allCases {
        #expect(Set(L10n.tables[language]!.keys) == expected)
        #expect(L10n.tables[language]!.values.allSatisfy { !$0.isEmpty })
    }
}

@Test func deleteTableMenuIsLocalizedInEveryLanguage() throws {
    let expected: [AppLanguage: String] = [
        .english: "Delete Table", .simplifiedChinese: "删除表格", .traditionalChinese: "刪除表格",
        .japanese: "表を削除", .korean: "표 삭제", .french: "Supprimer le tableau",
        .german: "Tabelle löschen", .spanish: "Eliminar tabla", .brazilianPortuguese: "Excluir tabela",
        .portuguese: "Eliminar tabela", .italian: "Elimina tabella", .dutch: "Tabel verwijderen",
        .polish: "Usuń tabelę", .turkish: "Tabloyu Sil", .indonesian: "Hapus Tabel"
    ]
    #expect(Set(expected.keys) == Set(AppLanguage.allCases))
    for language in AppLanguage.allCases {
        #expect(L10n.text(.deleteTable, language: language) == expected[language])
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let menus = try String(contentsOf: root.appendingPathComponent("Sources/DawnMark/AppMenus.swift"), encoding: .utf8)
    #expect(menus.contains("command(format, .deleteTable, .tableDelete)"))
}

@Test func listIndentRestrictionExplainsBothModesInEveryLanguage() {
    for language in AppLanguage.allCases {
        let richMode = L10n.text(.richMode, language: language)
        let sourceMode = L10n.text(.sourceMode, language: language)
        let message = L10n.format(.listIndentOnly, richMode, sourceMode, language: language)
        #expect(message.contains(richMode))
        #expect(message.contains(sourceMode))
        #expect(!message.contains("%@"))
        #expect(message != L10n.text(.unsupportedEdit, language: language))
        if language != .english {
            #expect(L10n.text(.listIndentOnly, language: language) != L10n.text(.listIndentOnly, language: .english))
        }
    }
    #expect(L10n.format(.listIndentOnly, "可视化编辑", "Markdown 源码", language: .simplifiedChinese)
        == "可视化编辑模式仅支持列表项增加缩进，不支持非列表内容。请切换到Markdown 源码模式调整缩进。")
}

@Test func interpolationMatchesAcrossLanguages() throws {
    let regex = try NSRegularExpression(pattern: "%[@d]")
    for key in TextKey.allCases {
        let patterns = AppLanguage.allCases.map { language in
            let text = L10n.text(key, language: language)
            return regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map { (text as NSString).substring(with: $0.range) }
        }
        #expect(patterns.allSatisfy { $0 == patterns.first! })
    }
    for language in AppLanguage.allCases {
        #expect(L10n.format(.heading, 3, language: language).contains("3"))
        #expect(L10n.format(.buy, "$9.99", language: language).contains("$9.99"))
        #expect(L10n.format(.version, "1.0", "1", language: language).contains("1.0"))
        #expect(L10n.format(.documentStatus, "Notes", "Ready", language: language).contains("Notes"))
    }
}

@Test func languageResolution() {
    #expect(AppLanguage.allCases.count == 15)
    #expect(AppLanguage.resolve(preferredLanguages: ["de-DE"]) == .german)
    #expect(AppLanguage.resolve(preferredLanguages: ["ar-SA", "ja-JP"]) == .japanese)
    #expect(AppLanguage.resolve(preferredLanguages: ["ar", "he"]) == .english)
    #expect(AppLanguage.resolve(preferredLanguages: []) == .english)
    #expect(AppLanguage.resolve(preferredLanguages: ["zh-TW"]) == .traditionalChinese)
    #expect(AppLanguage.resolve(preferredLanguages: ["zh-HK"]) == .traditionalChinese)
    #expect(AppLanguage.resolve(preferredLanguages: ["zh-Hans-HK"]) == .simplifiedChinese)
    #expect(AppLanguage.resolve(preferredLanguages: ["zh-CN"]) == .simplifiedChinese)
    #expect(AppLanguage.resolve(preferredLanguages: ["pt_BR"]) == .brazilianPortuguese)
    #expect(AppLanguage.resolve(preferredLanguages: ["pt-PT"]) == .portuguese)
    #expect(AppLanguage.resolve(preference: "fr", preferredLanguages: ["en-US"]) == .french)
    #expect(Set(AppLanguage.allCases.map(\.nativeName)).count == 15)
}

@Test func everySupportedRegionalLanguageMatches() {
    let samples: [(String, AppLanguage)] = [
        ("en-AU", .english), ("zh-SG", .simplifiedChinese), ("zh-MO", .traditionalChinese),
        ("ja-JP", .japanese), ("ko-KR", .korean), ("fr-CA", .french), ("de-AT", .german),
        ("es-MX", .spanish), ("pt-BR", .brazilianPortuguese), ("pt", .portuguese),
        ("it-IT", .italian), ("nl-BE", .dutch), ("pl-PL", .polish), ("tr-TR", .turkish), ("id-ID", .indonesian)
    ]
    for (identifier, expected) in samples {
        #expect(AppLanguage.resolve(preferredLanguages: [identifier]) == expected)
        #expect(AppLanguage.resolve(preference: expected.rawValue, preferredLanguages: ["en"]) == expected)
    }
    #expect(AppLanguage.resolve(preference: "invalid", preferredLanguages: ["ru-RU"]) == .english)
}

@Test func appAndProductsDeclareAllFifteenLanguages() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Configuration/Info.plist")), format: nil) as? [String: Any])
    let expected = Set(AppLanguage.allCases.map(\.rawValue))
    #expect(Set(try #require(info["CFBundleLocalizations"] as? [String])) == expected)
    let configuration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Configuration/DawnMark.storekit"))) as? [String: Any])
    let products = try #require(configuration["products"] as? [[String: Any]])
    #expect(products.count == 2)
    for product in products {
        let entries = try #require(product["localizations"] as? [[String: String]])
        #expect(entries.count == 15)
        let languages = try entries.map { entry in
            let locale = try #require(entry["locale"])
            #expect(entry["displayName"]?.isEmpty == false)
            #expect(entry["description"]?.isEmpty == false)
            return AppLanguage.resolve(preferredLanguages: [locale]).rawValue
        }
        #expect(Set(languages) == expected)
        if product["productID"] as? String == "com.liaolinrong.DawnMark.lifetime" {
            #expect(product["displayPrice"] as? String == "10.00")
        }
    }
}