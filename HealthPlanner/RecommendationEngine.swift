import Foundation

enum SuggestionType: String, Codable {
    case rest = "Rest"
    case walk = "Walk"
    case easyRun = "Easy Run"
    case strength = "Strength"
    case mobility = "Mobility"
}

enum RecommendationIntensity: String, Codable {
    case low = "Low"
    case moderate = "Moderate"
    case high = "High"
}

enum VolumeTier: String, Codable {
    case light = "Light"
    case moderate = "Moderate"
    case hard = "Hard"
}

struct RecommendationScores {
    let recoveryScore: Int
    let activationNeedScore: Int
    let trainingBalanceScore: Int
    let muscleReadinessScore: Int
    let confidenceScore: Int
    let passiveRecoveryResponseScore: Int
}

struct PlannedExercise: Codable, Hashable, Identifiable {
    var id: String { exerciseID + "-" + name }
    var exerciseID: String
    var name: String
    var targetMuscles: [MuscleGroup]
    var sets: Int?
    var reps: String?
    var loadGuidance: String?
    var restSeconds: Int?
    var durationMinutes: Int?
    var intensity: RecommendationIntensity
}

struct DailyRecommendation {
    let type: SuggestionType
    let targetFocus: [MuscleGroup]
    let exercises: [PlannedExercise]
    let durationMinutes: Int
    let intensity: RecommendationIntensity
    let explanation: String
    let confidenceLevel: Int
    let scores: RecommendationScores
    let scoreDrivers: [String]
    let safetyMessage: String?
    let volumeTier: VolumeTier

    var title: String {
        "Today: \(type.rawValue)"
    }

    var detail: String {
        "\(durationMinutes) min • \(intensity.rawValue) • \(volumeTier.rawValue)"
    }

    static let fallback = DailyRecommendation(
        type: .walk,
        targetFocus: [.cardioSystemic],
        exercises: [],
        durationMinutes: 20,
        intensity: .low,
        explanation: "Not enough data yet. Start with a short walk.",
        confidenceLevel: 35,
        scores: RecommendationScores(recoveryScore: 50, activationNeedScore: 40, trainingBalanceScore: 50, muscleReadinessScore: 50, confidenceScore: 35, passiveRecoveryResponseScore: 50),
        scoreDrivers: ["Fallback due to limited data"],
        safetyMessage: nil,
        volumeTier: .light
    )
}

enum RecommendationEngine {
    private enum TrainingFocusModule: String, CaseIterable {
        case chest
        case back
        case arms
        case lowerBody

        var groups: [MuscleGroup] {
            switch self {
            case .chest:
                return [.chest]
            case .back:
                return [.back]
            case .arms:
                return [.biceps, .forearms]
            case .lowerBody:
                return [.quads, .hamstrings, .glutes, .calves, .adductors]
            }
        }

        var representativeFocus: [MuscleGroup] {
            switch self {
            case .chest:
                return [.chest]
            case .back:
                return [.back]
            case .arms:
                return [.biceps, .forearms]
            case .lowerBody:
                return [.quads, .hamstrings, .glutes]
            }
        }
    }

    private struct AdaptiveTuning {
        let recoveryBias: Double
        let activationBias: Double
        let intensityBias: Double
        let volumeBias: Double
    }

    private struct NormalizedSignals {
        let sleep: Double
        let restingHR: Double
        let hrv: Double
        let stepsGap: Double
        let passive: Double
        let hoursSinceWorkout: Double
    }

    private struct CapabilityProfile {
        let aerobicCapacity: Double
        let upperPushStrength: Double
        let upperPullStrength: Double
        let lowerBodyStrength: Double
        let recoveryCapacity: Double
        let consistencyCapacity: Double
        let loadTolerance: Double
        let estimatedSessionMinutes: Int
    }

