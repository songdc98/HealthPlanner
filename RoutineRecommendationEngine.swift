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
        let bedtimeAdjustmentMinutes: Int
        if stressScore >= 28 {
            priority = .restTonight
            bedtimeAdjustmentMinutes = -35
        } else if stressScore >= 14 {
            priority = .lightTonight
            bedtimeAdjustmentMinutes = -15
        } else {
            priority = .normalTonight
            bedtimeAdjustmentMinutes = 10
        }

        let bedtime = recommendedBedtime(
            snapshot: snapshot,
            baseline: baseline,
            passiveScore: passiveScore,
            latestRecommendation: latestRecommendation,
            stressScore: stressScore,
            priority: priority,
            bedtimeAdjustmentMinutes: bedtimeAdjustmentMinutes,
            now: now
        )
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

    private static func recommendedBedtime(
        snapshot: DailyHealthSnapshot,
        baseline: PersonalBaseline,
        passiveScore: Int,
        latestRecommendation: DailyRecommendation,
        stressScore: Double,
        priority: RoutinePriority,
        bedtimeAdjustmentMinutes: Int,
        now: Date
    ) -> Date {
        let calendar = Calendar.current

        let baselineSleep = baseline.sleep.rolling28 ?? baseline.sleep.recent7 ?? 7.8
        let lastNightSleep = snapshot.lastNightSleepHours ?? baselineSleep
        let sleepDebtHours = max(0, baselineSleep - lastNightSleep)

        var targetSleepHours = baselineSleep
        targetSleepHours += min(1.4, sleepDebtHours * 0.75)
        targetSleepHours += passiveScore < 45 ? 0.35 : 0
        targetSleepHours += stressScore >= 28 ? 0.35 : 0
        targetSleepHours += latestRecommendation.type == .strength ? 0.15 : 0

        switch priority {
        case .restTonight:
            targetSleepHours += 0.25
        case .lightTonight:
            break
        case .normalTonight:
            targetSleepHours -= 0.15
        }

        targetSleepHours = clamp(targetSleepHours, min: 7.1, max: 9.6)

        let wakeTarget = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: now) ?? now
        let nextWakeTarget: Date
        if wakeTarget <= now {
            nextWakeTarget = calendar.date(byAdding: .day, value: 1, to: wakeTarget) ?? wakeTarget
        } else {
            nextWakeTarget = wakeTarget
        }

        var bedtime = calendar.date(
            byAdding: .minute,
            value: -Int((targetSleepHours * 60).rounded()),
            to: nextWakeTarget
        ) ?? nextWakeTarget
        bedtime = calendar.date(byAdding: .minute, value: bedtimeAdjustmentMinutes, to: bedtime) ?? bedtime

        if let workoutDate = snapshot.latestWorkoutDate,
           calendar.isDate(workoutDate, inSameDayAs: now) {
            let hoursSinceWorkout = now.timeIntervalSince(workoutDate) / 3600.0
            if hoursSinceWorkout < 2.5 {
                bedtime = calendar.date(byAdding: .minute, value: 20, to: bedtime) ?? bedtime
            } else if hoursSinceWorkout < 4 {
                bedtime = calendar.date(byAdding: .minute, value: 10, to: bedtime) ?? bedtime
            }
        }

        let earliest = calendar.date(bySettingHour: 21, minute: 15, second: 0, of: now) ?? now
        let latest = calendar.date(bySettingHour: 0, minute: 45, second: 0, of: now) ?? now
        let latestTonight = latest <= earliest ? calendar.date(byAdding: .day, value: 1, to: latest) ?? latest : latest
        let earliestTonight = earliest <= now ? earliest : earliest

        let minimumLeadMinutes: Int
        switch priority {
        case .restTonight:
            minimumLeadMinutes = 35
        case .lightTonight:
            minimumLeadMinutes = 45
        case .normalTonight:
            minimumLeadMinutes = 55
        }
        let earliestPractical = calendar.date(byAdding: .minute, value: minimumLeadMinutes, to: now) ?? now

        if bedtime < earliestTonight {
            bedtime = earliestTonight
        }
        if bedtime < earliestPractical {
            bedtime = earliestPractical
        }
        if bedtime > latestTonight {
            bedtime = latestTonight
        }

        let minute = calendar.component(.minute, from: bedtime)
        let roundedMinute = minute < 15 ? 0 : (minute < 45 ? 30 : 60)
        let rounded = calendar.date(
            bySettingHour: calendar.component(.hour, from: bedtime),
            minute: roundedMinute == 60 ? 0 : roundedMinute,
            second: 0,
            of: bedtime
        ) ?? bedtime

        if roundedMinute == 60 {
            return calendar.date(byAdding: .hour, value: 1, to: rounded) ?? rounded
        }
        return rounded
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}
