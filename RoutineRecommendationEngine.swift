import Foundation

enum RoutinePriority {
    case restTonight
    case lightTonight
    case normalTonight
}

struct RoutineRecommendation {
    let priority: RoutinePriority
    let bedtimeHour: Int
    let bedtimeMinute: Int
    let explanationKeys: [String]
    let weatherKey: String?
}

enum RoutineRecommendationEngine {
    static func generate(
        snapshot: DailyHealthSnapshot,
        baseline: PersonalBaseline,
        passiveScore: Int,
        latestRecommendation: DailyRecommendation,
        weather: WeatherContext?,
        now: Date = Date()
    ) -> RoutineRecommendation {
        var stressScore = 0.0
        var notes: [String] = []

        if let sleep = snapshot.lastNightSleepHours,
           let baseSleep = baseline.sleep.rolling28,
           baseSleep > 0 {
            let deviation = (sleep - baseSleep) / baseSleep
            if deviation < -0.18 {
                stressScore += 18
                notes.append("routine.reason.sleepLow")
            } else if deviation > 0.1 {
                stressScore -= 5
            }
        }

        if let rhr = snapshot.restingHeartRate,
           let baseRhr = baseline.restingHeartRate.rolling28,
           baseRhr > 0 {
            let delta = (rhr - baseRhr) / baseRhr
            if delta > 0.08 {
                stressScore += 16
                notes.append("routine.reason.rhrHigh")
            }
        }

        if let hrv = snapshot.hrv,
           let baseHrv = baseline.hrv.rolling28,
           baseHrv > 0 {
            let delta = (hrv - baseHrv) / baseHrv
            if delta < -0.12 {
                stressScore += 14
                notes.append("routine.reason.hrvLow")
            }
        }

        let expectedSteps = expectedStepsByHour(baseline: baseline.steps.rolling28 ?? 7000, date: now)
        if let steps = snapshot.stepCountToday, expectedSteps > 0 {
            let gap = (expectedSteps - steps) / expectedSteps
            if gap > 0.3 {
                stressScore += 4
                notes.append("routine.reason.lowActivity")
            }
        }

        if latestRecommendation.type == .strength && passiveScore < 45 {
            stressScore += 10
            notes.append("routine.reason.recentLoad")
        }

        if let weather {
            if weather.isBadForOutdoor {
                notes.append("routine.reason.weatherIndoor")
            }
            if weather.temperatureC >= 32 || weather.temperatureC <= 0 {
                stressScore += 5
                notes.append("routine.reason.tempExtreme")
            }
        }

        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 20 {
            stressScore += 3
        }

        let priority: RoutinePriority
        let bedtimeOffsetMinutes: Int
        if stressScore >= 28 {
            priority = .restTonight
            bedtimeOffsetMinutes = -45
        } else if stressScore >= 14 {
            priority = .lightTonight
            bedtimeOffsetMinutes = -20
        } else {
            priority = .normalTonight
            bedtimeOffsetMinutes = 0
        }

        let baseBedtime = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: now) ?? now
        let bedtime = Calendar.current.date(byAdding: .minute, value: bedtimeOffsetMinutes, to: baseBedtime) ?? baseBedtime
        let bedtimeHour = Calendar.current.component(.hour, from: bedtime)
        let bedtimeMinute = Calendar.current.component(.minute, from: bedtime)

        let summaryKeys = notes.isEmpty ? ["routine.reason.stable"] : Array(notes.prefix(2))
        let weatherKey = weather.map { w in
            w.isBadForOutdoor ? "routine.weather.bad" : "routine.weather.good"
        }

        return RoutineRecommendation(
            priority: priority,
            bedtimeHour: bedtimeHour,
            bedtimeMinute: bedtimeMinute,
            explanationKeys: summaryKeys,
            weatherKey: weatherKey
        )
    }

    private static func expectedStepsByHour(baseline: Double, date: Date) -> Double {
        let hour = Calendar.current.component(.hour, from: date)
        let progress = min(1.0, max(0.15, Double(hour) / 22.0))
        return baseline * progress
    }
}
