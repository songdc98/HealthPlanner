import Foundation

struct CompletedExerciseEntry: Codable, Hashable {
    var exerciseID: String
    var name: String
    var muscleGroups: [MuscleGroup]
    var sets: Int
    var reps: Int
    var loadKg: Double?
    var plannedSets: Int
    var plannedReps: Int
}

struct CompletedWorkoutSession: Codable, Identifiable {
    var id: UUID
    var date: Date
    var exercises: [CompletedExerciseEntry]
    var plannedVolumeScore: Double
    var completedVolumeScore: Double
    var sessionIntensity: RecommendationIntensity
    var perceivedDifficulty: PerceivedEffort?

    var completionRatio: Double {
        guard plannedVolumeScore > 0 else { return 1 }
        return completedVolumeScore / plannedVolumeScore
    }
}

enum MuscleRecoveryState: String {
    case fresh = "Fresh"
    case recovering = "Recovering"
    case fatigued = "Fatigued"
}

struct MuscleRecoveryStatus {
    var score: Int
    var state: MuscleRecoveryState
    var lastTrainedDate: Date?
}

enum MuscleRecoveryEngine {
    static func buildRecoveryMap(
        sessions: [CompletedWorkoutSession],
        experience: TrainingExperience,
        passiveResponseSummary: PassiveRecoveryResponseSummary,
        referenceDate: Date = Date()
    ) -> [MuscleGroup: MuscleRecoveryStatus] {
        var fatigueByGroup: [MuscleGroup: Double] = [:]
        var lastTrainedByGroup: [MuscleGroup: Date] = [:]

        for session in sessions {
            let hoursSince = max(0.0, referenceDate.timeIntervalSince(session.date) / 3600.0)
            let halfLife = recoveryHalfLifeHours(for: experience)
            let decay = exp(-log(2.0) * (hoursSince / halfLife))

            let intensityFactor: Double
            switch session.sessionIntensity {
            case .low:
                intensityFactor = 0.75
            case .moderate:
                intensityFactor = 1.0
            case .high:
                intensityFactor = 1.3
            }

            let completionFactor = clamp(session.completionRatio, min: 0.4, max: 1.4)
            let responseFactor = responseMultiplier(summary: passiveResponseSummary)
            let sessionFatigue = session.completedVolumeScore * intensityFactor * completionFactor * decay * responseFactor

            var touchedGroups = Set<MuscleGroup>()
            for exercise in session.exercises {
                for group in exercise.muscleGroups {
                    touchedGroups.insert(group)
                }
            }

            for group in touchedGroups {
                fatigueByGroup[group, default: 0] += sessionFatigue
                if let existing = lastTrainedByGroup[group] {
                    if session.date > existing {
                        lastTrainedByGroup[group] = session.date
                    }
                } else {
                    lastTrainedByGroup[group] = session.date
                }
            }
        }

        var result: [MuscleGroup: MuscleRecoveryStatus] = [:]
        for group in MuscleGroup.allCases {
            let fatigue = fatigueByGroup[group, default: 0]
            let score = Int(clamp(100.0 - fatigue * 12.0, min: 10, max: 100).rounded())
            let state: MuscleRecoveryState
            if score >= 76 {
                state = .fresh
            } else if score >= 46 {
                state = .recovering
            } else {
                state = .fatigued
            }
            result[group] = MuscleRecoveryStatus(score: score, state: state, lastTrainedDate: lastTrainedByGroup[group])
        }

        return result
    }

    private static func recoveryHalfLifeHours(for experience: TrainingExperience) -> Double {
        switch experience {
        case .beginner:
            return 54
        case .intermediate:
            return 44
        case .advanced:
            return 36
        }
    }

    private static func responseMultiplier(summary: PassiveRecoveryResponseSummary) -> Double {
        if summary.recentAverageScore < 40 { return 1.12 }
        if summary.recentAverageScore > 65 { return 0.92 }
        return 1.0
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}
