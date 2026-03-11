import Foundation

enum LocalizationCatalog {
    static func value(for key: String, language: AppLanguage) -> String {
        let table = mergedTable
        guard let localized = table[key] else { return key }
        switch language {
        case .english:
            return localized.en
        case .simplifiedChinese:
            return localized.zh
        }
    }

    private static var mergedTable: [String: (en: String, zh: String)] {
        screenTable.merging(exerciseTable) { current, _ in current }
    }
}