    static func generate(
        snapshot: DailyHealthSnapshot,
        baseline: PersonalBaseline,
        profile: UserProfile?,
        enabledExercises: [ExerciseItem],
        recoveryMap: [MuscleGroup: MuscleRecoveryStatus],
        history: [StoredDailyRecord],
        passiveSummary: PassiveRecoveryResponseSummary,
        now: Date = Date()
    ) -> DailyRecommendation {
        var recovery = 50.0
        var activationNeed = 50.0
        var trainingBalance = 50.0
        var drivers: [String] = []

        let safetyMessage = safetyCheck(snapshot: snapshot, baseline: baseline)
        if let safetyMessage {
            return DailyRecommendation(
                type: .rest,
                targetFocus: [.cardioSystemic],
                exercises: [],
                durationMinutes: 20,
                intensity: .low,
                explanation: "Safety first: \(safetyMessage)",
                confidenceLevel: 84,
                scores: RecommendationScores(recoveryScore: 20, activationNeedScore: 20, trainingBalanceScore: 50, muscleReadinessScore: 25, confidenceScore: 84, passiveRecoveryResponseScore: passiveSummary.recentAverageScore),
                scoreDrivers: ["Safety layer suppressed hard training"],
                safetyMessage: safetyMessage,
                volumeTier: .light
            )
        }

        let signals = buildNormalizedSignals(snapshot: snapshot, baseline: baseline, passiveSummary: passiveSummary, now: now)
        let tuning = deriveAdaptiveTuning(history: history, passiveSummary: passiveSummary)
        let capability = buildCapabilityProfile(profile)
        let allowedForGoal = enabledExercises.filter { exercise in
            let goal = profile?.goal ?? .generalHealth
            return exercise.suitabilityGoals.contains(goal)
        }

        recovery += signals.sleep * 14.0
        recovery += signals.restingHR * 16.0
        recovery += signals.hrv * 14.0
        recovery += signals.passive * 8.0
        recovery += tuning.recoveryBias

        activationNeed += signals.stepsGap * 16.0
        if signals.hoursSinceWorkout > 56 {
            activationNeed += 11
            drivers.append("No workout in >56h: +11 activation")
        } else if signals.hoursSinceWorkout < 18 {
            activationNeed -= 9
            drivers.append("Workout in <18h: -9 activation")
        }
        activationNeed += tuning.activationBias

        drivers.append("zSleep=\(signed(signals.sleep)) zRHR=\(signed(signals.restingHR)) zHRV=\(signed(signals.hrv)) zStepsGap=\(signed(signals.stepsGap))")
        drivers.append("Adaptive bias recovery=\(signed(tuning.recoveryBias)) activation=\(signed(tuning.activationBias)) intensity=\(signed(tuning.intensityBias)) volume=\(signed(tuning.volumeBias))")
        drivers.append("Capability aerobic=\(signed(capability.aerobicCapacity - 50)) push=\(signed(capability.upperPushStrength - 50)) pull=\(signed(capability.upperPullStrength - 50)) lower=\(signed(capability.lowerBodyStrength - 50)) recovery=\(signed(capability.recoveryCapacity - 50))")

        trainingBalance += trainingBalanceAdjustment(
            baseline: baseline,
            enabledExercises: allowedForGoal,
            drivers: &drivers
        )

        applyCapabilityAdjustments(
            capability: capability,
            profile: profile,
            recovery: &recovery,
            activationNeed: &activationNeed,
            drivers: &drivers
        )

        applyGoalAndOptionalManualFeedback(
            profile: profile,
            history: history,
            passiveSummary: passiveSummary,
            recovery: &recovery,
            activationNeed: &activationNeed,
            drivers: &drivers
        )

        recovery = clamp(recovery, min: 0, max: 100)
        activationNeed = clamp(activationNeed, min: 0, max: 100)
        trainingBalance = clamp(trainingBalance, min: 0, max: 100)

        let recommendedType = chooseType(
            recovery: recovery,
            activationNeed: activationNeed,
            trainingBalance: trainingBalance,
            hour: Calendar.current.component(.hour, from: now),
            enabledExercises: allowedForGoal,
            capability: capability,
            profile: profile
        )

        let targetFocus = chooseTargetFocus(
            recommendationType: recommendedType,
            enabledExercises: allowedForGoal,
            baseline: baseline
        )

        let muscleReadiness = muscleReadinessScore(for: targetFocus, recoveryMap: recoveryMap)
        let intensity = chooseIntensity(
            recovery: recovery,
            activationNeed: activationNeed,
            muscleReadiness: Double(muscleReadiness),
            passiveScore: passiveSummary.recentAverageScore,
            bias: tuning.intensityBias,
            capability: capability,
            recommendationType: recommendedType
        )
        let volumeTier = chooseVolumeTier(
            recovery: recovery,
            muscleReadiness: Double(muscleReadiness),
            passiveScore: passiveSummary.recentAverageScore,
            experience: profile?.experience ?? .beginner,
            bias: tuning.volumeBias,
            capability: capability,
            recommendationType: recommendedType
        )

        let exercises = buildExercisePlan(
            recommendationType: recommendedType,
            targetFocus: targetFocus,
            enabledExercises: allowedForGoal,
            intensity: intensity,
            volumeTier: volumeTier,
            profile: profile,
            capability: capability
        )

        let duration = plannedDurationMinutes(
            recommendationType: recommendedType,
            exercises: exercises,
            volumeTier: volumeTier,
            capability: capability,
            profile: profile
        )
        let confidence = computeConfidence(snapshot: snapshot, baseline: baseline, enabledExercises: allowedForGoal, passiveSummary: passiveSummary)

        let scores = RecommendationScores(
            recoveryScore: Int(recovery.rounded()),
            activationNeedScore: Int(activationNeed.rounded()),
            trainingBalanceScore: Int(trainingBalance.rounded()),
            muscleReadinessScore: muscleReadiness,
            confidenceScore: confidence,
            passiveRecoveryResponseScore: passiveSummary.recentAverageScore
        )

        let explanation = buildExplanation(type: recommendedType, goal: profile?.goal ?? .generalHealth, scores: scores, targetFocus: targetFocus)

        logRecommendation(
            recommendationType: recommendedType,
            duration: duration,
            intensity: intensity,
            volumeTier: volumeTier,
            scores: scores,
            targetFocus: targetFocus,
            recoveryMap: recoveryMap,
            drivers: drivers,
            exercises: exercises
        )

        return DailyRecommendation(
            type: recommendedType,
            targetFocus: targetFocus,
            exercises: exercises,
            durationMinutes: duration,
            intensity: intensity,
            explanation: explanation,
            confidenceLevel: confidence,
            scores: scores,
            scoreDrivers: drivers,
            safetyMessage: nil,
            volumeTier: volumeTier
        )
    }

