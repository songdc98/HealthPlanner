import Foundation
import Combine

@MainActor
final class LocalizationManager: ObservableObject {
    @Published private(set) var language: AppLanguage

    private let languageKey = "preferredLanguage"

    init() {
        if let raw = UserDefaults.standard.string(forKey: languageKey),
           let lang = AppLanguage(rawValue: raw) {
            language = lang
        } else {
            language = .english
        }
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
    }

    func text(_ key: String) -> String {
        LocalizationCatalog.value(for: key, language: language)
    }

    func exerciseDisplayName(for exercise: ExerciseItem) -> String {
        let key = "exercise.\(exercise.id)"
        let localized = text(key)
        return localized == key ? exercise.displayName : localized
    }

    func suggestionType(_ type: SuggestionType) -> String {
        switch type {
        case .rest: return text("rec.type.rest")
        case .walk: return text("rec.type.walk")
        case .easyRun: return text("rec.type.easyRun")
        case .strength: return text("rec.type.strength")
        case .mobility: return text("rec.type.mobility")
        }
    }

    func intensity(_ intensity: RecommendationIntensity) -> String {
        switch intensity {
        case .low: return text("rec.intensity.low")
        case .moderate: return text("rec.intensity.moderate")
        case .high: return text("rec.intensity.high")
        }
    }

    func volume(_ tier: VolumeTier) -> String {
        switch tier {
        case .light: return text("rec.volume.light")
        case .moderate: return text("rec.volume.moderate")
        case .hard: return text("rec.volume.hard")
        }
    }

    func recommendationTitle(_ recommendation: DailyRecommendation) -> String {
        "\(text("rec.todayPrefix")): \(suggestionType(recommendation.type))"
    }

    func recommendationDetail(_ recommendation: DailyRecommendation) -> String {
        String(format: text("rec.detailFormat"), "\(recommendation.durationMinutes)", intensity(recommendation.intensity), volume(recommendation.volumeTier))
    }

    func recommendationExplanation(_ recommendation: DailyRecommendation) -> String {
        let focus = recommendation.targetFocus.map { muscleGroup($0) }.joined(separator: ", ")
        return String(format: text("rec.explanationFormat"), "\(recommendation.scores.recoveryScore)", "\(recommendation.scores.activationNeedScore)", "\(recommendation.scores.passiveRecoveryResponseScore)", focus)
    }

    func muscleGroup(_ group: MuscleGroup) -> String {
        switch group {
        case .chest: return text("muscle.chest")
        case .back: return text("muscle.back")
        case .biceps: return text("muscle.biceps")
        case .forearms: return text("muscle.forearms")
        case .quads: return text("muscle.quads")
        case .hamstrings: return text("muscle.hamstrings")
        case .glutes: return text("muscle.glutes")
        case .adductors: return text("muscle.adductors")
        case .calves: return text("muscle.calves")
        case .cardioSystemic: return text("muscle.cardioSystemic")
        }
    }

    func recoveryState(_ state: MuscleRecoveryState) -> String {
        switch state {
        case .fresh: return text("recovery.fresh")
        case .recovering: return text("recovery.recovering")
        case .fatigued: return text("recovery.fatigued")
        }
    }

    func statusText(_ state: HealthAuthorizationUIState) -> String {
        switch state {
        case .unknown:
            return text("status.unknown")
        case .requestAvailable:
            return text("status.request")
        case .configuredInHealthApp:
            return text("status.ready")
        case .loadFailed(let message):
            return "\(text("status.failed")): \(message)"
        }
    }

    func fallbackText(_ message: String) -> String {
        if message == "Physiological stress appears elevated today. Prefer recovery activity." {
            return text("fallback.safetyStress")
        }
        if message == "No samples returned" {
            return text("fallback.noSamples")
        }
        if message == "Permission may be configured but this metric has no recent entries" {
            return text("fallback.noRecent")
        }
        if message.hasPrefix("Query failed:") {
            let suffix = message.replacingOccurrences(of: "Query failed:", with: "").trimmingCharacters(in: .whitespaces)
            return "\(text("fallback.queryFailed")): \(suffix)"
        }
        return message
    }

    func passiveSummary(_ summary: String) -> String {
        if summary == "Body responded well to recent training" {
            return language == .simplifiedChinese ? "身体对近期训练反应良好" : summary
        }
        if summary == "Neutral physiological response" {
            return language == .simplifiedChinese ? "生理反应中性" : summary
        }
        if summary == "Recovery response suggests extra caution" {
            return language == .simplifiedChinese ? "恢复响应提示需要更谨慎" : summary
        }
        return summary
    }

    func effort(_ effort: PerceivedEffort) -> String {
        switch effort {
        case .tooEasy:
            return language == .simplifiedChinese ? "太轻松" : "Too easy"
        case .good:
            return language == .simplifiedChinese ? "刚好" : "Good"
        case .tooHard:
            return language == .simplifiedChinese ? "太难" : "Too hard"
        }
    }

    func trainingGoal(_ goal: TrainingGoal) -> String {
        switch goal {
        case .generalHealth:
            return language == .simplifiedChinese ? "健康优先" : "General Health"
        case .fatLoss:
            return language == .simplifiedChinese ? "减脂" : "Fat Loss"
        case .muscleGain:
            return language == .simplifiedChinese ? "增肌" : "Muscle Gain"
        }
    }

    func experience(_ value: TrainingExperience) -> String {
        switch value {
        case .beginner:
            return language == .simplifiedChinese ? "初学" : "Beginner"
        case .intermediate:
            return language == .simplifiedChinese ? "中级" : "Intermediate"
        case .advanced:
            return language == .simplifiedChinese ? "高级" : "Advanced"
        }
    }

    func biologicalSex(_ value: BiologicalSex) -> String {
        switch value {
        case .female:
            return language == .simplifiedChinese ? "女性" : "Female"
        case .male:
            return language == .simplifiedChinese ? "男性" : "Male"
        case .nonBinary:
            return language == .simplifiedChinese ? "非二元" : "Non-binary"
        case .preferNotToSay:
            return language == .simplifiedChinese ? "不愿透露" : "Prefer not to say"
        }
    }

    func exerciseCategory(_ value: ExerciseCategory) -> String {
        switch value {
        case .walking:
            return language == .simplifiedChinese ? "步行" : "Walking"
        case .running:
            return language == .simplifiedChinese ? "跑步" : "Running"
        case .strength:
            return language == .simplifiedChinese ? "力量" : "Strength"
        case .mobility:
            return language == .simplifiedChinese ? "灵活性" : "Mobility"
        }
    }

    func equipment(_ value: EquipmentType) -> String {
        switch value {
        case .none:
            return language == .simplifiedChinese ? "无需器械" : "None"
        case .gymMachine:
            return language == .simplifiedChinese ? "器械" : "Gym Machine"
        case .barbell:
            return language == .simplifiedChinese ? "杠铃" : "Barbell"
        case .pullUpBar:
            return language == .simplifiedChinese ? "单杠" : "Pull-up Bar"
        case .bodyweight:
            return language == .simplifiedChinese ? "自重" : "Bodyweight"
        case .other:
            return language == .simplifiedChinese ? "其他" : "Other"
        }
    }
}
