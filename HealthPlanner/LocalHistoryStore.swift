import Foundation
import Combine

enum PerceivedEffort: String, Codable, CaseIterable {
    case tooEasy = "Too easy"
    case good = "Good"
    case tooHard = "Too hard"
}

enum NextDayFeeling: String, Codable, CaseIterable {
    case better = "Feel better"
    case same = "Same"
    case worse = "Worse"
}

struct StoredDailyRecord: Codable, Identifiable {
    var id: Date { date }

    var date: Date
    var sleepHours: Double?
    var restingHeartRate: Double?
    var hrv: Double?
    var steps: Double?
    var dailyStepGoal: Double?
    var workoutType: String?
    var workoutDate: Date?
    var workoutDurationMinutes: Double?

    var recommendationType: SuggestionType?
    var recommendationDurationMinutes: Int?
    var recommendationIntensity: RecommendationIntensity?
    var recommendationExplanation: String?
    var recommendationConfidence: Int?
    var recommendationExercises: [PlannedExercise]

    var completedRecommendation: Bool?
    var perceivedEffort: PerceivedEffort?
    var nextDayFeeling: NextDayFeeling?
    var feedbackNote: String?

    init(date: Date) {
        self.date = date
        self.recommendationExercises = []
    }
}

@MainActor
final class LocalHistoryStore: ObservableObject {
    @Published private(set) var records: [StoredDailyRecord] = []
    @Published private(set) var sessions: [CompletedWorkoutSession] = []
    @Published private(set) var passiveResponses: [PassiveRecoveryResponse] = []
    @Published var activeSessionStart: Date?

    private let recordsFileURL: URL
    private let sessionsFileURL: URL
    private let responsesFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let fm = FileManager.default
        let baseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appDir = baseDir.appendingPathComponent("HealthPlanner", isDirectory: true)

        if !fm.fileExists(atPath: appDir.path) {
            try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        }

        recordsFileURL = appDir.appendingPathComponent("daily_history.json")
        sessionsFileURL = appDir.appendingPathComponent("workout_sessions.json")
        responsesFileURL = appDir.appendingPathComponent("passive_responses.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    var passiveSummary: PassiveRecoveryResponseSummary {
        PassiveRecoveryResponseEngine.summarize(passiveResponses)
    }

    func upsert(snapshot: DailyHealthSnapshot, recommendation: DailyRecommendation) {
        let day = Calendar.current.startOfDay(for: snapshot.date)

        var target = record(for: day) ?? StoredDailyRecord(date: day)
        target.sleepHours = snapshot.lastNightSleepHours
        target.restingHeartRate = snapshot.restingHeartRate
        target.hrv = snapshot.hrv
        target.steps = snapshot.stepCountToday
        target.workoutType = snapshot.latestWorkoutType
        target.workoutDate = snapshot.latestWorkoutDate
        target.workoutDurationMinutes = snapshot.latestWorkoutDurationMinutes

        target.recommendationType = recommendation.type
        target.recommendationDurationMinutes = recommendation.durationMinutes
        target.recommendationIntensity = recommendation.intensity
        target.recommendationExplanation = recommendation.explanation
        target.recommendationConfidence = recommendation.confidenceLevel
        target.recommendationExercises = recommendation.exercises

        save(record: target)
    }

    func upsertDailyStepGoal(_ goal: Double, for date: Date = Date()) {
        let day = Calendar.current.startOfDay(for: date)
        var target = record(for: day) ?? StoredDailyRecord(date: day)
        target.dailyStepGoal = goal
        save(record: target)
    }

    func startSession() {
        activeSessionStart = Date()
    }

    func endSession(recommendation: DailyRecommendation, completionRatio: Double = 1.0) {
        let endDate = Date()
        let start = activeSessionStart ?? endDate.addingTimeInterval(-Double(recommendation.durationMinutes * 60))
        activeSessionStart = nil
        let actualDurationMinutes = max(1, Int(endDate.timeIntervalSince(start) / 60))
        let durationRatio = Double(actualDurationMinutes) / Double(max(1, recommendation.durationMinutes))
        let effectiveCompletionRatio = clamp(completionRatio * durationRatio, min: 0.4, max: 1.4)

        let day = Calendar.current.startOfDay(for: start)
        var record = self.record(for: day) ?? StoredDailyRecord(date: day)
        record.completedRecommendation = true
        record.workoutType = recommendation.type.rawValue
        record.workoutDate = endDate
        record.workoutDurationMinutes = Double(actualDurationMinutes)
        save(record: record)

        appendSessionFromRecommendation(
            recommendation: recommendation,
            date: endDate,
            completionRatio: effectiveCompletionRatio,
            perceived: record.perceivedEffort
        )
    }