    private static func applyGoalAndOptionalManualFeedback(
        profile: UserProfile?,
        history: [StoredDailyRecord],
        passiveSummary: PassiveRecoveryResponseSummary,
        recovery: inout Double,
        activationNeed: inout Double,
        drivers: inout [String]
    ) {
        let goal = profile?.goal ?? .generalHealth
        switch goal {
        case .generalHealth:
            activationNeed += 2
            drivers.append("Goal=General Health: sustainable +2 activation")
        case .fatLoss:
            activationNeed += 8
            recovery -= 2
            drivers.append("Goal=Fat Loss: +8 activation, -2 recovery")
        case .muscleGain:
            recovery += 4
            drivers.append("Goal=Muscle Gain: +4 recovery")
        }

        if passiveSummary.recentAverageScore < 40 {
            recovery -= 10
            drivers.append("Passive response low: -10 recovery")
        } else if passiveSummary.recentAverageScore > 65 {
            recovery += 6
            drivers.append("Passive response strong: +6 recovery")
        }

        let effortVotes = Array(history.suffix(10)).compactMap { $0.perceivedEffort }
        if !effortVotes.isEmpty {
            let tooHardRatio = ratio(of: .tooHard, from: effortVotes)
            let tooEasyRatio = ratio(of: .tooEasy, from: effortVotes)

            if tooHardRatio > 0.35 {
                recovery -= 6
                drivers.append("Optional manual feedback too-hard trend: -6 recovery")
            }
            if tooEasyRatio > 0.35 {
                activationNeed += 6
                drivers.append("Optional manual feedback too-easy trend: +6 activation")
            }
        }
    }

    private static func buildNormalizedSignals(
        snapshot: DailyHealthSnapshot,
        baseline: PersonalBaseline,
        passiveSummary: PassiveRecoveryResponseSummary,
        now: Date
    ) -> NormalizedSignals {
        let sleepSignal = normalizedSignal(
            current: snapshot.lastNightSleepHours,
            baseline: baseline.sleep.rolling28,
            minScale: 0.6,
            baselineScaleRatio: 0.12,
            direction: .higherIsBetter
        )

        let restingSignal = normalizedSignal(
            current: snapshot.restingHeartRate,
            baseline: baseline.restingHeartRate.rolling28,
            minScale: 2.0,
            baselineScaleRatio: 0.08,
            direction: .lowerIsBetter
        )

        let hrvSignal = normalizedSignal(
            current: snapshot.hrv,
            baseline: baseline.hrv.rolling28,
            minScale: 4.0,
            baselineScaleRatio: 0.12,
            direction: .higherIsBetter
        )

        let baselineSteps = baseline.steps.rolling28 ?? 7000
        let expectedSteps = expectedStepsByCurrentHour(baselineSteps: baselineSteps, date: now)
        let stepsGapRaw = (expectedSteps - (snapshot.stepCountToday ?? expectedSteps)) / max(1, expectedSteps)
        let stepsGapSignal = clamp(stepsGapRaw * 1.7, min: -2.5, max: 2.5)

        let passiveSignal = clamp((Double(passiveSummary.recentAverageScore) - 50.0) / 15.0, min: -2.5, max: 2.5)

        let hoursSinceWorkout: Double
        if let lastWorkoutDate = snapshot.latestWorkoutDate {
            hoursSinceWorkout = now.timeIntervalSince(lastWorkoutDate) / 3600.0
        } else {
            hoursSinceWorkout = 72
        }

        return NormalizedSignals(
            sleep: sleepSignal,
            restingHR: restingSignal,
            hrv: hrvSignal,
            stepsGap: stepsGapSignal,
            passive: passiveSignal,
            hoursSinceWorkout: hoursSinceWorkout
        )
    }

    private enum SignalDirection {
        case higherIsBetter
        case lowerIsBetter
    }

    private static func normalizedSignal(
        current: Double?,
        baseline: Double?,
        minScale: Double,
        baselineScaleRatio: Double,
        direction: SignalDirection
    ) -> Double {
        guard let current, let baseline, baseline > 0 else { return 0 }
        let scale = max(minScale, abs(baseline) * baselineScaleRatio)
        let raw = (current - baseline) / scale
        switch direction {
        case .higherIsBetter:
            return clamp(raw, min: -2.5, max: 2.5)
        case .lowerIsBetter:
            return clamp(-raw, min: -2.5, max: 2.5)
        }
    }

