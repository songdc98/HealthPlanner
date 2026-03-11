import Foundation

struct PassiveRecoveryResponse: Codable, Identifiable {
    var id: UUID
    var sourceDate: Date
    var responseDate: Date
    var sleepDeltaPercent: Double
    var restingHRDeltaPercent: Double
    var hrvDeltaPercent: Double
    var stepsDeltaPercent: Double
    var recentLoadRatio: Double
    var hoursSinceLastWorkout: Double
    var score: Int
    var summary: String
}

struct PassiveRecoveryResponseSummary {
    var recentAverageScore: Int
    var lastResponse: PassiveRecoveryResponse?

    static let neutral = PassiveRecoveryResponseSummary(recentAverageScore: 50, lastResponse: nil)
}

enum PassiveRecoveryResponseEngine {
    static func evaluate(
        sourceRecord: StoredDailyRecord,
        responseSnapshot: DailyHealthSnapshot,
        baseline: PersonalBaseline,
        recentSessions: [CompletedWorkoutSession]
    ) -> PassiveRecoveryResponse {
        let sleepBaseline = baseline.sleep.rolling28 ?? max(1, sourceRecord.sleepHours ?? 7)
        let rhrBaseline = baseline.restingHeartRate.rolling28 ?? max(1, sourceRecord.restingHeartRate ?? 60)
        let hrvBaseline = baseline.hrv.rolling28 ?? max(1, sourceRecord.hrv ?? 35)
        let stepsBaseline = baseline.steps.rolling28 ?? max(1, sourceRecord.steps ?? 7000)

        let sleepDelta = percentDelta(current: responseSnapshot.lastNightSleepHours, baseline: sleepBaseline)
        let rhrDelta = -percentDelta(current: responseSnapshot.restingHeartRate, baseline: rhrBaseline)
        let hrvDelta = percentDelta(current: responseSnapshot.hrv, baseline: hrvBaseline)
        let stepsDelta = percentDelta(current: responseSnapshot.stepCountToday, baseline: stepsBaseline)

        let sevenDayLoad = recentSessions.suffix(7).reduce(0.0) { $0 + $1.completedVolumeScore }
        let baselineLoad = max(1.0, baseline.workoutFrequencyPerWeek28 * 2.0)
        let loadRatio = sevenDayLoad / baselineLoad

        let hoursSinceLastWorkout: Double
        if let latest = recentSessions.last?.date {
            hoursSinceLastWorkout = Date().timeIntervalSince(latest) / 3600.0
        } else {
            hoursSinceLastWorkout = 72
        }

        var composite = 50.0
        composite += sleepDelta * 0.35
        composite += rhrDelta * 0.30
        composite += hrvDelta * 0.30
        composite += stepsDelta * 0.15

        if loadRatio > 1.4 {
            composite -= 8
        } else if loadRatio < 0.7 {
            composite += 4
        }

        if hoursSinceLastWorkout < 18 {
            composite -= 5
        }

        let score = Int(clamp(composite, min: 10, max: 95).rounded())
        let summary = summaryText(score: score)

        return PassiveRecoveryResponse(
            id: UUID(),
            sourceDate: sourceRecord.date,
            responseDate: responseSnapshot.date,
            sleepDeltaPercent: sleepDelta,
            restingHRDeltaPercent: -rhrDelta,
            hrvDeltaPercent: hrvDelta,
            stepsDeltaPercent: stepsDelta,
            recentLoadRatio: loadRatio,
            hoursSinceLastWorkout: hoursSinceLastWorkout,
            score: score,
            summary: summary
        )
    }

    static func summarize(_ responses: [PassiveRecoveryResponse]) -> PassiveRecoveryResponseSummary {
        guard !responses.isEmpty else { return .neutral }
        let recent = Array(responses.suffix(7))
        let avg = Int((Double(recent.reduce(0) { $0 + $1.score }) / Double(recent.count)).rounded())
        return PassiveRecoveryResponseSummary(recentAverageScore: avg, lastResponse: responses.last)
    }

    private static func percentDelta(current: Double?, baseline: Double) -> Double {
        guard let current, baseline > 0 else { return 0 }
        return ((current - baseline) / baseline) * 100.0
    }

    private static func summaryText(score: Int) -> String {
        if score >= 65 { return "Body responded well to recent training" }
        if score >= 45 { return "Neutral physiological response" }
        return "Recovery response suggests extra caution" }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}