    func syncWorkoutFromHealthKit(_ workout: WorkoutSummary) {
        let day = Calendar.current.startOfDay(for: workout.date)
        let plannedRecord = record(for: day)
        let resolvedType = suggestionType(for: workout, plannedRecord: plannedRecord)
        let resolvedExercises = completedExercises(for: workout, plannedRecord: plannedRecord, suggestionType: resolvedType)

        guard !sessionExists(near: workout.date, exerciseNames: resolvedExercises.map(\.name)) else {
            markDetectedWorkout(on: day, workout: workout, plannedRecord: plannedRecord)
            return
        }

        let intensity = resolvedIntensity(for: workout, plannedRecord: plannedRecord)
        let volume = resolvedVolume(for: workout, suggestionType: resolvedType, plannedRecord: plannedRecord, exercises: resolvedExercises)
        let session = CompletedWorkoutSession(
            id: UUID(),
            date: workout.date,
            exercises: resolvedExercises,
            plannedVolumeScore: volume,
            completedVolumeScore: volume,
            sessionIntensity: intensity,
            perceivedDifficulty: nil
        )

        sessions.append(session)
        sessions.sort { $0.date < $1.date }
        persistSessions()
        markDetectedWorkout(on: day, workout: workout, plannedRecord: plannedRecord)
        let groupSummary = Set(resolvedExercises.flatMap(\.muscleGroups)).map(\.rawValue).joined(separator: ",")
        let volumeSummary = String(format: "%.2f", volume)
        print("[LocalHistoryStore] imported HealthKit workout \(workout.type) \(Int(workout.durationMinutes.rounded())) min groups=\(groupSummary) volume=\(volumeSummary)")
    }

    func syncWorkoutsFromHealthKit(_ workouts: [WorkoutSummary]) {
        for workout in workouts {
            syncWorkoutFromHealthKit(workout)
        }
    }

    func syncPassiveCompletion(snapshot: DailyHealthSnapshot) {
        let day = Calendar.current.startOfDay(for: snapshot.date)
        guard var record = record(for: day), record.completedRecommendation != true else { return }
        guard let recommendationType = record.recommendationType else { return }

        if let latestWorkoutDate = record.workoutDate,
           Calendar.current.isDate(latestWorkoutDate, inSameDayAs: snapshot.date),
           matchesRecommendation(workoutType: record.workoutType, recommendationType: recommendationType) {
            record.completedRecommendation = true
            save(record: record)
            print("[LocalHistoryStore] passive completion from HealthKit workout")
            return
        }

        guard let steps = snapshot.stepCountToday else { return }
        let stepThreshold = passiveStepCompletionThreshold(for: record)
        guard stepThreshold > 0, steps >= stepThreshold else { return }

        record.completedRecommendation = true
        save(record: record)

        if latestSession(on: snapshot.date) == nil {
            appendSessionFromStoredRecord(record, date: snapshot.date, completionRatio: 1.0)
        }
        print("[LocalHistoryStore] passive completion from steps steps=\(Int(steps)) threshold=\(Int(stepThreshold.rounded()))")
    }

    func setCompletion(_ completed: Bool, for date: Date = Date()) {
        let day = Calendar.current.startOfDay(for: date)
        var target = record(for: day) ?? StoredDailyRecord(date: day)
        target.completedRecommendation = completed
        save(record: target)

        if completed {
            appendSessionFromStoredRecord(target, date: date, completionRatio: 1.0)
        }
    }

    func setPerceivedEffort(_ effort: PerceivedEffort, for date: Date = Date()) {
        let day = Calendar.current.startOfDay(for: date)
        var target = record(for: day) ?? StoredDailyRecord(date: day)
        target.perceivedEffort = effort
        save(record: target)
    }

    func setNextDayFeeling(_ feeling: NextDayFeeling, for date: Date = Date()) {
        let day = Calendar.current.startOfDay(for: date)
        var target = record(for: day) ?? StoredDailyRecord(date: day)
        target.nextDayFeeling = feeling
        save(record: target)
    }