    private static func deriveAdaptiveTuning(history: [StoredDailyRecord], passiveSummary: PassiveRecoveryResponseSummary) -> AdaptiveTuning {
        let recent = Array(history.suffix(21))
        guard !recent.isEmpty else {
            return AdaptiveTuning(recoveryBias: 0, activationBias: 0, intensityBias: 0, volumeBias: 0)
        }

        let efforts = recent.compactMap(\.perceivedEffort)
        let tooHardRatio = ratio(of: .tooHard, from: efforts)
        let tooEasyRatio = ratio(of: .tooEasy, from: efforts)
        let completionRate = Double(recent.filter { $0.completedRecommendation == true }.count) / Double(recent.count)
        let lowPassive = passiveSummary.recentAverageScore < 45
        let highPassive = passiveSummary.recentAverageScore > 62

        var recoveryBias = 0.0
        var activationBias = 0.0
        var intensityBias = 0.0
        var volumeBias = 0.0

        recoveryBias -= tooHardRatio * 8.0
        recoveryBias += tooEasyRatio * 4.0
        recoveryBias += highPassive ? 3.0 : 0.0
        recoveryBias -= lowPassive ? 4.0 : 0.0

        activationBias += (1.0 - completionRate) * 6.0
        activationBias += tooEasyRatio * 5.0
        activationBias -= tooHardRatio * 4.0

        intensityBias += tooEasyRatio * 9.0
        intensityBias -= tooHardRatio * 11.0
        intensityBias -= lowPassive ? 4.0 : 0.0

        volumeBias += tooEasyRatio * 7.0
        volumeBias -= tooHardRatio * 9.0
        volumeBias -= completionRate < 0.45 ? 3.0 : 0.0

        return AdaptiveTuning(
            recoveryBias: clamp(recoveryBias, min: -10, max: 10),
            activationBias: clamp(activationBias, min: -10, max: 10),
            intensityBias: clamp(intensityBias, min: -15, max: 12),
            volumeBias: clamp(volumeBias, min: -15, max: 12)
        )
    }

    private static func buildCapabilityProfile(_ profile: UserProfile?) -> CapabilityProfile {
        guard let profile else {
            return CapabilityProfile(
                aerobicCapacity: 50,
                upperPushStrength: 50,
                upperPullStrength: 50,
                lowerBodyStrength: 50,
                recoveryCapacity: 50,
                consistencyCapacity: 50,
                loadTolerance: 50,
                estimatedSessionMinutes: 24
            )
        }

        let bodyWeight = max(40.0, profile.weightKg)
        let bmi = profile.heightCm > 0 ? profile.weightKg / pow(profile.heightCm / 100.0, 2) : 22.0

        let aerobicFrom5K: Double
        if let minutes = profile.estimated5kMinutes, minutes > 0 {
            let normalized = (42.0 - minutes) / 17.0
            aerobicFrom5K = clamp(50 + normalized * 30, min: 28, max: 92)
        } else {
            aerobicFrom5K = 50
        }

        let pushFromPushUps = profile.maxPushUps.map { clamp(30 + Double($0) * 1.2, min: 25, max: 88) } ?? 50
        let pullFromPullUps = profile.maxPullUps.map { clamp(34 + Double($0) * 2.6, min: 24, max: 92) } ?? 48

        let relativeBench = profile.estimatedBenchPressKg.map { $0 / bodyWeight } ?? 0
        let relativeLat = profile.estimatedLatPulldownKg.map { $0 / bodyWeight } ?? 0
        let relativeSquat = profile.estimatedSquatKg.map { $0 / bodyWeight } ?? 0

        let benchScore = relativeBench > 0 ? clamp(36 + relativeBench * 28, min: 30, max: 92) : pushFromPushUps
        let pullScore = relativeLat > 0 ? clamp(36 + relativeLat * 24, min: 30, max: 92) : pullFromPullUps
        let lowerScore = relativeSquat > 0 ? clamp(36 + relativeSquat * 26, min: 32, max: 95) : 50

        let experienceAdjustment: Double
        switch profile.experience {
        case .beginner:
            experienceAdjustment = -6
        case .intermediate:
            experienceAdjustment = 4
        case .advanced:
            experienceAdjustment = 10
        }

        let ageAdjustment: Double
        if let age = profile.age {
            switch age {
            case ..<25:
                ageAdjustment = 3
            case 25...39:
                ageAdjustment = 1
            case 40...54:
                ageAdjustment = -3
            default:
                ageAdjustment = -7
            }
        } else {
            ageAdjustment = 0
        }

        let bmiAdjustment: Double
        if bmi < 19 {
            bmiAdjustment = -3
        } else if bmi > 30 {
            bmiAdjustment = -4
        } else {
            bmiAdjustment = 1
        }

        let hasStrengthData = profile.estimatedBenchPressKg != nil || profile.estimatedLatPulldownKg != nil || profile.estimatedSquatKg != nil
        let recoveryCapacity = clamp(52 + experienceAdjustment * 0.9 + ageAdjustment + bmiAdjustment, min: 30, max: 86)
        let consistencyCapacity = clamp(50 + experienceAdjustment * 0.8 + (profile.estimated5kMinutes != nil ? 4 : 0), min: 34, max: 86)
        let loadTolerance = clamp((recoveryCapacity + max(benchScore, pullScore) + lowerScore) / 3.0 + (hasStrengthData ? 4 : 0), min: 34, max: 90)
        let estimatedSessionMinutes = Int(clamp(24 + (consistencyCapacity - 50) * 0.22 + (aerobicFrom5K - 50) * 0.18, min: 18, max: 48).rounded())

        return CapabilityProfile(
            aerobicCapacity: clamp(aerobicFrom5K + experienceAdjustment * 0.6 + ageAdjustment * 0.5, min: 28, max: 92),
            upperPushStrength: clamp((benchScore * 0.6 + pushFromPushUps * 0.4) + experienceAdjustment * 0.7, min: 28, max: 94),
            upperPullStrength: clamp((pullScore * 0.65 + pullFromPullUps * 0.35) + experienceAdjustment * 0.7, min: 26, max: 94),
            lowerBodyStrength: clamp(lowerScore + experienceAdjustment * 0.7, min: 30, max: 95),
            recoveryCapacity: recoveryCapacity,
            consistencyCapacity: consistencyCapacity,
            loadTolerance: loadTolerance,
            estimatedSessionMinutes: estimatedSessionMinutes
        )
    }

