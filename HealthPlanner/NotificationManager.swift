import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    private let morningKey = "lastMorningNotificationDay"
    private let eveningKey = "lastEveningNotificationDay"

    func requestPermission() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("[Notification] permission request failed: \(error.localizedDescription)")
        }
    }

    func scheduleEveningReminderIfNeeded(
        recommendation: DailyRecommendation,
        routine: RoutineRecommendation,
        snapshot: DailyHealthSnapshot,
        completedToday: Bool,
        restSuppressed: Bool,
        notificationsEnabled: Bool,
        now: Date = Date()
    ) {
        guard notificationsEnabled else { return }
        guard !restSuppressed else { return }
        let dayKey = Self.dayKey(for: now)
        guard UserDefaults.standard.string(forKey: eveningKey) != dayKey else { return }

        if completedToday {
            clearEveningReminder()
            print("[Notification] skip reminder because session already completed")
            return
        }

        let hour = Calendar.current.component(.hour, from: now)
        guard hour < 22 else {
            print("[Notification] skip reminder because it is too late")
            return
        }

        let lowActivity = (snapshot.stepCountToday ?? 0) < 6500
        guard lowActivity || recommendation.type != .rest else {
            print("[Notification] skip reminder due to enough activity")
            return
        }

        let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "preferredLanguage") ?? "en") ?? .english
        let typeText = LocalizationCatalog.value(for: recommendationTypeKey(recommendation.type), language: language)
        let routineText = localizedRoutinePriority(routine.priority, language: language)

        let content = UNMutableNotificationContent()
        content.title = language == .simplifiedChinese ? "健康训练计划" : "HealthPlanner"
        content.body = language == .simplifiedChinese
            ? "今晚建议：\(routineText)。可进行\(typeText)，约\(recommendation.durationMinutes)分钟。"
            : "Evening plan: \(routineText). Try a \(typeText.lowercased()) session for about \(recommendation.durationMinutes) min."
        content.sound = .default

        let trigger: UNNotificationTrigger
        if hour < 18 {
            var components = DateComponents()
            components.hour = 18
            components.minute = 0
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5 * 60, repeats: false)
        }

        let request = UNNotificationRequest(identifier: "healthplanner-evening-reminder", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Notification] add request failed: \(error.localizedDescription)")
            } else {
                print("[Notification] evening reminder scheduled")
                UserDefaults.standard.set(dayKey, forKey: self.eveningKey)
            }
        }
    }

    func clearEveningReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["healthplanner-evening-reminder"])
    }

    func scheduleMorningSummaryIfNeeded(
        recommendation: DailyRecommendation,
        routine: RoutineRecommendation,
        notificationsEnabled: Bool,
        now: Date = Date()
    ) {
        guard notificationsEnabled else { return }
        let hour = Calendar.current.component(.hour, from: now)
        guard hour >= 6 && hour <= 11 else { return }
        let dayKey = Self.dayKey(for: now)
        guard UserDefaults.standard.string(forKey: morningKey) != dayKey else { return }

        let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "preferredLanguage") ?? "en") ?? .english
        let typeText = LocalizationCatalog.value(for: recommendationTypeKey(recommendation.type), language: language)
        let routineText = localizedRoutinePriority(routine.priority, language: language)

        let content = UNMutableNotificationContent()
        content.title = language == .simplifiedChinese ? "晨间健康摘要" : "Morning Health Summary"
        content.body = language == .simplifiedChinese
            ? "今日建议：\(typeText)。作息方向：\(routineText)。"
            : "Today's recommendation: \(typeText). Routine focus: \(routineText)."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 4, repeats: false)
        let request = UNNotificationRequest(identifier: "healthplanner-morning-summary", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Notification] morning summary failed: \(error.localizedDescription)")
            } else {
                print("[Notification] morning summary scheduled")
                UserDefaults.standard.set(dayKey, forKey: self.morningKey)
            }
        }
    }

    private func recommendationTypeKey(_ type: SuggestionType) -> String {
        switch type {
        case .rest: return "rec.type.rest"
        case .walk: return "rec.type.walk"
        case .easyRun: return "rec.type.easyRun"
        case .strength: return "rec.type.strength"
        case .mobility: return "rec.type.mobility"
        }
    }

    private func localizedRoutinePriority(_ priority: RoutinePriority, language: AppLanguage) -> String {
        switch priority {
        case .restTonight:
            return language == .simplifiedChinese ? "优先恢复休息" : "Prioritize recovery rest"
        case .lightTonight:
            return language == .simplifiedChinese ? "轻量活动即可" : "Keep activity light"
        case .normalTonight:
            return language == .simplifiedChinese ? "可保持常规活动" : "Normal activity is okay"
        }
    }

    private static func dayKey(for date: Date) -> String {
        let day = Calendar.current.startOfDay(for: date)
        return day.formatted(date: .numeric, time: .omitted)
    }
}