    func setFeedbackNote(_ note: String, for date: Date = Date()) {
        let day = Calendar.current.startOfDay(for: date)
        var target = record(for: day) ?? StoredDailyRecord(date: day)
        target.feedbackNote = note.isEmpty ? nil : note
        save(record: target)
    }

    func storePassiveResponse(_ response: PassiveRecoveryResponse) {
        passiveResponses.append(response)
        passiveResponses.sort { $0.responseDate < $1.responseDate }
        persistResponses()
    }

    func latestRecord(before date: Date) -> StoredDailyRecord? {
        records
            .filter { $0.date < Calendar.current.startOfDay(for: date) }
            .sorted { $0.date < $1.date }
            .last
    }

    func todayRecord() -> StoredDailyRecord? {
        record(for: Calendar.current.startOfDay(for: Date()))
    }

    func latestSession(on date: Date = Date()) -> CompletedWorkoutSession? {
        sessions
            .filter { Calendar.current.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.date < $1.date }
            .last
    }

    var hasCompletedRecommendationToday: Bool {
        todayRecord()?.completedRecommendation == true
    }

    private func record(for day: Date) -> StoredDailyRecord? {
        records.first { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    private func save(record: StoredDailyRecord) {
        if let index = records.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: record.date) }) {
            records[index] = record
        } else {
            records.append(record)
        }