    private static func applyCapabilityAdjustments(
        capability: CapabilityProfile,
        profile: UserProfile?,
        recovery: inout Double,
        activationNeed: inout Double,
        drivers: inout [String]
    ) {
        let recoveryShift = (capability.recoveryCapacity - 50.0) * 0.18
        let activationShift = (capability.consistencyCapacity - 50.0) * 0.12
        recovery += recoveryShift
        activationNeed += activationShift
        drivers.append("Profile recovery capacity: \(signed(recoveryShift)) recovery")
        drivers.append("Profile consistency capacity: \(signed(activationShift)) activation")

        if let age = profile?.age, age >= 50 {
            recovery -= 3
            drivers.append("Age >=50: -3 recovery")
        }
    }

    private static func chooseType(
        recovery: Double,
        activationNeed: Double,
        trainingBalance: Double,
        hour: Int,
        enabledExercises: [ExerciseItem],
        capability: CapabilityProfile,
        profile: UserProfile?
    ) -> SuggestionType {
        let categories = Set(enabledExercises.map { $0.category })

        if recovery < 32 {
            return categories.contains(.walking) ? .walk : .rest
        }
        if hour >= 22 {
            return .mobility
        }
        if trainingBalance > 58 && categories.contains(.strength) {
            return .strength
        }
        if activationNeed > 62 && categories.contains(.running) && capability.aerobicCapacity >= 44 {
            return .easyRun
        }
        if activationNeed > 52 && categories.contains(.walking) {
            return .walk
        }
        if profile?.goal == .muscleGain && categories.contains(.strength) && capability.loadTolerance >= 48 && recovery >= 48 {
            return .strength
        }
        if categories.contains(.mobility) {
            return .mobility
        }
        return .rest
    }

    private static func chooseTargetFocus(recommendationType: SuggestionType, enabledExercises: [ExerciseItem], baseline: PersonalBaseline) -> [MuscleGroup] {
        switch recommendationType {
        case .rest, .walk, .easyRun, .mobility:
            return [.cardioSystemic]
        case .strength:
            let strength = enabledExercises.filter { $0.category == .strength }
            guard let module = weakestStrengthModule(enabledExercises: strength, baseline: baseline) else {
                return [.back]
            }
            return module.representativeFocus
        }
    }

    private static func trainingBalanceAdjustment(
        baseline: PersonalBaseline,
        enabledExercises: [ExerciseItem],
        drivers: inout [String]
    ) -> Double {
        let strengthExercises = enabledExercises.filter { $0.category == .strength }
        let availableModules = availableStrengthModules(from: strengthExercises)
        guard !availableModules.isEmpty else {
            drivers.append("No strength modules enabled: +0.0 balance")
            return 0
        }

        let moduleCounts = Dictionary(uniqueKeysWithValues: availableModules.map { module in
            (module, moduleCoverageCount(module, baseline: baseline))
        })
        let counts = Array(moduleCounts.values)
        let averageCount = counts.isEmpty ? 0 : counts.reduce(0, +) / counts.count
        let weakestModule = moduleCounts.min { lhs, rhs in lhs.value < rhs.value }?.key
        let weakestCount = weakestModule.flatMap { moduleCounts[$0] } ?? 0
        let deficitRatio = averageCount > 0 ? Double(max(0, averageCount - weakestCount)) / Double(max(1, averageCount)) : 0

        let totalWorkouts = max(1, baseline.workoutBalance28.totalSessions)
        let cardioDominance = Double(baseline.workoutBalance28.cardioSessions - baseline.workoutBalance28.strengthSessions) / Double(totalWorkouts)
        let strengthOverweight = Double(max(0, baseline.workoutBalance28.strengthSessions - baseline.workoutBalance28.cardioSessions)) / Double(totalWorkouts)

        let moduleAdjustment = deficitRatio * 18.0
        let cardioAdjustment = max(0, cardioDominance) * 16.0
        let overweightPenalty = strengthOverweight * 8.0
        let totalAdjustment = moduleAdjustment + cardioAdjustment - overweightPenalty

        if let weakestModule {
            drivers.append("Coverage deficit \(weakestModule.rawValue): \(signed(moduleAdjustment))")
        }
        drivers.append("Cardio/strength balance: \(signed(cardioAdjustment - overweightPenalty))")
        return totalAdjustment
    }

