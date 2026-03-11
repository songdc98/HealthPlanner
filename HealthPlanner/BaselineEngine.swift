import Foundation

struct BaselineWindow {
    let recent7: Double?
    let rolling28: Double?
    let trend84: Double?
}

struct WorkoutBalanceSummary {
    let cardioSessions: Int
    let strengthSessions: Int
    let mobilitySessions: Int

    var totalSessions: Int {
        cardioSessions + strengthSessions + mobilitySessions
    }

    var summaryText: String {
        "Cardio \(cardioSessions) / Strength \(strengthSessions) / Mobility \(mobilitySessions)"
    }
}

struct PersonalBaseline {
    let sleep: BaselineWindow
    let restingHeartRate: BaselineWindow
    let hrv: BaselineWindow
    let steps: BaselineWindow
    let workoutFrequencyPerWeek28: Double
    let workoutBalance28: WorkoutBalanceSummary
    let muscleCoverageBalance28: [MuscleGroup: Int]

    static let empty = PersonalBaseline(
        sleep: BaselineWindow(recent7: nil, rolling28: nil, trend84: nil),
        restingHeartRate: BaselineWindow(recent7: nil, rolling28: nil, trend84: nil),
        hrv: BaselineWindow(recent7: nil, rolling28: nil, trend84: nil),
        steps: BaselineWindow(recent7: nil, rolling28: nil, trend84: nil),
        workoutFrequencyPerWeek28: 0,
        workoutBalance28: WorkoutBalanceSummary(cardioSessions: 0, strengthSessions: 0, mobilitySessions: 0),
        muscleCoverageBalance28: [:]
    )
}

enum BaselineEngine {
    static func compute(records: [StoredDailyRecord], sessions: [CompletedWorkoutSession], referenceDate: Date = Date()) -> PersonalBaseline {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: referenceDate)

        let baselineEnd = dayStart
        let start7 = calendar.date(byAdding: .day, value: -7, to: baselineEnd) ?? referenceDate
        let start28 = calendar.date(byAdding: .day, value: -28, to: baselineEnd) ?? referenceDate
        let start84 = calendar.date(byAdding: .day, value: -84, to: baselineEnd) ?? referenceDate

        let records7 = records.filter { $0.date >= start7 && $0.date < baselineEnd }
        let records28 = records.filter { $0.date >= start28 && $0.date < baselineEnd }
        let records84 = records.filter { $0.date >= start84 && $0.date < baselineEnd }

        let sessions28 = sessions.filter { $0.date >= start28 && $0.date < baselineEnd }

        return PersonalBaseline(
            sleep: BaselineWindow(
                recent7: median(records7.compactMap { $0.sleepHours }),
                rolling28: median(records28.compactMap { $0.sleepHours }),
                trend84: median(records84.compactMap { $0.sleepHours })
            ),
            restingHeartRate: BaselineWindow(
                recent7: median(records7.compactMap { $0.restingHeartRate }),
                rolling28: median(records28.compactMap { $0.restingHeartRate }),
                trend84: median(records84.compactMap { $0.restingHeartRate })
            ),
            hrv: BaselineWindow(
                recent7: median(records7.compactMap { $0.hrv }),
                rolling28: median(records28.compactMap { $0.hrv }),
                trend84: median(records84.compactMap { $0.hrv })
            ),
            steps: BaselineWindow(
                recent7: median(records7.compactMap { $0.steps }),
                rolling28: median(records28.compactMap { $0.steps }),
                trend84: median(records84.compactMap { $0.steps })
            ),
            workoutFrequencyPerWeek28: sessions28.isEmpty ? 0 : (Double(sessions28.count) / 4.0),
            workoutBalance28: workoutBalance(sessions: sessions28),
            muscleCoverageBalance28: muscleCoverage(sessions: sessions28)
        )
    }

    private static func workoutBalance(sessions: [CompletedWorkoutSession]) -> WorkoutBalanceSummary {
        var cardio = 0
        var strength = 0
        var mobility = 0

        for session in sessions {
            let categories = Set(session.exercises.compactMap { exercise in
                ExerciseCatalogStore.seedExerciseByID(exercise.exerciseID)?.category
            })
            if categories.contains(.strength) {
                strength += 1
            } else if categories.contains(.running) || categories.contains(.walking) {
                cardio += 1
            } else {
                mobility += 1
            }
        }

        return WorkoutBalanceSummary(cardioSessions: cardio, strengthSessions: strength, mobilitySessions: mobility)
    }

    private static func muscleCoverage(sessions: [CompletedWorkoutSession]) -> [MuscleGroup: Int] {
        var map: [MuscleGroup: Int] = [:]
        for session in sessions {
            for exercise in session.exercises {
                for group in exercise.muscleGroups {
                    map[group, default: 0] += 1
                }
            }
        }
        return map
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}