        records.sort { $0.date < $1.date }
        persistRecords()
    }

    private func appendSessionFromRecommendation(
        recommendation: DailyRecommendation,
        date: Date,
        completionRatio: Double,
        perceived: PerceivedEffort?
    ) {
        let exercises: [CompletedExerciseEntry]
        if recommendation.exercises.isEmpty {
            let fallbackName = fallbackExerciseName(for: recommendation.type)
            exercises = [
                CompletedExerciseEntry(
                    exerciseID: "session-\(recommendation.type.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    name: fallbackName,
                    muscleGroups: inferredMuscleGroups(forWorkoutName: fallbackName, recommendationType: recommendation.type, fallbackFocus: recommendation.targetFocus),
                    sets: 1,
                    reps: max(1, recommendation.durationMinutes),
                    loadKg: nil,
                    plannedSets: 1,
                    plannedReps: max(1, recommendation.durationMinutes)
                )
            ]
        } else {
            exercises = recommendation.exercises.map {
                let mappedMuscles = inferredMuscleGroups(for: $0, recommendationType: recommendation.type)
                return CompletedExerciseEntry(
                    exerciseID: $0.exerciseID,
                    name: $0.name,
                    muscleGroups: mappedMuscles,
                    sets: max(1, $0.sets ?? 1),
                    reps: parseRepMidpoint($0.reps),
                    loadKg: parseApproximateLoad($0.loadGuidance),
                    plannedSets: max(1, $0.sets ?? 1),
                    plannedReps: parseRepMidpoint($0.reps)
                )
            }
        }

        guard !sessionExists(near: date, exerciseNames: exercises.map(\.name)) else { return }

        let plannedVolume = estimateSessionVolume(exercises: exercises, fallbackType: recommendation.type)
        let completedVolume = plannedVolume * clamp(completionRatio, min: 0.4, max: 1.2)

        let session = CompletedWorkoutSession(
            id: UUID(),
            date: date,
            exercises: exercises,
            plannedVolumeScore: plannedVolume,
            completedVolumeScore: completedVolume,
            sessionIntensity: recommendation.intensity,
            perceivedDifficulty: perceived
        )

        sessions.append(session)
        sessions.sort { $0.date < $1.date }
        persistSessions()
        let groupSummary = Set(exercises.flatMap(\.muscleGroups)).map(\.rawValue).joined(separator: ",")
        let volumeSummary = String(format: "%.2f", completedVolume)
        print("[LocalHistoryStore] appended session \(recommendation.type.rawValue) groups=\(groupSummary) volume=\(volumeSummary)")
    }

    private func appendSessionFromStoredRecord(_ record: StoredDailyRecord, date: Date, completionRatio: Double) {
        guard let recommendation = storedRecommendation(from: record) else { return }
        appendSessionFromRecommendation(
            recommendation: recommendation,
            date: date,
            completionRatio: completionRatio,
            perceived: record.perceivedEffort
        )
    }

    private func storedRecommendation(from record: StoredDailyRecord) -> DailyRecommendation? {
        guard let type = record.recommendationType else { return nil }
        let focusFromExercises = Array(Set(record.recommendationExercises.flatMap(\.targetMuscles)))
        let targetFocus = focusFromExercises.isEmpty ? inferredFocus(for: type, exercises: record.recommendationExercises) : focusFromExercises

        return DailyRecommendation(
            type: type,
            targetFocus: targetFocus,
            exercises: record.recommendationExercises,
            durationMinutes: record.recommendationDurationMinutes ?? 20,
            intensity: record.recommendationIntensity ?? .low,
            explanation: record.recommendationExplanation ?? "",
            confidenceLevel: record.recommendationConfidence ?? 50,
            scores: RecommendationScores(
                recoveryScore: 50,
                activationNeedScore: 50,
                trainingBalanceScore: 50,
                muscleReadinessScore: 50,
                confidenceScore: 50,
                passiveRecoveryResponseScore: passiveSummary.recentAverageScore
            ),
            scoreDrivers: [],
            safetyMessage: nil,
            volumeTier: .light
        )
    }

    private func inferredMuscleGroups(for exercise: PlannedExercise, recommendationType: SuggestionType) -> [MuscleGroup] {
        let existing = exercise.targetMuscles.filter { $0 != .cardioSystemic }
        if !existing.isEmpty {
            return Array(Set(existing + carryOverSystemicIfNeeded(from: exercise.targetMuscles)))
        }

        let id = exercise.exerciseID.lowercased()
        let name = exercise.name.lowercased()

        return inferredMuscleGroups(
            forWorkoutName: "\(id) \(name)",
            recommendationType: recommendationType,
            fallbackFocus: exercise.targetMuscles
        )
    }

    private func carryOverSystemicIfNeeded(from groups: [MuscleGroup]) -> [MuscleGroup] {
        groups.contains(.cardioSystemic) ? [.cardioSystemic] : []
    }

    private func inferredMuscleGroups(
        forWorkoutName name: String,
        recommendationType: SuggestionType,
        fallbackFocus: [MuscleGroup] = []
    ) -> [MuscleGroup] {
        let lowercasedName = name.lowercased()

        if lowercasedName.contains("walk") || lowercasedName.contains("hiking") {
            if lowercasedName.contains("hiking") {
                return [.calves, .quads, .hamstrings, .glutes, .cardioSystemic]
            }
            return [.calves, .quads, .hamstrings, .glutes, .cardioSystemic]
        }
        if lowercasedName.contains("run") {
            return [.calves, .quads, .hamstrings, .glutes, .cardioSystemic]
        }
        if lowercasedName.contains("cycling") {
            return [.quads, .hamstrings, .glutes, .calves, .cardioSystemic]
        }
        if lowercasedName.contains("swimming") {
            return [.chest, .back, .biceps, .forearms, .cardioSystemic]
        }
        if lowercasedName.contains("yoga") || lowercasedName.contains("mobility") {
            return [.glutes, .hamstrings, .back, .cardioSystemic]
        }
        if lowercasedName.contains("chest") || lowercasedName.contains("bench") || lowercasedName.contains("press") {
            return [.chest, .biceps, .forearms]
        }
        if lowercasedName.contains("row") || lowercasedName.contains("pull") || lowercasedName.contains("back") || lowercasedName.contains("pulldown") {
            return [.back, .biceps, .forearms]
        }
        if lowercasedName.contains("squat") || lowercasedName.contains("leg") || lowercasedName.contains("curl") || lowercasedName.contains("adduction") {
            return [.quads, .hamstrings, .glutes, .calves, .adductors]
        }
        if lowercasedName.contains("strength") || lowercasedName.contains("functional strength") {
            return [.chest, .back, .quads, .hamstrings, .glutes, .biceps, .forearms, .cardioSystemic]
        }
        if recommendationType == .mobility {
            return [.cardioSystemic]
        }
        if recommendationType == .walk || recommendationType == .easyRun {
            return [.calves, .quads, .hamstrings, .glutes, .cardioSystemic]
        }
        let existing = fallbackFocus.filter { $0 != .cardioSystemic }
        if !existing.isEmpty {
            return Array(Set(existing + carryOverSystemicIfNeeded(from: fallbackFocus)))
        }
        return [.cardioSystemic]
    }

    private func estimateSessionVolume(exercises: [CompletedExerciseEntry], fallbackType: SuggestionType) -> Double {
        if !exercises.isEmpty {
            return exercises.reduce(0.0) { partial, exercise in
                partial + Double(max(1, exercise.plannedSets)) * Double(max(1, exercise.plannedReps)) * 0.03
            }
        }

        switch fallbackType {
        case .rest:
            return 0.5
        case .walk, .mobility:
            return 1.5
        case .easyRun:
            return 2.0
        case .strength:
            return 3.0
        }
    }

    private func parseRepMidpoint(_ reps: String?) -> Int {
        guard let reps else { return 8 }
        let parts = reps.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2 {
            return (parts[0] + parts[1]) / 2
        }
        return parts.first ?? 8
    }

    private func parseApproximateLoad(_ load: String?) -> Double? {
        guard let load else { return nil }
        let digits = load.filter { $0.isNumber }
        return Double(digits)
    }

    private func sessionExists(near date: Date, exerciseNames: [String]) -> Bool {
        let normalizedNames = Set(exerciseNames.map { $0.lowercased() })
        return sessions.contains { session in
            let closeInTime = abs(session.date.timeIntervalSince(date)) < 90 * 60
            let sameExercises = Set(session.exercises.map { $0.name.lowercased() }) == normalizedNames
            return closeInTime && sameExercises
        }
    }

    private func inferredSuggestionType(from workoutType: String) -> SuggestionType {
        let lowercasedType = workoutType.lowercased()
        if lowercasedType.contains("run") {
            return .easyRun
        }
        if lowercasedType.contains("walk") || lowercasedType.contains("hiking") || lowercasedType.contains("cycling") || lowercasedType.contains("swimming") {
            return .walk
        }
        if lowercasedType.contains("yoga") || lowercasedType.contains("mobility") {
            return .mobility
        }
        if lowercasedType.contains("strength") || lowercasedType.contains("pull") || lowercasedType.contains("row") || lowercasedType.contains("press") || lowercasedType.contains("squat") {
            return .strength
        }
        return .walk
    }

    private func suggestionType(for workout: WorkoutSummary, plannedRecord: StoredDailyRecord?) -> SuggestionType {
        let inferred = inferredSuggestionType(from: workout.type)
        guard let plannedType = plannedRecord?.recommendationType else { return inferred }

        if isStrengthLike(workout.type), plannedType == .strength {
            return .strength
        }

        if matchesRecommendation(workoutType: workout.type, recommendationType: plannedType) {
            return plannedType
        }

        return inferred
    }

    private func completedExercises(
        for workout: WorkoutSummary,
        plannedRecord: StoredDailyRecord?,
        suggestionType: SuggestionType
    ) -> [CompletedExerciseEntry] {
        if isStrengthLike(workout.type),
           let plannedRecord,
           plannedRecord.recommendationType == .strength,
           !plannedRecord.recommendationExercises.isEmpty {
            return plannedRecord.recommendationExercises.map {
                let mappedMuscles = inferredMuscleGroups(for: $0, recommendationType: .strength)
                return CompletedExerciseEntry(
                    exerciseID: $0.exerciseID,
                    name: $0.name,
                    muscleGroups: mappedMuscles,
                    sets: max(1, $0.sets ?? 1),
                    reps: parseRepMidpoint($0.reps),
                    loadKg: parseApproximateLoad($0.loadGuidance),
                    plannedSets: max(1, $0.sets ?? 1),
                    plannedReps: parseRepMidpoint($0.reps)
                )
            }
        }

        let muscles = inferredMuscleGroups(
            forWorkoutName: workout.type,
            recommendationType: suggestionType,
            fallbackFocus: inferredFocus(for: plannedRecord?.recommendationType ?? suggestionType, exercises: plannedRecord?.recommendationExercises ?? [])
        )
        let reps = max(1, Int(workout.durationMinutes.rounded()))
        return [
            CompletedExerciseEntry(
                exerciseID: "healthkit-\(suggestionType.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
                name: workout.type,
                muscleGroups: muscles,
                sets: 1,
                reps: reps,
                loadKg: nil,
                plannedSets: 1,
                plannedReps: reps
            )
        ]
    }

    private func inferredIntensity(from workout: WorkoutSummary) -> RecommendationIntensity {
        let lowercasedType = workout.type.lowercased()
        if lowercasedType.contains("run") || lowercasedType.contains("cycling") || lowercasedType.contains("swimming") || lowercasedType.contains("hiking") {
            return workout.durationMinutes >= 45 ? .high : .moderate
        }
        if lowercasedType.contains("strength") {
            return workout.durationMinutes >= 55 ? .high : .moderate
        }
        if lowercasedType.contains("yoga") || lowercasedType.contains("mobility") {
            return .low
        }
        return workout.durationMinutes >= 50 ? .moderate : .low
    }

    private func resolvedIntensity(for workout: WorkoutSummary, plannedRecord: StoredDailyRecord?) -> RecommendationIntensity {
        let inferred = inferredIntensity(from: workout)
        guard let plannedIntensity = plannedRecord?.recommendationIntensity else { return inferred }
        if isStrengthLike(workout.type), plannedRecord?.recommendationType == .strength {
            return maxIntensity(plannedIntensity, inferred)
        }
        return inferred
    }

    private func estimatedVolume(for workout: WorkoutSummary, suggestionType: SuggestionType) -> Double {
        let base = max(0.8, workout.durationMinutes / 18.0)
        switch suggestionType {
        case .rest:
            return 0.5
        case .walk, .mobility:
            return base * 1.0
        case .easyRun:
            return base * 1.35
        case .strength:
            return base * 1.7
        }
    }

    private func resolvedVolume(
        for workout: WorkoutSummary,
        suggestionType: SuggestionType,
        plannedRecord: StoredDailyRecord?,
        exercises: [CompletedExerciseEntry]
    ) -> Double {
        let durationVolume = estimatedVolume(for: workout, suggestionType: suggestionType)

        guard let plannedRecord,
              let plannedRecommendation = storedRecommendation(from: plannedRecord) else {
            return durationVolume
        }

        let plannedVolume = estimateSessionVolume(exercises: exercises, fallbackType: suggestionType)
        let durationRatio = workout.durationMinutes / Double(max(plannedRecommendation.durationMinutes, 1))
        let completionRatio = clamp(durationRatio, min: 0.75, max: 1.5)
        let contextAdjustedVolume = plannedVolume * completionRatio

        if isStrengthLike(workout.type), plannedRecord.recommendationType == .strength {
            return max(durationVolume * 1.25, contextAdjustedVolume * 1.4)
        }

        if matchesRecommendation(workoutType: workout.type, recommendationType: plannedRecommendation.type) {
            return max(durationVolume, contextAdjustedVolume)
        }

        return durationVolume
    }

    private func inferredFocus(for type: SuggestionType, exercises: [PlannedExercise]) -> [MuscleGroup] {
        let focus = Array(Set(exercises.flatMap(\.targetMuscles)))
        if !focus.isEmpty {
            return focus
        }
        switch type {
        case .rest, .mobility:
            return [.cardioSystemic]
        case .walk, .easyRun:
            return [.quads, .hamstrings, .glutes, .calves, .cardioSystemic]
        case .strength:
            return [.cardioSystemic]
        }
    }

    private func matchesRecommendation(workoutType: String?, recommendationType: SuggestionType) -> Bool {
        guard let workoutType else { return false }
        let lowercasedType = workoutType.lowercased()
        switch recommendationType {
        case .rest:
            return false
        case .walk:
            return lowercasedType.contains("walk") || lowercasedType.contains("hiking") || lowercasedType.contains("cycling") || lowercasedType.contains("swimming")
        case .easyRun:
            return lowercasedType.contains("run")
        case .strength:
            return isStrengthLike(workoutType)
        case .mobility:
            return lowercasedType.contains("yoga") || lowercasedType.contains("mobility") || lowercasedType.contains("pilates")
        }
    }

    private func isStrengthLike(_ workoutType: String) -> Bool {
        let lowercasedType = workoutType.lowercased()
        return lowercasedType.contains("strength") || lowercasedType.contains("functional strength") || lowercasedType.contains("traditional strength")
    }

    private func markDetectedWorkout(on day: Date, workout: WorkoutSummary, plannedRecord: StoredDailyRecord?) {
        var record = plannedRecord ?? StoredDailyRecord(date: day)
        if record.workoutDate == nil || workout.date > (record.workoutDate ?? .distantPast) {
            record.workoutType = workout.type
            record.workoutDate = workout.date
            record.workoutDurationMinutes = workout.durationMinutes
        }
        if let recommendationType = record.recommendationType,
           matchesRecommendation(workoutType: workout.type, recommendationType: recommendationType) {
            record.completedRecommendation = true
        }
        save(record: record)
    }

    private func passiveStepCompletionThreshold(for record: StoredDailyRecord) -> Double {
        guard let type = record.recommendationType else { return 0 }
        let duration = Double(record.recommendationDurationMinutes ?? 20)
        let intensity = record.recommendationIntensity ?? .low

        switch type {
        case .walk:
            let cadence: Double
            switch intensity {
            case .low:
                cadence = 80
            case .moderate:
                cadence = 95
            case .high:
                cadence = 110
            }
            return max(1800, duration * cadence * 0.82)
        case .easyRun:
            let cadence: Double
            switch intensity {
            case .low:
                cadence = 135
            case .moderate:
                cadence = 150
            case .high:
                cadence = 165
            }
            return max(2600, duration * cadence * 0.78)
        default:
            return 0
        }
    }

    private func maxIntensity(_ lhs: RecommendationIntensity, _ rhs: RecommendationIntensity) -> RecommendationIntensity {
        let order: [RecommendationIntensity] = [.low, .moderate, .high]
        let lhsIndex = order.firstIndex(of: lhs) ?? 0
        let rhsIndex = order.firstIndex(of: rhs) ?? 0
        return order[Swift.max(lhsIndex, rhsIndex)]
    }

    private func fallbackExerciseName(for type: SuggestionType) -> String {
        switch type {
        case .rest:
            return "Recovery Activity"
        case .walk:
            return "Walk"
        case .easyRun:
            return "Run"
        case .strength:
            return "Strength Session"
        case .mobility:
            return "Mobility"
        }
    }

    private func load() {
        loadRecords()
        loadSessions()
        loadResponses()
    }

    private func loadRecords() {
        guard FileManager.default.fileExists(atPath: recordsFileURL.path) else {
            records = []
            return
        }

        do {
            let data = try Data(contentsOf: recordsFileURL)
            records = try decoder.decode([StoredDailyRecord].self, from: data)
            records.sort { $0.date < $1.date }
        } catch {
            print("[LocalHistoryStore] load records failed: \(error.localizedDescription)")
            records = []
        }
    }

    private func loadSessions() {
        guard FileManager.default.fileExists(atPath: sessionsFileURL.path) else {
            sessions = []
            return
        }

        do {
            let data = try Data(contentsOf: sessionsFileURL)
            sessions = try decoder.decode([CompletedWorkoutSession].self, from: data)
            sessions.sort { $0.date < $1.date }
        } catch {
            print("[LocalHistoryStore] load sessions failed: \(error.localizedDescription)")
            sessions = []
        }
    }

    private func loadResponses() {
        guard FileManager.default.fileExists(atPath: responsesFileURL.path) else {
            passiveResponses = []
            return
        }

        do {
            let data = try Data(contentsOf: responsesFileURL)
            passiveResponses = try decoder.decode([PassiveRecoveryResponse].self, from: data)
            passiveResponses.sort { $0.responseDate < $1.responseDate }
        } catch {
            print("[LocalHistoryStore] load passive responses failed: \(error.localizedDescription)")
            passiveResponses = []
        }
    }

    private func persistRecords() {
        do {
            let data = try encoder.encode(records)
            try data.write(to: recordsFileURL, options: .atomic)
        } catch {
            print("[LocalHistoryStore] persist records failed: \(error.localizedDescription)")
        }
    }

    private func persistSessions() {
        do {
            let data = try encoder.encode(sessions)
            try data.write(to: sessionsFileURL, options: .atomic)
        } catch {
            print("[LocalHistoryStore] persist sessions failed: \(error.localizedDescription)")
        }
    }

    func clearAllData() {
        records = []
        sessions = []
        passiveResponses = []
        activeSessionStart = nil

        let fm = FileManager.default
        [recordsFileURL, sessionsFileURL, responsesFileURL].forEach { url in
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func persistResponses() {
        do {
            let data = try encoder.encode(passiveResponses)
            try data.write(to: responsesFileURL, options: .atomic)
        } catch {
            print("[LocalHistoryStore] persist responses failed: \(error.localizedDescription)")
        }
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}