    private static func availableStrengthModules(from exercises: [ExerciseItem]) -> [TrainingFocusModule] {
        var modules: Set<TrainingFocusModule> = []
        for exercise in exercises {
            let groups = exercise.primaryMuscleGroups + exercise.secondaryMuscleGroups
            for module in TrainingFocusModule.allCases where groups.contains(where: module.groups.contains) {
                modules.insert(module)
            }
        }
        return Array(modules)
    }

    private static func moduleCoverageCount(_ module: TrainingFocusModule, baseline: PersonalBaseline) -> Int {
        module.groups.reduce(0) { partial, group in
            partial + baseline.muscleCoverageBalance28[group, default: 0]
        }
    }

    private static func weakestStrengthModule(enabledExercises: [ExerciseItem], baseline: PersonalBaseline) -> TrainingFocusModule? {
        let modules = availableStrengthModules(from: enabledExercises)
        return modules.min { lhs, rhs in
            moduleCoverageCount(lhs, baseline: baseline) < moduleCoverageCount(rhs, baseline: baseline)
        }
    }

    private static func buildExercisePlan(
        recommendationType: SuggestionType,
        targetFocus: [MuscleGroup],
        enabledExercises: [ExerciseItem],
        intensity: RecommendationIntensity,
        volumeTier: VolumeTier,
        profile: UserProfile?,
        capability: CapabilityProfile
    ) -> [PlannedExercise] {
        switch recommendationType {
        case .rest:
            return []
        case .walk:
            let minutes = walkDuration(capability: capability, profile: profile, volumeTier: volumeTier)
            return [PlannedExercise(exerciseID: "walk", name: "Walk", targetMuscles: [.cardioSystemic], sets: nil, reps: nil, loadGuidance: nil, restSeconds: nil, durationMinutes: minutes, intensity: .low)]
        case .easyRun:
            let minutes = runDuration(capability: capability, profile: profile, volumeTier: volumeTier)
            return [PlannedExercise(exerciseID: "run", name: "Run", targetMuscles: [.cardioSystemic], sets: nil, reps: nil, loadGuidance: nil, restSeconds: nil, durationMinutes: minutes, intensity: .moderate)]
        case .mobility:
            return [PlannedExercise(exerciseID: "mobility", name: "Mobility Flow", targetMuscles: [.cardioSystemic], sets: nil, reps: nil, loadGuidance: "Gentle range-of-motion sequence", restSeconds: nil, durationMinutes: 18, intensity: .low)]
        case .strength:
            let focus = targetFocus.first ?? .back
            let matches = enabledExercises
                .filter { $0.category == .strength && ($0.primaryMuscleGroups.contains(focus) || $0.secondaryMuscleGroups.contains(focus)) }
                .prefix(3)

            let sets: Int
            let reps: String
            let prescription = strengthPrescription(
                focus: focus,
                capability: capability,
                volumeTier: volumeTier,
                profile: profile
            )
            sets = prescription.sets
            reps = prescription.reps

            let rest = intensity == .high ? 120 : 90

            return matches.map { item in
                PlannedExercise(
                    exerciseID: item.id,
                    name: item.displayName,
                    targetMuscles: item.primaryMuscleGroups,
                    sets: sets,
                    reps: reps,
                    loadGuidance: loadGuidance(for: item, profile: profile, capability: capability, tier: volumeTier),
                    restSeconds: rest,
                    durationMinutes: nil,
                    intensity: intensity
                )
            }
        }
    }

    private static func loadGuidance(for exercise: ExerciseItem, profile: UserProfile?, capability: CapabilityProfile, tier: VolumeTier) -> String {
        let percent: String
        switch tier {
        case .light: percent = "55-65%"
        case .moderate: percent = "65-75%"
        case .hard: percent = "75-82%"
        }

        let estimate: Double?
        let lower = exercise.displayName.lowercased()
        if lower.contains("bench") || lower.contains("chest") {
            estimate = profile?.estimatedBenchPressKg
        } else if lower.contains("pulldown") || lower.contains("row") || lower.contains("pull") {
            estimate = profile?.estimatedLatPulldownKg
        } else if lower.contains("squat") || lower.contains("leg") {
            estimate = profile?.estimatedSquatKg
        } else {
            estimate = nil
        }

        if let estimate {
            let workingMaxMultiplier: Double
            switch tier {
            case .light:
                workingMaxMultiplier = 0.60
            case .moderate:
                workingMaxMultiplier = 0.68
            case .hard:
                workingMaxMultiplier = 0.75
            }
            return "\(percent) est max (~\(Int((estimate * workingMaxMultiplier).rounded())) kg), RIR 2-3"
        }

        if exercise.displayName.lowercased().contains("pull-up"), let maxPullUps = profile?.maxPullUps {
            if maxPullUps >= 10 {
                return "Bodyweight or small added load, RIR 2-3"
            }
            return "Assisted or bodyweight reps, RIR 2-3"
        }

        if exercise.displayName.lowercased().contains("push"), let maxPushUps = profile?.maxPushUps {
            if maxPushUps >= 25 {
                return "Moderate load, controlled tempo, RIR 2-3"
            }
        }

        if capability.loadTolerance < 45 {
            return "RPE 6-7, leave 3 reps in reserve"
        }
        return "RPE 6-8, leave 2-3 reps in reserve"
    }

