import Foundation
import HealthKit
import Combine

enum HealthAuthorizationUIState: Equatable {
    case unknown
    case requestAvailable
    case configuredInHealthApp
    case loadFailed(String)

    var title: String {
        switch self {
        case .unknown:
            return "Authorization state unknown"
        case .requestAvailable:
            return "Request available"
        case .configuredInHealthApp:
            return "Configured in Health app / Ready to load data"
        case .loadFailed(let message):
            return "Load failed: \(message)"
        }
    }
}

enum HealthMetric: String, CaseIterable {
    case stepCountToday = "Step count today"
    case latestHeartRate = "Latest heart rate"
    case latestRestingHeartRate = "Latest resting heart rate"
    case latestHRV = "Latest HRV"
    case latestWorkout = "Latest workout"
    case sleepDuration = "Sleep duration"
}

private struct MetricFetchResult<Value> {
    let value: Value?
    let sampleCount: Int
    let errorMessage: String?
    let fallbackMessage: String
}

struct HealthKitBaselineFallbacks {
    let sleep28: Double?
    let restingHeartRate28: Double?
    let hrv28: Double?
    let steps28: Double?

    static let empty = HealthKitBaselineFallbacks(
        sleep28: nil,
        restingHeartRate28: nil,
        hrv28: nil,
        steps28: nil
    )
}

@MainActor
final class HealthKitManager: ObservableObject {
    @Published private(set) var setupState: HealthAuthorizationUIState = .unknown
    @Published private(set) var lastLoadTimestamp: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var successfulMetricCount: Int = 0
    @Published private(set) var metricMessages: [HealthMetric: String] = [:]
    @Published private(set) var observerTick: Int = 0

