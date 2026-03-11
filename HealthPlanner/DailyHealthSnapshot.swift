import Foundation

struct SleepHistoryEntry: Codable, Hashable {
    let date: Date
    let hours: Double
}

struct QuantityHistoryEntry: Codable, Hashable {
    let date: Date
    let value: Double
}

struct DailyValueRange: Codable, Hashable {
    let minimum: Double?
    let maximum: Double?
}

struct WorkoutSummary: Codable, Hashable {
    let type: String
    let date: Date
    let durationMinutes: Double
}

struct DailyHealthSnapshot {
    var date: Date
    var lastNightSleepHours: Double?
    var recentSleepHistory: [SleepHistoryEntry]
    var latestHeartRate: Double?
    var todayHeartRateRange: DailyValueRange
    var restingHeartRate: Double?
    var recentRestingHeartRateHistory: [QuantityHistoryEntry]
    var hrv: Double?
    var recentHRVHistory: [QuantityHistoryEntry]
    var stepCountToday: Double?
    var latestWorkout: WorkoutSummary?

    var latestWorkoutType: String? { latestWorkout?.type }
    var latestWorkoutDate: Date? { latestWorkout?.date }
    var latestWorkoutDurationMinutes: Double? { latestWorkout?.durationMinutes }

    static let empty = DailyHealthSnapshot(
        date: Date(),
        lastNightSleepHours: nil,
        recentSleepHistory: [],
        latestHeartRate: nil,
        todayHeartRateRange: DailyValueRange(minimum: nil, maximum: nil),
        restingHeartRate: nil,
        recentRestingHeartRateHistory: [],
        hrv: nil,
        recentHRVHistory: [],
        stepCountToday: nil,
        latestWorkout: nil
    )
}