    private static func chooseIntensity(
        recovery: Double,
        activationNeed: Double,
        muscleReadiness: Double,
        passiveScore: Int,
        bias: Double,
        capability: CapabilityProfile,
        recommendationType: SuggestionType
    ) -> RecommendationIntensity {
        var blend = recovery * 0.45 + activationNeed * 0.20 + muscleReadiness * 0.25 + Double(passiveScore) * 0.10 + bias
        switch recommendationType {
        case .easyRun:
            blend += (capability.aerobicCapacity - 50) * 0.16
        case .strength:
            blend += (capability.loadTolerance - 50) * 0.14
        case .walk, .mobility, .rest:
            break
        }
        if blend < 45 { return .low }
        if blend < 70 { return .moderate }
        return .high
    }

    private static func chooseVolumeTier(
        recovery: Double,
        muscleReadiness: Double,
        passiveScore: Int,
        experience: TrainingExperience,
        bias: Double,
        capability: CapabilityProfile,
        recommendationType: SuggestionType
    ) -> VolumeTier {
        var score = recovery * 0.5 + muscleReadiness * 0.35 + Double(passiveScore) * 0.15 + bias
        switch experience {
        case .beginner: score -= 8
        case .intermediate: break
        case .advanced: score += 6
        }

        switch recommendationType {
        case .strength:
            score += (capability.loadTolerance - 50) * 0.18
        case .easyRun, .walk:
            score += (capability.aerobicCapacity - 50) * 0.14
        case .mobility, .rest:
            break
        }

        if score < 45 { return .light }
        if score < 70 { return .moderate }
        return .hard
    }

    private static func plannedDurationMinutes(
        recommendationType: SuggestionType,
        exercises: [PlannedExercise],
        volumeTier: VolumeTier,
        capability: CapabilityProfile,
        profile: UserProfile?
    ) -> Int {
        switch recommendationType {
        case .walk:
            return walkDuration(capability: capability, profile: profile, volumeTier: volumeTier)
        case .easyRun:
            return runDuration(capability: capability, profile: profile, volumeTier: volumeTier)
        case .mobility:
            return 18
        case .rest:
            return 15
        case .strength:
            let exerciseMinutes = exercises.count * 8
            let setMinutes = exercises.reduce(0) { partial, item in
                partial + max(0, (item.sets ?? 0) * 3)
            }
            let base = max(18, exerciseMinutes + setMinutes)
            let consistencyBoost = Int(((capability.consistencyCapacity - 50) * 0.08).rounded())
            return Int(clamp(Double(base + consistencyBoost), min: 20, max: 60).rounded())
        }
    }

    private static func walkDuration(capability: CapabilityProfile, profile: UserProfile?, volumeTier: VolumeTier) -> Int {
        let goalBoost: Int
        switch profile?.goal ?? .generalHealth {
        case .generalHealth:
            goalBoost = 0
        case .fatLoss:
            goalBoost = 6
        case .muscleGain:
            goalBoost = -2
        }
        let tierBase: Int
        switch volumeTier {
        case .light:
            tierBase = 22
        case .moderate:
            tierBase = 30
        case .hard:
            tierBase = 38
        }
        let capabilityShift = Int(((capability.consistencyCapacity - 50) * 0.12).rounded())
        return Int(clamp(Double(tierBase + goalBoost + capabilityShift), min: 18, max: 50).rounded())
    }

    private static func runDuration(capability: CapabilityProfile, profile: UserProfile?, volumeTier: VolumeTier) -> Int {
        let tierBase: Int
        switch volumeTier {
        case .light:
            tierBase = 16
        case .moderate:
            tierBase = 24
        case .hard:
            tierBase = 32
        }
        let aerobicShift = Int(((capability.aerobicCapacity - 50) * 0.18).rounded())
        let goalBoost = (profile?.goal == .fatLoss) ? 4 : 0
        return Int(clamp(Double(tierBase + aerobicShift + goalBoost), min: 15, max: 42).rounded())
    }