    private let healthStore = HKHealthStore()
    private var observerQueries: [HKObserverQuery] = []
    private var observersStarted = false

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]

        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleepType)
        }

        [
            HKQuantityType.quantityType(forIdentifier: .heartRate),
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate),
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            HKQuantityType.quantityType(forIdentifier: .stepCount)
        ]
        .compactMap { $0 }
        .forEach { types.insert($0) }

        return types
    }

    init() {
        if !isHealthDataAvailable() {
            setupState = .loadFailed("HealthKit unavailable on this device")
            return
        }

        Task {
            await refreshSetupState()
            startObserverQueriesIfNeeded()
        }
    }

    func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    var canLoadData: Bool {
        if case .configuredInHealthApp = setupState {
            return true
        }
        return false
    }

    func refreshSetupState() async {
        guard isHealthDataAvailable() else {
            setupState = .loadFailed("HealthKit unavailable on this device")
            return
        }

        do {
            let status: HKAuthorizationRequestStatus = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKAuthorizationRequestStatus, Error>) in
                healthStore.getRequestStatusForAuthorization(toShare: Set<HKSampleType>(), read: readTypes) { status, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: status)
                    }
                }
            }

            switch status {
            case .unknown:
                setupState = .unknown
            case .shouldRequest:
                setupState = .requestAvailable
            case .unnecessary:
                setupState = .configuredInHealthApp
                startObserverQueriesIfNeeded()
            @unknown default:
                setupState = .unknown
            }
        } catch {
            setupState = .loadFailed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        }
    }

    func requestAuthorization() async {
        guard isHealthDataAvailable() else {
            setupState = .loadFailed("HealthKit unavailable on this device")
            return
        }

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                healthStore.requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: success)
                    }
                }
            }

            setupState = .configuredInHealthApp
            lastErrorMessage = nil
            startObserverQueriesIfNeeded()
        } catch {
            setupState = .loadFailed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        }
    }

    func startObserverQueriesIfNeeded() {
        guard !observersStarted else { return }
        guard isHealthDataAvailable() else { return }

        let sampleTypes = observerSampleTypes()
        guard !sampleTypes.isEmpty else { return }

        observersStarted = true

        for type in sampleTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
                defer { completionHandler() }

                if let error {
                    print("[HealthKitObserver] \(type.identifier) error=\(error.localizedDescription)")
                    return
                }

                print("[HealthKitObserver] \(type.identifier) changed")
                Task { @MainActor [weak self] in
                    self?.observerTick += 1
                }
            }
            observerQueries.append(query)
            healthStore.execute(query)

            healthStore.enableBackgroundDelivery(for: type, frequency: .hourly) { success, error in
                if let error {
                    print("[HealthKitObserver] background delivery failed for \(type.identifier): \(error.localizedDescription)")
                } else {
                    print("[HealthKitObserver] background delivery \(success ? "enabled" : "not enabled") for \(type.identifier)")
                }
            }
        }
    }

    private func observerSampleTypes() -> [HKSampleType] {
        var types: [HKSampleType] = [HKObjectType.workoutType()]

        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.append(sleep)
        }

        [
            HKQuantityType.quantityType(forIdentifier: .heartRate),
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate),
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            HKQuantityType.quantityType(forIdentifier: .stepCount)
        ]
        .compactMap { $0 }
        .forEach { types.append($0) }

        return types
    }

    func loadDailySnapshot() async -> DailyHealthSnapshot {
        var messages: [HealthMetric: String] = [:]
        var firstError: String?
        var loadedCount = 0

        let stepResult = await fetchTodayStepCount()
        messages[.stepCountToday] = stepResult.fallbackMessage
        if stepResult.value != nil { loadedCount += 1 }
        if firstError == nil { firstError = stepResult.errorMessage }

        let heartRateResult = await fetchLatestHeartRate()
        messages[.latestHeartRate] = heartRateResult.fallbackMessage
        if heartRateResult.value != nil { loadedCount += 1 }
        if firstError == nil { firstError = heartRateResult.errorMessage }
        let heartRateRange = await fetchTodayHeartRateRange()

        let restingHeartRateResult = await fetchLatestRestingHeartRate()
        messages[.latestRestingHeartRate] = restingHeartRateResult.fallbackMessage
        if restingHeartRateResult.value != nil { loadedCount += 1 }
        if firstError == nil { firstError = restingHeartRateResult.errorMessage }
        let restingHeartRateHistory = await fetchDailyAverageHistoryLast7Days(
            for: HKQuantityType.quantityType(forIdentifier: .restingHeartRate),
            unit: HKUnit.count().unitDivided(by: .minute()),
            metric: .latestRestingHeartRate
        )

        let hrvResult = await fetchLatestHRV()
        messages[.latestHRV] = hrvResult.fallbackMessage
        if hrvResult.value != nil { loadedCount += 1 }
        if firstError == nil { firstError = hrvResult.errorMessage }
        let hrvHistory = await fetchDailyAverageHistoryLast7Days(
            for: HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            unit: HKUnit.secondUnit(with: .milli),
            metric: .latestHRV
        )

        let workoutResult = await fetchMostRecentWorkoutSummary()
        messages[.latestWorkout] = workoutResult.fallbackMessage
        if workoutResult.value != nil { loadedCount += 1 }
        if firstError == nil { firstError = workoutResult.errorMessage }

        let sleepResult = await fetchSleepDataLast7Days()
        messages[.sleepDuration] = sleepResult.fallbackMessage
        if sleepResult.value?.lastNightHours != nil { loadedCount += 1 }
        if firstError == nil { firstError = sleepResult.errorMessage }

        metricMessages = messages
        successfulMetricCount = loadedCount
        lastLoadTimestamp = Date()
        lastErrorMessage = firstError

        if let firstError {
            setupState = .loadFailed(firstError)
        } else {
            setupState = .configuredInHealthApp
        }

        return DailyHealthSnapshot(
            date: Date(),
            lastNightSleepHours: sleepResult.value?.lastNightHours,
            recentSleepHistory: sleepResult.value?.history ?? [],
            latestHeartRate: heartRateResult.value,
            todayHeartRateRange: heartRateRange.value ?? DailyValueRange(minimum: nil, maximum: nil),
            restingHeartRate: restingHeartRateResult.value,
            recentRestingHeartRateHistory: restingHeartRateHistory.value ?? [],
            hrv: hrvResult.value,
            recentHRVHistory: hrvHistory.value ?? [],
            stepCountToday: stepResult.value,
            latestWorkout: workoutResult.value
        )
    }

    func loadBaselineFallbacks() async -> HealthKitBaselineFallbacks {
        async let sleep28 = fetchSleepBaseline28Days()
        async let restingHeartRate28 = fetchQuantityMedianLast28Days(
            for: HKQuantityType.quantityType(forIdentifier: .restingHeartRate),
            unit: HKUnit.count().unitDivided(by: .minute())
        )
        async let hrv28 = fetchQuantityMedianLast28Days(
            for: HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            unit: HKUnit.secondUnit(with: .milli)
        )
        async let steps28 = fetchDailyStepMedianLast28Days()

        return await HealthKitBaselineFallbacks(
            sleep28: sleep28,
            restingHeartRate28: restingHeartRate28,
            hrv28: hrv28,
            steps28: steps28
        )
    }

    func loadRecentWorkouts(days: Int = 14) async -> [WorkoutSummary] {
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: endDate) ?? endDate
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                let workouts = (samples as? [HKWorkout]) ?? []
                self.logBaselineDiagnostic(
                    metric: "recentWorkouts",
                    startDate: startDate,
                    endDate: endDate,
                    sampleCount: workouts.count,
                    error: error
                )

                guard error == nil else {
                    continuation.resume(returning: [])
                    return
                }

                let summaries = workouts.map {
                    WorkoutSummary(
                        type: Self.displayName(for: $0.workoutActivityType),
                        date: $0.endDate,
                        durationMinutes: $0.duration / 60.0
                    )
                }
                continuation.resume(returning: summaries)
            }

            healthStore.execute(query)
        }
    }

    func metricFallbackText(for metric: HealthMetric) -> String {
        metricMessages[metric] ?? "No samples returned"
    }

    private func fetchSleepDataLast7Days() async -> MetricFetchResult<(lastNightHours: Double?, history: [SleepHistoryEntry])> {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return MetricFetchResult(
                value: nil,
                sampleCount: 0,
                errorMessage: nil,
                fallbackMessage: "Permission may be configured but this metric has no recent entries"
            )
        }

        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: Date())) ?? Date()
        let endDate = Date()
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictStartDate])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, samples, error in
                let categorySamples = (samples as? [HKCategorySample]) ?? []
                self.logQueryDiagnostic(
                    metric: .sleepDuration,
                    startDate: startDate,
                    endDate: endDate,
                    sampleCount: categorySamples.count,
                    error: error
                )

                if let error {
                    continuation.resume(returning: MetricFetchResult(
                        value: nil,
                        sampleCount: categorySamples.count,
                        errorMessage: error.localizedDescription,
                        fallbackMessage: "Query failed: \(error.localizedDescription)"
                    ))
                    return
                }

                guard !categorySamples.isEmpty else {
                    continuation.resume(returning: MetricFetchResult(
                        value: (nil, []),
                        sampleCount: 0,
                        errorMessage: nil,
                        fallbackMessage: "No samples returned"
                    ))
                    return
                }

                let sleepIntervals = categorySamples
                    .filter { Self.isAsleepValue($0.value) }
                    .map { DateInterval(start: $0.startDate, end: $0.endDate) }
                let mergedIntervals = Self.mergeIntervals(sleepIntervals)
                let history = Self.buildSleepHistory(from: mergedIntervals, calendar: calendar, referenceDate: endDate)
                let lastNightHours = history.last(where: { $0.hours >= 2.0 })?.hours

                let fallbackMessage: String = lastNightHours == nil
                    ? "Permission may be configured but this metric has no recent entries"
                    : ""

                continuation.resume(returning: MetricFetchResult(
                    value: (lastNightHours, history),
                    sampleCount: categorySamples.count,
                    errorMessage: nil,
                    fallbackMessage: fallbackMessage
                ))
            }

            healthStore.execute(query)
        }
    }

    private func fetchLatestHeartRate() async -> MetricFetchResult<Double> {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return MetricFetchResult(value: nil, sampleCount: 0, errorMessage: nil, fallbackMessage: "No samples returned")
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        return await fetchLatestQuantityValue(for: type, unit: unit, metric: .latestHeartRate)
    }

    private func fetchTodayHeartRateRange() async -> MetricFetchResult<DailyValueRange> {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return MetricFetchResult(
                value: DailyValueRange(minimum: nil, maximum: nil),
                sampleCount: 0,
                errorMessage: nil,
                fallbackMessage: "No samples returned"
            )
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let endDate = Date()
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: endDate, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: [.discreteMin, .discreteMax]) { _, statistics, error in
                let minimum = statistics?.minimumQuantity()?.doubleValue(for: unit)
                let maximum = statistics?.maximumQuantity()?.doubleValue(for: unit)
                let sampleCount = (minimum == nil && maximum == nil) ? 0 : 1

                self.logQueryDiagnostic(
                    metric: .latestHeartRate,
                    startDate: startOfDay,
                    endDate: endDate,
                    sampleCount: sampleCount,
                    error: error
                )

                if let error {
                    continuation.resume(returning: MetricFetchResult(
                        value: DailyValueRange(minimum: nil, maximum: nil),
                        sampleCount: sampleCount,
                        errorMessage: error.localizedDescription,
                        fallbackMessage: "Query failed: \(error.localizedDescription)"
                    ))
                    return
                }

                continuation.resume(returning: MetricFetchResult(
                    value: DailyValueRange(minimum: minimum, maximum: maximum),
                    sampleCount: sampleCount,
                    errorMessage: nil,
                    fallbackMessage: sampleCount == 0 ? "No samples returned" : ""
                ))
            }

            healthStore.execute(query)
        }
    }

    private func fetchLatestRestingHeartRate() async -> MetricFetchResult<Double> {
        guard let type = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            return MetricFetchResult(value: nil, sampleCount: 0, errorMessage: nil, fallbackMessage: "No samples returned")
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        return await fetchLatestQuantityValue(for: type, unit: unit, metric: .latestRestingHeartRate)
    }

    private func fetchLatestHRV() async -> MetricFetchResult<Double> {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            return MetricFetchResult(value: nil, sampleCount: 0, errorMessage: nil, fallbackMessage: "No samples returned")
        }

        let unit = HKUnit.secondUnit(with: .milli)
        return await fetchLatestQuantityValue(for: type, unit: unit, metric: .latestHRV)
    }

    private func fetchTodayStepCount() async -> MetricFetchResult<Double> {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return MetricFetchResult(value: nil, sampleCount: 0, errorMessage: nil, fallbackMessage: "No samples returned")
        }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let endDate = Date()
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: endDate, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                let steps = statistics?.sumQuantity()?.doubleValue(for: .count())
                let sampleCount = steps == nil ? 0 : 1

                self.logQueryDiagnostic(
                    metric: .stepCountToday,
                    startDate: startOfDay,
                    endDate: endDate,
                    sampleCount: sampleCount,
                    error: error
                )

                if let error {
                    continuation.resume(returning: MetricFetchResult(
                        value: nil,
                        sampleCount: sampleCount,
                        errorMessage: error.localizedDescription,
                        fallbackMessage: "Query failed: \(error.localizedDescription)"
                    ))
                    return
                }

                guard let steps else {
                    continuation.resume(returning: MetricFetchResult(
                        value: nil,
                        sampleCount: 0,
                        errorMessage: nil,
                        fallbackMessage: "No samples returned"
                    ))
                    return
                }

                continuation.resume(returning: MetricFetchResult(
                    value: steps,
                    sampleCount: 1,
                    errorMessage: nil,
                    fallbackMessage: ""
                ))
            }

            healthStore.execute(query)
        }
    }

    private func fetchMostRecentWorkoutSummary() async -> MetricFetchResult<WorkoutSummary> {
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: nil, limit: 1, sortDescriptors: [sortDescriptor]) { _, samples, error in
                let workouts = (samples as? [HKWorkout]) ?? []

                self.logQueryDiagnostic(
                    metric: .latestWorkout,
                    startDate: nil,
                    endDate: nil,
                    sampleCount: workouts.count,
                    error: error
                )

                if let error {
                    continuation.resume(returning: MetricFetchResult(
                        value: nil,
                        sampleCount: workouts.count,
                        errorMessage: error.localizedDescription,
                        fallbackMessage: "Query failed: \(error.localizedDescription)"
                    ))
                    return
                }

                guard let workout = workouts.first else {
                    continuation.resume(returning: MetricFetchResult(
                        value: nil,
                        sampleCount: 0,
                        errorMessage: nil,
                        fallbackMessage: "Permission may be configured but this metric has no recent entries"
                    ))
                    return
                }

                continuation.resume(returning: MetricFetchResult(
                    value: WorkoutSummary(
                        type: Self.displayName(for: workout.workoutActivityType),
                        date: workout.endDate,
                        durationMinutes: workout.duration / 60.0
                    ),
                    sampleCount: workouts.count,
                    errorMessage: nil,
                    fallbackMessage: ""
                ))
            }

            healthStore.execute(query)
        }
    }

    private func fetchLatestQuantityValue(for type: HKQuantityType, unit: HKUnit, metric: HealthMetric) async -> MetricFetchResult<Double> {
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -30, to: endDate)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictEndDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { _, samples, error in
                let quantitySamples = (samples as? [HKQuantitySample]) ?? []

                self.logQueryDiagnostic(
                    metric: metric,
                    startDate: startDate,
                    endDate: endDate,
                    sampleCount: quantitySamples.count,
                    error: error
                )

                if let error {
                    continuation.resume(returning: MetricFetchResult(
                        value: nil,
                        sampleCount: quantitySamples.count,
                        errorMessage: error.localizedDescription,
                        fallbackMessage: "Query failed: \(error.localizedDescription)"
                    ))
                    return
                }

                guard let sample = quantitySamples.first else {
                    continuation.resume(returning: MetricFetchResult(
                        value: nil,
                        sampleCount: 0,
                        errorMessage: nil,
                        fallbackMessage: "Permission may be configured but this metric has no recent entries"
                    ))
                    return
                }

                continuation.resume(returning: MetricFetchResult(
                    value: sample.quantity.doubleValue(for: unit),
                    sampleCount: quantitySamples.count,
                    errorMessage: nil,
                    fallbackMessage: ""
                ))
            }

            healthStore.execute(query)
        }
    }

    private func fetchDailyAverageHistoryLast7Days(
        for type: HKQuantityType?,
        unit: HKUnit,
        metric: HealthMetric
    ) async -> MetricFetchResult<[QuantityHistoryEntry]> {
        guard let type else {
            return MetricFetchResult(value: [], sampleCount: 0, errorMessage: nil, fallbackMessage: "No samples returned")
        }

        let calendar = Calendar.current
        let endDate = Date()
        let anchorDate = calendar.startOfDay(for: endDate)
        let startDate = calendar.date(byAdding: .day, value: -6, to: anchorDate) ?? anchorDate
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage,
                anchorDate: anchorDate,
                intervalComponents: DateComponents(day: 1)
            )

            query.initialResultsHandler = { _, collection, error in
                self.logQueryDiagnostic(
                    metric: metric,
                    startDate: startDate,
                    endDate: endDate,
                    sampleCount: collection == nil ? 0 : 7,
                    error: error
                )

                if let error {
                    continuation.resume(returning: MetricFetchResult(
                        value: [],
                        sampleCount: 0,
                        errorMessage: error.localizedDescription,
                        fallbackMessage: "Query failed: \(error.localizedDescription)"
                    ))
                    return
                }

                guard let collection else {
                    continuation.resume(returning: MetricFetchResult(
                        value: [],
                        sampleCount: 0,
                        errorMessage: nil,
                        fallbackMessage: "No samples returned"
                    ))
                    return
                }

                var history: [QuantityHistoryEntry] = []
                collection.enumerateStatistics(from: startDate, to: anchorDate) { statistics, _ in
                    guard let average = statistics.averageQuantity()?.doubleValue(for: unit) else { return }
                    history.append(QuantityHistoryEntry(date: statistics.startDate, value: average))
                }

                continuation.resume(returning: MetricFetchResult(
                    value: history,
                    sampleCount: history.count,
                    errorMessage: nil,
                    fallbackMessage: history.isEmpty ? "No samples returned" : ""
                ))
            }

            healthStore.execute(query)
        }
    }

    private func fetchSleepBaseline28Days() async -> Double? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return nil
        }

        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -35, to: calendar.startOfDay(for: endDate)) ?? endDate
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictStartDate])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, samples, error in
                let categorySamples = (samples as? [HKCategorySample]) ?? []
                self.logBaselineDiagnostic(
                    metric: "sleep28",
                    startDate: startDate,
                    endDate: endDate,
                    sampleCount: categorySamples.count,
                    error: error
                )

                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let sleepIntervals = categorySamples
                    .filter { Self.isAsleepValue($0.value) }
                    .map { DateInterval(start: $0.startDate, end: $0.endDate) }
                let mergedIntervals = Self.mergeIntervals(sleepIntervals)
                let history = Self.buildSleepHistory(
                    from: mergedIntervals,
                    calendar: calendar,
                    referenceDate: endDate,
                    dayCount: 28
                )
                let validHours = history.map(\.hours).filter { $0 >= 2.0 }
                continuation.resume(returning: Self.median(validHours))
            }

            healthStore.execute(query)
        }
    }

    private func fetchQuantityMedianLast28Days(for type: HKQuantityType?, unit: HKUnit) async -> Double? {
        guard let type else { return nil }

        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -35, to: endDate) ?? endDate
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictEndDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, samples, error in
                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                self.logBaselineDiagnostic(
                    metric: type.identifier,
                    startDate: startDate,
                    endDate: endDate,
                    sampleCount: quantitySamples.count,
                    error: error
                )

                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let values = quantitySamples.map { $0.quantity.doubleValue(for: unit) }
                continuation.resume(returning: Self.median(values))
            }

            healthStore.execute(query)
        }
    }

    private func fetchDailyStepMedianLast28Days() async -> Double? {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return nil
        }

        let calendar = Calendar.current
        let endDate = Date()
        let anchorDate = calendar.startOfDay(for: endDate)
        let startDate = calendar.date(byAdding: .day, value: -28, to: anchorDate) ?? anchorDate
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: DateComponents(day: 1)
            )

            query.initialResultsHandler = { _, collection, error in
                self.logBaselineDiagnostic(
                    metric: "stepCount28",
                    startDate: startDate,
                    endDate: endDate,
                    sampleCount: collection == nil ? 0 : 28,
                    error: error
                )

                guard error == nil, let collection else {
                    continuation.resume(returning: nil)
                    return
                }

                var dailyValues: [Double] = []
                collection.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
                    dailyValues.append(statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0)
                }

                continuation.resume(returning: Self.median(dailyValues.filter { $0 > 0 }))
            }

            self.healthStore.execute(query)
        }
    }

    nonisolated private func logQueryDiagnostic(metric: HealthMetric, startDate: Date?, endDate: Date?, sampleCount: Int, error: Error?) {
        let startText = Self.logDateText(startDate)
        let endText = Self.logDateText(endDate)
        let errorText = error?.localizedDescription ?? "none"

        print("[HealthKit] metric=\(metric.rawValue) range=\(startText) -> \(endText) samples=\(sampleCount) error=\(errorText)")
    }

    nonisolated private func logBaselineDiagnostic(metric: String, startDate: Date?, endDate: Date?, sampleCount: Int, error: Error?) {
        let startText = Self.logDateText(startDate)
        let endText = Self.logDateText(endDate)
        let errorText = error?.localizedDescription ?? "none"
        print("[HealthKitBaseline] metric=\(metric) range=\(startText) -> \(endText) samples=\(sampleCount) error=\(errorText)")
    }

    nonisolated private static func logDateText(_ date: Date?) -> String {
        guard let date else { return "none" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func isAsleepValue(_ rawValue: Int) -> Bool {
        if #available(iOS 16.0, *) {
            return rawValue == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                || rawValue == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                || rawValue == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                || rawValue == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
        }

        return rawValue == HKCategoryValueSleepAnalysis.asleep.rawValue
    }

    nonisolated private static func mergeIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }

        var merged: [DateInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        return merged
    }

    nonisolated private static func buildSleepHistory(from intervals: [DateInterval], calendar: Calendar, referenceDate: Date, dayCount: Int = 7) -> [SleepHistoryEntry] {
        let today = calendar.startOfDay(for: referenceDate)
        let firstMorning = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today

        return (0..<dayCount).compactMap { offset in
            guard let morning = calendar.date(byAdding: .day, value: offset, to: firstMorning),
                  let windowStart = calendar.date(byAdding: .hour, value: -18, to: morning),
                  let windowEnd = calendar.date(byAdding: .hour, value: 14, to: morning),
                  let overnightStart = calendar.date(byAdding: .hour, value: -3, to: windowStart),
                  let overnightEnd = calendar.date(byAdding: .hour, value: 10, to: morning) else {
                return nil
            }

            let clippedIntervals = intervals.compactMap { interval -> DateInterval? in
                let overlapStart = max(interval.start, windowStart)
                let overlapEnd = min(interval.end, windowEnd)
                guard overlapEnd > overlapStart else { return nil }
                return DateInterval(start: overlapStart, end: overlapEnd)
            }

            let clusters = clusterSleepIntervals(clippedIntervals, maxGapMinutes: 90)
            guard let mainCluster = dominantSleepCluster(
                from: clusters,
                preferredWindow: DateInterval(start: overnightStart, end: overnightEnd)
            ) else {
                return SleepHistoryEntry(date: morning, hours: 0)
            }

            let hours = mainCluster.totalAsleepSeconds / 3600.0
            guard hours >= 2.0 else { return SleepHistoryEntry(date: morning, hours: 0) }
            return SleepHistoryEntry(date: morning, hours: hours)
        }
    }

    nonisolated private static func clusterSleepIntervals(_ intervals: [DateInterval], maxGapMinutes: Double) -> [SleepCluster] {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return [] }

        let maxGap = maxGapMinutes * 60.0
        var clusters: [SleepCluster] = []
        var currentIntervals: [DateInterval] = [first]

        for interval in sorted.dropFirst() {
            let previousEnd = currentIntervals.last?.end ?? interval.start
            if interval.start.timeIntervalSince(previousEnd) <= maxGap {
                currentIntervals.append(interval)
            } else {
                clusters.append(SleepCluster(intervals: currentIntervals))
                currentIntervals = [interval]
            }
        }

        clusters.append(SleepCluster(intervals: currentIntervals))
        return clusters
    }

    nonisolated private static func dominantSleepCluster(from clusters: [SleepCluster], preferredWindow: DateInterval) -> SleepCluster? {
        clusters.max { lhs, rhs in
            let lhsPreferred = lhs.overlapSeconds(with: preferredWindow)
            let rhsPreferred = rhs.overlapSeconds(with: preferredWindow)
            if lhsPreferred == rhsPreferred {
                return lhs.totalAsleepSeconds < rhs.totalAsleepSeconds
            }
            return lhsPreferred < rhsPreferred
        }
    }

    nonisolated private static func displayName(for activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running:
            return "Running"
        case .walking:
            return "Walking"
        case .cycling:
            return "Cycling"
        case .swimming:
            return "Swimming"
        case .traditionalStrengthTraining:
            return "Strength Training"
        case .functionalStrengthTraining:
            return "Functional Strength"
        case .hiking:
            return "Hiking"
        case .yoga:
            return "Yoga"
        default:
            return "Other Workout"
        }
    }

    nonisolated private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}

private struct SleepCluster {
    let intervals: [DateInterval]
    let start: Date
    let end: Date
    let totalAsleepSeconds: Double

    nonisolated init(intervals: [DateInterval]) {
        self.intervals = intervals
        self.start = intervals.first?.start ?? .distantPast
        self.end = intervals.last?.end ?? .distantPast
        self.totalAsleepSeconds = intervals.reduce(0) { $0 + $1.duration }
    }

    nonisolated func overlapSeconds(with window: DateInterval) -> Double {
        intervals.reduce(0) { partial, interval in
            let overlapStart = max(interval.start, window.start)
            let overlapEnd = min(interval.end, window.end)
            guard overlapEnd > overlapStart else { return partial }
            return partial + overlapEnd.timeIntervalSince(overlapStart)
        }
    }
}