    private static func strengthPrescription(
        focus: MuscleGroup,
        capability: CapabilityProfile,
        volumeTier: VolumeTier,
        profile: UserProfile?
    ) -> (sets: Int, reps: String) {
        let capabilityBase: Double
        switch focus {
        case .chest:
            capabilityBase = capability.upperPushStrength
        case .back, .biceps, .forearms:
            capabilityBase = capability.upperPullStrength
        case .quads, .hamstrings, .glutes, .adductors, .calves:
            capabilityBase = capability.lowerBodyStrength
        case .cardioSystemic:
            capabilityBase = capability.loadTolerance
        }

        var sets: Int
        var reps: String
        switch volumeTier {
        case .light:
            sets = capabilityBase >= 58 ? 3 : 2
            reps = capabilityBase >= 60 ? "8-10" : "10-12"
        case .moderate:
            sets = capabilityBase >= 62 ? 4 : 3
            reps = capabilityBase >= 65 ? "6-10" : "8-12"
        case .hard:
            sets = capabilityBase >= 68 ? 5 : 4
            reps = capabilityBase >= 72 ? "5-8" : "6-10"
        }

        if profile?.goal == .muscleGain {
            sets += 1
        }
        if profile?.goal == .generalHealth {
            sets = min(sets, 4)
        }
        return (sets: Int(clamp(Double(sets), min: 2, max: 5).rounded()), reps: reps)
    }

    private static func muscleReadinessScore(for targetFocus: [MuscleGroup], recoveryMap: [MuscleGroup: MuscleRecoveryStatus]) -> Int {
        let values = targetFocus.compactMap { recoveryMap[$0]?.score }
        guard !values.isEmpty else { return 50 }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private static func computeConfidence(snapshot: DailyHealthSnapshot, baseline: PersonalBaseline, enabledExercises: [ExerciseItem], passiveSummary: PassiveRecoveryResponseSummary) -> Int {
        let metricCount = [snapshot.lastNightSleepHours, snapshot.restingHeartRate, snapshot.hrv, snapshot.stepCountToday].compactMap { $0 }.count
        let baselineCount = [baseline.sleep.rolling28, baseline.restingHeartRate.rolling28, baseline.hrv.rolling28, baseline.steps.rolling28].compactMap { $0 }.count
        let exerciseFactor = min(10, enabledExercises.count)
        let passive = passiveSummary.lastResponse == nil ? 0 : 8

        let confidence = 25 + metricCount * 10 + baselineCount * 8 + exerciseFactor + passive
        return Int(clamp(Double(confidence), min: 25, max: 95).rounded())
    }

    private static func expectedStepsByCurrentHour(baselineSteps: Double, date: Date) -> Double {
        let hour = Calendar.current.component(.hour, from: date)
        let progress = clamp(Double(hour) / 16.0, min: 0.2, max: 1.0)
        return baselineSteps * progress
    }

    private static func buildExplanation(type: SuggestionType, goal: TrainingGoal, scores: RecommendationScores, targetFocus: [MuscleGroup]) -> String {
        let focus = targetFocus.map { $0.rawValue }.joined(separator: ", ")
        return "Goal: \(goal.rawValue). Recovery \(scores.recoveryScore), activation \(scores.activationNeedScore), passive response \(scores.passiveRecoveryResponseScore), focus: \(focus)."
    }

    private static func safetyCheck(snapshot: DailyHealthSnapshot, baseline: PersonalBaseline) -> String? {
        guard let baseRHR = baseline.restingHeartRate.rolling28,
              let baseHRV = baseline.hrv.rolling28,
              let rhr = snapshot.restingHeartRate,
              let hrv = snapshot.hrv,
              let sleep = snapshot.lastNightSleepHours else {
            return nil
        }

        if rhr > baseRHR * 1.15 && hrv < baseHRV * 0.8 && sleep < 5.0 {
            return "Physiological stress appears elevated today. Prefer recovery activity."
        }

        return nil
    }

    private static func logRecommendation(
        recommendationType: SuggestionType,
        duration: Int,
        intensity: RecommendationIntensity,
        volumeTier: VolumeTier,
        scores: RecommendationScores,
        targetFocus: [MuscleGroup],
        recoveryMap: [MuscleGroup: MuscleRecoveryStatus],
        drivers: [String],
        exercises: [PlannedExercise]
    ) {
        print("[Recommendation] type=\(recommendationType.rawValue) duration=\(duration) intensity=\(intensity.rawValue) tier=\(volumeTier.rawValue)")
        print("[Recommendation] scores recovery=\(scores.recoveryScore), activation=\(scores.activationNeedScore), balance=\(scores.trainingBalanceScore), muscle=\(scores.muscleReadinessScore), passive=\(scores.passiveRecoveryResponseScore), confidence=\(scores.confidenceScore)")
        for group in targetFocus {
            if let state = recoveryMap[group] {
                print("[Recommendation] muscle \(group.rawValue) => \(state.state.rawValue) score=\(state.score)")
            }
        }
        for driver in drivers {
            print("[Recommendation] driver=\(driver)")
        }
        for exercise in exercises {
            print("[Recommendation] selected exercise=\(exercise.name) sets=\(exercise.sets ?? 0) reps=\(exercise.reps ?? "-") load=\(exercise.loadGuidance ?? "-")")
        }
    }

    private static func ratio<T: Equatable>(of value: T, from values: [T]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.filter { $0 == value }.count) / Double(values.count)
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    private static func signed(_ value: Double) -> String {
        value >= 0 ? String(format: "+%.1f", value) : String(format: "%.1f", value)
    }
}
