import SwiftUI
import Combine

private enum AppTab: String {
    case dashboard
    case today
    case exercises
    case profile
    case history
    case settings
}

private enum ProfileField: Hashable {
    case height
    case weight
    case age
    case fiveK
    case pushups
    case pullups
    case bench
    case lat
    case squat
    case equipment
}

struct ContentView: View {
    @EnvironmentObject private var localization: LocalizationManager
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var healthKitManager = HealthKitManager()
    @StateObject private var historyStore = LocalHistoryStore()
    @StateObject private var profileStore = UserProfileStore()
    @StateObject private var exerciseStore = ExerciseCatalogStore()
    @StateObject private var weatherManager = WeatherContextManager()

    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("debugMode") private var debugMode = false
    @AppStorage("lastMorningAutoRefresh") private var lastMorningAutoRefresh = ""

    @State private var selectedTab: AppTab = .dashboard
    @State private var snapshot: DailyHealthSnapshot = .empty
    @State private var baseline: PersonalBaseline = .empty
    @State private var healthKitBaselineFallbacks: HealthKitBaselineFallbacks = .empty
    @State private var recoveryMap: [MuscleGroup: MuscleRecoveryStatus] = [:]
    @State private var recommendation: DailyRecommendation = .fallback
    @State private var routineRecommendation: RoutineRecommendation = .init(priority: .lightTonight, bedtimeHour: 23, bedtimeMinute: 0, explanationKeys: ["routine.reason.stable"], weatherKey: nil)
    @State private var isLoading = false
    @State private var lastAutoRefreshAt: Date = .distantPast

    @State private var draftProfile = UserProfile(
        heightCm: 170,
        weightKg: 70,
        age: nil,
        biologicalSex: .preferNotToSay,
        goal: .generalHealth,
        experience: .beginner,
        estimated5kMinutes: nil,
        maxPushUps: nil,
        maxPullUps: nil,
        estimatedBenchPressKg: nil,
        estimatedLatPulldownKg: nil,
        estimatedSquatKg: nil,
        hasGymAccess: true,
        equipmentNotes: ""
    )

    @State private var customExerciseName = ""
    @State private var customExerciseCategory: ExerciseCategory = .strength
    @State private var customExerciseEquipment: EquipmentType = .other
    @State private var customPrimaryMuscle: MuscleGroup = .cardioSystemic

    @State private var feedbackNote = ""

    @State private var profileMessage: String?
    @State private var profileValidationError: String?
    @State private var profileBannerKind: ProfileBannerKind?
    @State private var showResetConfirmation = false

    @FocusState private var focusedField: ProfileField?

    private enum ProfileBannerKind {
        case success
        case error
    }

    private struct DailyStatusState {
        let score: Int
        let label: String
        let reason: String
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            dashboardTab
                .tabItem { Label(t("tab.dashboard"), systemImage: "house.fill") }
                .tag(AppTab.dashboard)

            todayTab
                .tabItem { Label(t("tab.today"), systemImage: "figure.run.circle.fill") }
                .tag(AppTab.today)

            exercisesTab
                .tabItem { Label(t("tab.exercises"), systemImage: "dumbbell.fill") }
                .tag(AppTab.exercises)

            profileTab
                .tabItem { Label(t("tab.profile"), systemImage: "person.crop.circle.fill") }
                .tag(AppTab.profile)

            historyTab
                .tabItem { Label(t("tab.history"), systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)

            settingsTab
                .tabItem { Label(t("tab.settings"), systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(AppTheme.accentPrimary)
        .preferredColorScheme(.dark)
        .task {
            if let saved = profileStore.profile {
                draftProfile = saved
            }
            recomputeDerivedState()
            await autoRefreshIfNeeded(force: true, reason: "initial")
            await runMorningWorkflowIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await autoRefreshIfNeeded(reason: "sceneActive") }
            }
        }
        .onReceive(healthKitManager.$observerTick.dropFirst()) { _ in
            Task { await autoRefreshIfNeeded(force: true, reason: "healthObserver") }
        }
        .onChange(of: historyStore.records.count) { _, _ in recomputeDerivedState() }
        .onChange(of: historyStore.sessions.count) { _, _ in recomputeDerivedState() }
        .onChange(of: historyStore.passiveResponses.count) { _, _ in recomputeDerivedState() }
    }

    private var dashboardTab: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [AppTheme.backgroundTop, AppTheme.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("dashboard.title"))
                                .font(AppTheme.title)
                            Text(t("dashboard.subtitle"))
                                .font(AppTheme.body)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Card(title: t("dashboard.readiness"), tint: AppTheme.accentPrimary) {
                            TimelineView(.periodic(from: .now, by: 300)) { context in
                                let status = dailyStatus(at: context.date)
                                HStack(spacing: 16) {
                                    CircularGauge(value: status.score, tint: AppTheme.accentPrimary)
                                        .frame(width: 78, height: 78)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(status.label)
                                            .font(.system(size: 22, weight: .bold, design: .rounded))
                                        Text(todayHeadline)
                                            .font(AppTheme.bodyStrong)
                                        Text(status.reason)
                                            .font(AppTheme.caption)
                                            .foregroundStyle(.secondary)
                                        Text(todaySubheadline)
                                            .font(AppTheme.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        Card(title: t("dashboard.routine"), tint: AppTheme.accentWarm) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(localizedRoutinePriority(routineRecommendation.priority))
                                        .font(AppTheme.bodyStrong)
                                    Spacer()
                                    Text(String(format: t("dashboard.bedtime"), routineRecommendation.bedtimeHour, routineRecommendation.bedtimeMinute))
                                        .font(AppTheme.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(localizedRoutineExplanation(routineRecommendation.explanationKeys))
                                    .font(AppTheme.body)
                                    .foregroundStyle(.secondary)
                                if let weatherKey = routineRecommendation.weatherKey {
                                    Text(localizedRoutineExplanation(weatherKey))
                                        .font(AppTheme.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Card(title: t("label.sleep"), tint: AppTheme.accentSecondary) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(snapshot.lastNightSleepHours.map { String(format: "%.1f h", $0) } ?? localizedFallback(for: .sleepDuration))
                                        .font(AppTheme.bodyStrong)
                                    Spacer()
                                    deltaPill(current: snapshot.lastNightSleepHours, baselineValue: baseline.sleep.rolling28, lowerIsBetter: false)
                                }
                                MiniBarChart(values: recentSleepValues, baseline: baseline.sleep.rolling28, tint: AppTheme.accentSecondary)
                                    .frame(height: 74)
                            }
                        }

                        Card(title: t("label.restingHR"), tint: AppTheme.accentWarm) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(snapshot.restingHeartRate.map { "\(Int($0.rounded())) bpm" } ?? localizedFallback(for: .latestRestingHeartRate))
                                            .font(.system(size: 28, weight: .bold, design: .rounded))
                                        Text(rhrStatusMeaning)
                                            .font(AppTheme.body)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 8) {
                                        deltaPill(current: snapshot.restingHeartRate, baselineValue: baseline.restingHeartRate.rolling28, lowerIsBetter: true)
                                        statusPill(title: rhrStatusTitle, color: rhrStatusColor)
                                    }
                                }

                                TrendSparkline(
                                    values: restingTrendValues,
                                    reference: restingTrendAverage,
                                    baseline: nil,
                                    tint: AppTheme.accentWarm
                                )
                                .frame(height: 94)

                                HStack(spacing: 8) {
                                    MetricMetaPill(
                                        title: t("label.weekAverage"),
                                        value: restingTrendAverage.map { "\(Int($0.rounded())) bpm" } ?? t("common.nA")
                                    )
                                    MetricMetaPill(
                                        title: t("label.baseline"),
                                        value: baseline.restingHeartRate.rolling28.map { "\(Int($0.rounded())) bpm" } ?? t("common.nA")
                                    )
                                    MetricMetaPill(
                                        title: t("label.todayLow"),
                                        value: snapshot.todayHeartRateRange.minimum.map { "\(Int($0.rounded())) bpm" } ?? t("common.nA")
                                    )
                                    MetricMetaPill(
                                        title: t("label.todayHigh"),
                                        value: snapshot.todayHeartRateRange.maximum.map { "\(Int($0.rounded())) bpm" } ?? t("common.nA")
                                    )
                                }
                                Text(rhrAnalysisText)
                                    .font(AppTheme.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Card(title: t("label.hrv"), tint: AppTheme.accentPrimary) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(snapshot.hrv.map { String(format: "%.0f ms", $0) } ?? localizedFallback(for: .latestHRV))
                                            .font(.system(size: 28, weight: .bold, design: .rounded))
                                        Text(hrvStatusMeaning)
                                            .font(AppTheme.body)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 8) {
                                        deltaPill(current: snapshot.hrv, baselineValue: baseline.hrv.rolling28, lowerIsBetter: false)
                                        statusPill(title: hrvStatusTitle, color: hrvStatusColor)
                                    }
                                }

                                TrendSparkline(
                                    values: hrvTrendValues,
                                    reference: hrvTrendAverage,
                                    baseline: nil,
                                    tint: AppTheme.accentPrimary
                                )
                                .frame(height: 94)

                                HStack {
                                    MetricMetaPill(
                                        title: t("label.weekAverage"),
                                        value: hrvTrendAverage.map { String(format: "%.0f ms", $0) } ?? t("common.nA")
                                    )
                                    Spacer()
                                    MetricMetaPill(
                                        title: t("label.baseline"),
                                        value: baseline.hrv.rolling28.map { String(format: "%.0f ms", $0) } ?? t("common.nA")
                                    )
                                }
                                Text(hrvAnalysisText)
                                    .font(AppTheme.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Card(title: t("label.steps"), tint: AppTheme.accentSecondary) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(snapshot.stepCountToday.map { "\(Int($0.rounded()))" } ?? localizedFallback(for: .stepCountToday))
                                        .font(AppTheme.bodyStrong)
                                    Spacer()
                                    Text("\(t("label.expectedNow")) \(Int(expectedStepsByNow.rounded()))")
                                        .font(AppTheme.caption)
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: stepProgress)
                                    .tint(AppTheme.accentPrimary)
                                HStack {
                                    Text("\(t("label.target")) \(Int(todayStepGoal.rounded()))")
                                    Spacer()
                                    Text(stepStatusText)
                                }
                                    .font(AppTheme.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Card(title: t("dashboard.recovery"), tint: AppTheme.accentWarm) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(t("label.passiveScore")): \(historyStore.passiveSummary.recentAverageScore)")
                                    .font(AppTheme.bodyStrong)
                                Text(workoutBalanceText)
                                    .font(AppTheme.caption)
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
                                    RecoveryHeatChip(title: localization.muscleGroup(.chest), score: recoveryScore(.chest))
                                    RecoveryHeatChip(title: localization.muscleGroup(.back), score: recoveryScore(.back))
                                    RecoveryHeatChip(title: t("label.arms"), score: armRecoveryScore)
                                    RecoveryHeatChip(title: localization.muscleGroup(.quads), score: recoveryScore(.quads))
                                    RecoveryHeatChip(title: localization.muscleGroup(.hamstrings), score: recoveryScore(.hamstrings))
                                    RecoveryHeatChip(title: localization.muscleGroup(.glutes), score: recoveryScore(.glutes))
                                    RecoveryHeatChip(title: localization.muscleGroup(.calves), score: recoveryScore(.calves))
                                    RecoveryHeatChip(title: localization.muscleGroup(.adductors), score: recoveryScore(.adductors))
                                }

                                HStack {
                                    Text(t("label.systemic"))
                                        .font(AppTheme.caption.weight(.semibold))
                                    Spacer()
                                    Capsule()
                                        .fill(recoveryColor(for: recoveryScore(.cardioSystemic)))
                                        .frame(width: 24, height: 10)
                                    Text(systemicRecoveryText)
                                        .font(AppTheme.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if debugMode {
                            Card(title: t("dashboard.debug"), tint: .gray) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("\(t("label.lastLoad")): \(lastLoadText)")
                                    Text("\(t("label.lastError")): \(healthKitManager.lastErrorMessage.map(localization.fallbackText) ?? t("common.none"))")
                                    Text("\(t("label.metricsLoaded")): \(healthKitManager.successfulMetricCount)/6")
                                    Text("\(t("label.enabledExercises")): \(exerciseStore.enabledExercises.count)")
                                    Divider().overlay(Color.white.opacity(0.08))
                                    Text(t("label.recScores"))
                                        .font(AppTheme.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Recovery \(recommendation.scores.recoveryScore) • Activation \(recommendation.scores.activationNeedScore) • Balance \(recommendation.scores.trainingBalanceScore)")
                                    Text("Muscle \(recommendation.scores.muscleReadinessScore) • Passive \(recommendation.scores.passiveRecoveryResponseScore) • Confidence \(recommendation.scores.confidenceScore)")
                                    Divider().overlay(Color.white.opacity(0.08))
                                    Text(t("label.scoreDrivers"))
                                        .font(AppTheme.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    ForEach(Array(recommendation.scoreDrivers.enumerated()), id: \.offset) { _, driver in
                                        Text("• \(driver)")
                                    }
                                }
                                .font(AppTheme.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .refreshable {
                    await loadData()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isLoading ? t("common.loading") : t("button.refresh")) {
                        Task { await loadData() }
                    }
                    .disabled(isLoading || !healthKitManager.canLoadData)
                }
            }
            .onAppear {
                Task { await autoRefreshIfNeeded(reason: "homeAppear") }
            }
        }
    }

    private var todayTab: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [AppTheme.backgroundTop, AppTheme.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        if historyStore.hasCompletedRecommendationToday, let session = historyStore.latestSession() {
                            Card(title: t("today.completedCard"), tint: AppTheme.accentPrimary) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(t("today.doneTitle"))
                                        .font(.system(size: 22, weight: .bold, design: .rounded))
                                    Text(completedSessionSummary(session))
                                        .font(AppTheme.body)
                                    Text(t("today.encouragement"))
                                        .font(AppTheme.body)
                                        .foregroundStyle(.secondary)
                                    Text(t("today.recoveryAdvice"))
                                        .font(AppTheme.caption)
                                        .foregroundStyle(.secondary)
                                    Text(tomorrowDirectionText)
                                        .font(AppTheme.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Card(title: t("today.statusCard"), tint: AppTheme.accentSecondary) {
                                TimelineView(.periodic(from: .now, by: 300)) { context in
                                    let status = dailyStatus(at: context.date)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(todayHeadline)
                                            .font(.system(size: 22, weight: .bold, design: .rounded))
                                        Text(todaySubheadline)
                                            .font(AppTheme.body)
                                        Text(String(format: t("dashboard.statusWithScore"), status.score))
                                            .font(AppTheme.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.accentPrimary)
                                        Text(status.reason)
                                            .font(AppTheme.caption)
                                            .foregroundStyle(.secondary)
                                        Text(todaySummaryText)
                                            .font(AppTheme.body)
                                            .foregroundStyle(.secondary)
                                        Text("\(t("label.confidence")): \(recommendation.confidenceLevel)%")
                                            .font(AppTheme.caption)
                                            .foregroundStyle(.secondary)
                                        if let safety = recommendation.safetyMessage {
                                            Text("\(t("label.safety")): \(localization.fallbackText(safety))")
                                                .font(AppTheme.caption.weight(.semibold))
                                                .foregroundStyle(.red)
                                        }
                                    }
                                }
                            }

                            if historyStore.activeSessionStart == nil {
                                Card(title: t("today.plan"), tint: AppTheme.accentWarm) {
                                    if recommendation.exercises.isEmpty {
                                        Text(t("today.noSpecific"))
                                            .font(AppTheme.body)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        VStack(spacing: 10) {
                                            ForEach(recommendation.exercises) { item in
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(localizedExerciseName(id: item.exerciseID, fallback: item.name))
                                                        .font(AppTheme.bodyStrong)
                                                    Text(planLine(for: item))
                                                        .font(AppTheme.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }
                                }
                            }

                            Card(title: t("today.sessionStatus"), tint: AppTheme.accentPrimary) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let start = historyStore.activeSessionStart {
                                        Text("\(t("label.startedAt")): \(start.formatted(date: .omitted, time: .shortened))")
                                            .font(AppTheme.caption)
                                            .foregroundStyle(.secondary)
                                        TimelineView(.periodic(from: start, by: 60)) { context in
                                            Text("\(t("today.elapsed")) \(elapsedMinutesText(since: start, now: context.date))")
                                                .font(AppTheme.body)
                                        }
                                        Button(t("button.endSession")) {
                                            Task { await completeSession() }
                                        }
                                        .buttonStyle(.borderedProminent)
                                    } else {
                                        Button(t("button.startSession")) {
                                            historyStore.startSession()
                                            recomputeDerivedState()
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }
                            }
                        }

                        Card(title: t("today.optionalFeedback"), tint: AppTheme.accentSecondary) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(t("feedback.hint"))
                                    .font(AppTheme.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    feedbackButton(localization.effort(.tooEasy), selected: historyStore.todayRecord()?.perceivedEffort == .tooEasy) {
                                        historyStore.setPerceivedEffort(.tooEasy)
                                        recomputeDerivedState()
                                    }
                                    feedbackButton(localization.effort(.good), selected: historyStore.todayRecord()?.perceivedEffort == .good) {
                                        historyStore.setPerceivedEffort(.good)
                                        recomputeDerivedState()
                                    }
                                    feedbackButton(localization.effort(.tooHard), selected: historyStore.todayRecord()?.perceivedEffort == .tooHard) {
                                        historyStore.setPerceivedEffort(.tooHard)
                                        recomputeDerivedState()
                                    }
                                }
                                TextField(t("feedback.note"), text: $feedbackNote)
                                    .textFieldStyle(.roundedBorder)
                                Button(t("button.saveNote")) {
                                    historyStore.setFeedbackNote(feedbackNote)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                }
                .padding(16)
                .refreshable {
                    await loadData()
                }
            }
            }
            .navigationTitle(t("tab.today"))
        }
    }

    private var exercisesTab: some View {
        NavigationStack {
            Form {
                Section(t("exercise.enable")) {
                    ForEach(exerciseStore.allExercises) { exercise in
                        Toggle(isOn: Binding(
                            get: { exerciseStore.isEnabled(exercise) },
                            set: { _ in
                                exerciseStore.toggleExercise(exercise)
                                recomputeDerivedState()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(localization.exerciseDisplayName(for: exercise))
                                Text("\(localization.exerciseCategory(exercise.category)) • \(localization.equipment(exercise.equipmentType))")
                                    .font(AppTheme.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section(t("exercise.custom")) {
                    TextField(t("exercise.name"), text: $customExerciseName)
                    Picker(t("exercise.category"), selection: $customExerciseCategory) {
                        ForEach(ExerciseCategory.allCases, id: \.self) { category in
                            Text(localization.exerciseCategory(category)).tag(category)
                        }
                    }
                    Picker(t("exercise.equipment"), selection: $customExerciseEquipment) {
                        ForEach(EquipmentType.allCases, id: \.self) { equipment in
                            Text(localization.equipment(equipment)).tag(equipment)
                        }
                    }
                    Picker(t("exercise.primary"), selection: $customPrimaryMuscle) {
                        ForEach(MuscleGroup.allCases, id: \.self) { muscle in
                            Text(localization.muscleGroup(muscle)).tag(muscle)
                        }
                    }
                    Button(t("button.add")) {
                        let trimmed = customExerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        exerciseStore.addCustomExercise(
                            name: trimmed,
                            category: customExerciseCategory,
                            equipment: customExerciseEquipment,
                            primary: [customPrimaryMuscle],
                            secondary: [],
                            movement: customExerciseCategory == .mobility ? .mobility : .isolation,
                            mode: customExerciseCategory == .strength ? .setsRepsLoad : .durationBased
                        )
                        customExerciseName = ""
                        recomputeDerivedState()
                    }
                }
            }
            .navigationTitle(t("tab.exercises"))
        }
    }

    private var profileTab: some View {
        NavigationStack {
            Form {
                Section(t("profile.basic")) {
                    valueRow(title: t("field.height"), value: $draftProfile.heightCm, field: .height)
                    valueRow(title: t("field.weight"), value: $draftProfile.weightKg, field: .weight)
                    intRow(title: t("field.age"), value: $draftProfile.age, field: .age)
                    Picker(t("field.sex"), selection: $draftProfile.biologicalSex) {
                        ForEach(BiologicalSex.allCases, id: \.self) { sex in
                            Text(localization.biologicalSex(sex)).tag(sex)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(t("profile.goal")) {
                    Picker(t("field.goal"), selection: $draftProfile.goal) {
                        ForEach(TrainingGoal.allCases, id: \.self) { goal in
                            Text(localization.trainingGoal(goal)).tag(goal)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draftProfile.goal) { _, newValue in
                        print("[Profile] goal changed -> \(newValue.rawValue)")
                    }
                    Picker(t("field.experience"), selection: $draftProfile.experience) {
                        ForEach(TrainingExperience.allCases, id: \.self) { level in
                            Text(localization.experience(level)).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(t("field.gym"), isOn: $draftProfile.hasGymAccess)
                    TextField(t("field.equipmentNotes"), text: $draftProfile.equipmentNotes)
                        .focused($focusedField, equals: .equipment)
                }

                Section(t("profile.self")) {
                    optionalValueRow(title: t("field.5k"), value: $draftProfile.estimated5kMinutes, field: .fiveK)
                    intRow(title: t("field.pushups"), value: $draftProfile.maxPushUps, field: .pushups)
                    intRow(title: t("field.pullups"), value: $draftProfile.maxPullUps, field: .pullups)
                    optionalValueRow(title: t("field.bench"), value: $draftProfile.estimatedBenchPressKg, field: .bench)
                    optionalValueRow(title: t("field.lat"), value: $draftProfile.estimatedLatPulldownKg, field: .lat)
                    optionalValueRow(title: t("field.squat"), value: $draftProfile.estimatedSquatKg, field: .squat)
                }

                Section {
                    if let saved = profileStore.lastSavedAt {
                        Text("\(t("profile.savedAt")): \(saved.formatted(date: .abbreviated, time: .shortened))")
                            .font(AppTheme.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(t("profile.complete")): \(profileStore.isProfileSufficientForRecommendations ? t("profile.completeYes") : t("profile.completeNo"))")
                        .font(AppTheme.caption)
                        .foregroundStyle(profileStore.isProfileSufficientForRecommendations ? .green : .orange)

                    Button {
                        print("[Profile] save tapped")
                        saveProfile()
                    } label: {
                        Text(t("button.saveProfile"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .navigationTitle(t("tab.profile"))
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    if focusedField != nil {
                        focusedField = nil
                    }
                },
                including: .gesture
            )
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(t("button.done")) { focusedField = nil }
                }
            }
            .overlay(alignment: .top) {
                if let text = profileBannerText {
                    Text(text)
                        .font(AppTheme.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill((profileBannerKind == .success ? Color.green : Color.red).opacity(0.9))
                        )
                        .padding(.top, 8)
                }
            }
        }
    }

    private var historyTab: some View {
        NavigationStack {
            List {
                Section(t("history.passive")) {
                    if historyStore.passiveResponses.isEmpty {
                        Text(t("common.noData"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(historyStore.passiveResponses.reversed()) { response in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(response.responseDate.formatted(date: .abbreviated, time: .omitted))
                                    .font(AppTheme.bodyStrong)
                                Text("\(t("label.score")): \(response.score) • \(localization.passiveSummary(response.summary))")
                                    .font(AppTheme.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section(t("history.sessions")) {
                    if historyStore.sessions.isEmpty {
                        Text(t("common.noData"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(historyStore.sessions.reversed()) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(AppTheme.bodyStrong)
                                Text("\(t("label.intensity")): \(localization.intensity(session.sessionIntensity)) • \(t("label.planned")) \(String(format: "%.1f", session.plannedVolumeScore)) / \(t("label.completed")) \(String(format: "%.1f", session.completedVolumeScore))")
                                    .font(AppTheme.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(t("tab.history"))
        }
    }

    private var settingsTab: some View {
        NavigationStack {
            Form {
                Section(t("settings.language")) {
                    Picker(t("settings.language"), selection: Binding(
                        get: { localization.language },
                        set: { localization.setLanguage($0) }
                    )) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                }

                Section(t("settings.health")) {
                    Button(t("button.requestHealth")) { Task { await requestAccess() } }
                    Button(t("settings.reloadNow")) { Task { await loadData() } }
                }

                Section(t("settings.diagnostics")) {
                    Text(localization.statusText(healthKitManager.setupState))
                    Text("\(t("label.lastLoad")): \(lastLoadText)")
                    Text("\(t("label.lastError")): \(healthKitManager.lastErrorMessage.map(localization.fallbackText) ?? t("common.none"))")
                    Text("\(t("label.metricsLoaded")): \(healthKitManager.successfulMetricCount)/6")
                }

                Section(t("settings.notifications")) {
                    Toggle(t("settings.enableReminder"), isOn: $notificationsEnabled)
                    Toggle(t("settings.debug"), isOn: $debugMode)
                    Button(t("settings.requestNotification")) {
                        Task { await NotificationManager.shared.requestPermission() }
                    }
                }

                Section {
                    Button(t("settings.jumpProfile")) { selectedTab = .profile }
                    Button(t("settings.jumpExercise")) { selectedTab = .exercises }
                }

                Section {
                    Button(t("settings.reset"), role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }
            .navigationTitle(t("tab.settings"))
            .alert(t("settings.resetConfirm"), isPresented: $showResetConfirmation) {
                Button(t("settings.cancel"), role: .cancel) {}
                Button(t("settings.confirm"), role: .destructive) {
                    resetAllLocalData()
                }
            }
        }
    }

    private func saveProfile() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            focusedField = nil
        }
        print("[Profile] save processing")
        profileValidationError = validateProfile(draftProfile)
        guard profileValidationError == nil else {
            profileMessage = nil
            profileBannerKind = .error
            print("[Profile] save failed validation")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                profileBannerKind = nil
            }
            return
        }
        _ = profileStore.saveProfile(draftProfile)
        profileMessage = t("profile.saveSuccess")
        profileBannerKind = .success
        print("[Profile] save success")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            profileMessage = nil
            profileValidationError = nil
            profileBannerKind = nil
        }
        recomputeDerivedState()
    }

    private var profileBannerText: String? {
        switch profileBannerKind {
        case .success:
            return profileMessage
        case .error:
            return profileValidationError
        case .none:
            return nil
        }
    }

    private func validateProfile(_ profile: UserProfile) -> String? {
        guard profile.heightCm > 0, profile.weightKg > 0 else { return t("profile.saveFailed") }
        return nil
    }

    private func requestAccess() async {
        await healthKitManager.requestAuthorization()
        await autoRefreshIfNeeded(force: true, reason: "afterAuthorization")
    }

    private func loadData() async {
        guard healthKitManager.canLoadData else { return }
        if isLoading { return }
        isLoading = true

        await weatherManager.refreshWeather()
        let newSnapshot = await healthKitManager.loadDailySnapshot()
        let baselineFallbacks = await healthKitManager.loadBaselineFallbacks()
        let recentWorkouts = await healthKitManager.loadRecentWorkouts(days: 14)
        let preBaseline = BaselineEngine.compute(records: historyStore.records, sessions: historyStore.sessions)

        if let previous = historyStore.latestRecord(before: newSnapshot.date), previous.completedRecommendation == true || previous.workoutType != nil {
            let response = PassiveRecoveryResponseEngine.evaluate(
                sourceRecord: previous,
                responseSnapshot: newSnapshot,
                baseline: preBaseline,
                recentSessions: historyStore.sessions
            )
            historyStore.storePassiveResponse(response)
        }

        snapshot = newSnapshot
        healthKitBaselineFallbacks = baselineFallbacks
        recomputeDerivedState()
        ensureDailyStepGoal()
        historyStore.upsert(snapshot: newSnapshot, recommendation: recommendation)
        historyStore.syncWorkoutsFromHealthKit(recentWorkouts)
        historyStore.syncPassiveCompletion(snapshot: newSnapshot)
        recomputeDerivedState()
        routineRecommendation = RoutineRecommendationEngine.generate(
            snapshot: snapshot,
            baseline: baseline,
            passiveScore: historyStore.passiveSummary.recentAverageScore,
            latestRecommendation: recommendation,
            weather: weatherManager.weather
        )

        NotificationManager.shared.scheduleMorningSummaryIfNeeded(
            recommendation: recommendation,
            routine: routineRecommendation,
            notificationsEnabled: notificationsEnabled
        )

        if historyStore.hasCompletedRecommendationToday {
            NotificationManager.shared.clearEveningReminder()
        }

        NotificationManager.shared.scheduleEveningReminderIfNeeded(
            recommendation: recommendation,
            routine: routineRecommendation,
            snapshot: snapshot,
            completedToday: historyStore.hasCompletedRecommendationToday,
            restSuppressed: recommendation.safetyMessage != nil,
            notificationsEnabled: notificationsEnabled
        )
        isLoading = false
    }

    private func autoRefreshIfNeeded(force: Bool = false, reason: String) async {
        guard healthKitManager.canLoadData else { return }
        let interval = Date().timeIntervalSince(lastAutoRefreshAt)
        guard force || interval > 45 else { return }
        print("[AutoRefresh] reason=\(reason)")
        await loadData()
        lastAutoRefreshAt = Date()
    }

    private func runMorningWorkflowIfNeeded() async {
        guard healthKitManager.canLoadData else { return }

        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        guard hour >= 5 && hour <= 11 else { return }

        let todayKey = Calendar.current.startOfDay(for: now).formatted(date: .numeric, time: .omitted)
        guard lastMorningAutoRefresh != todayKey else { return }

        await autoRefreshIfNeeded(force: true, reason: "morningWorkflow")
        lastMorningAutoRefresh = todayKey
        print("[Workflow] morning refresh completed")
    }

    private func recomputeDerivedState() {
        let localBaseline = BaselineEngine.compute(records: historyStore.records, sessions: historyStore.sessions)
        baseline = mergedBaseline(localBaseline, with: healthKitBaselineFallbacks)
        let passiveSummary = historyStore.passiveSummary
        let experience = profileStore.profile?.experience ?? .beginner

        recoveryMap = MuscleRecoveryEngine.buildRecoveryMap(
            sessions: historyStore.sessions,
            experience: experience,
            passiveResponseSummary: passiveSummary
        )

        if !profileStore.isProfileSufficientForRecommendations {
            recommendation = .fallback
            return
        }

        recommendation = RecommendationEngine.generate(
            snapshot: snapshot,
            baseline: baseline,
            profile: profileStore.profile,
            enabledExercises: exerciseStore.enabledExercises,
            recoveryMap: recoveryMap,
            history: historyStore.records,
            passiveSummary: passiveSummary
        )

        routineRecommendation = RoutineRecommendationEngine.generate(
            snapshot: snapshot,
            baseline: baseline,
            passiveScore: passiveSummary.recentAverageScore,
            latestRecommendation: recommendation,
            weather: weatherManager.weather
        )
    }

    private func mergedBaseline(_ localBaseline: PersonalBaseline, with fallbacks: HealthKitBaselineFallbacks) -> PersonalBaseline {
        PersonalBaseline(
            sleep: BaselineWindow(
                recent7: localBaseline.sleep.recent7,
                rolling28: localBaseline.sleep.rolling28 ?? fallbacks.sleep28,
                trend84: localBaseline.sleep.trend84
            ),
            restingHeartRate: BaselineWindow(
                recent7: localBaseline.restingHeartRate.recent7,
                rolling28: localBaseline.restingHeartRate.rolling28 ?? fallbacks.restingHeartRate28,
                trend84: localBaseline.restingHeartRate.trend84
            ),
            hrv: BaselineWindow(
                recent7: localBaseline.hrv.recent7,
                rolling28: localBaseline.hrv.rolling28 ?? fallbacks.hrv28,
                trend84: localBaseline.hrv.trend84
            ),
            steps: BaselineWindow(
                recent7: localBaseline.steps.recent7,
                rolling28: localBaseline.steps.rolling28 ?? fallbacks.steps28,
                trend84: localBaseline.steps.trend84
            ),
            workoutFrequencyPerWeek28: localBaseline.workoutFrequencyPerWeek28,
            workoutBalance28: localBaseline.workoutBalance28,
            muscleCoverageBalance28: localBaseline.muscleCoverageBalance28
        )
    }

    private func ensureDailyStepGoal() {
        if let existing = historyStore.todayRecord()?.dailyStepGoal, existing > 0 {
            return
        }
        let computedGoal = computeDailyStepGoal()
        historyStore.upsertDailyStepGoal(computedGoal)
    }

    private func completeSession() async {
        historyStore.endSession(recommendation: recommendation)
        recomputeDerivedState()
        ensureDailyStepGoal()
        NotificationManager.shared.clearEveningReminder()
        NotificationManager.shared.scheduleEveningReminderIfNeeded(
            recommendation: recommendation,
            routine: routineRecommendation,
            snapshot: snapshot,
            completedToday: historyStore.hasCompletedRecommendationToday,
            restSuppressed: recommendation.safetyMessage != nil,
            notificationsEnabled: notificationsEnabled
        )
        await autoRefreshIfNeeded(force: true, reason: "sessionEnd")
    }

    private func resetAllLocalData() {
        historyStore.clearAllData()
        profileStore.clearAllData()
        exerciseStore.clearAllData()
        snapshot = .empty
        baseline = .empty
        recoveryMap = [:]
        recommendation = .fallback
        routineRecommendation = .init(priority: .lightTonight, bedtimeHour: 23, bedtimeMinute: 0, explanationKeys: ["routine.reason.stable"], weatherKey: nil)
        profileMessage = nil
        profileValidationError = nil
    }

    private func localizedFallback(for metric: HealthMetric) -> String {
        localization.fallbackText(healthKitManager.metricFallbackText(for: metric))
    }

    private func localizedExerciseName(id: String, fallback: String) -> String {
        if let match = exerciseStore.allExercises.first(where: { $0.id == id }) {
            return localization.exerciseDisplayName(for: match)
        }
        return fallback
    }

    private var readinessScore: Int {
        dailyStatus(at: Date()).score
    }

    private func recoveryScore(_ group: MuscleGroup) -> Int {
        recoveryMap[group]?.score ?? 100
    }

    private var armRecoveryScore: Int {
        Int((Double(recoveryScore(.biceps) + recoveryScore(.forearms)) / 2.0).rounded())
    }

    private var systemicRecoveryText: String {
        let score = recoveryScore(.cardioSystemic)
        if score >= 76 { return t("recovery.fresh") }
        if score >= 46 { return t("recovery.recovering") }
        return t("recovery.fatigued")
    }

    private func recoveryColor(for score: Int) -> Color {
        switch score {
        case 76...100:
            return Color(red: 0.42, green: 0.70, blue: 0.60)
        case 46...75:
            return Color(red: 0.84, green: 0.66, blue: 0.32)
        default:
            return Color(red: 0.88, green: 0.36, blue: 0.28)
        }
    }

    private var todayStepGoal: Double {
        historyStore.todayRecord()?.dailyStepGoal ?? computeDailyStepGoal()
    }

    private var expectedStepsByNow: Double {
        let hour = Calendar.current.component(.hour, from: Date())
        let progress = expectedProgressByHour(hour)
        return todayStepGoal * progress
    }

    private var oneLineSummary: String {
        if let safety = recommendation.safetyMessage {
            return localization.fallbackText(safety)
        }
        if let summary = historyStore.passiveSummary.lastResponse?.summary {
            return localization.passiveSummary(summary)
        }
        return localization.recommendationExplanation(recommendation)
    }

    private func dailyStatus(at now: Date) -> DailyStatusState {
        let baseScore =
            Double(recommendation.scores.recoveryScore) * 0.5 +
            Double(recommendation.scores.muscleReadinessScore) * 0.22 +
            Double(recommendation.scores.passiveRecoveryResponseScore) * 0.18 +
            Double(recoveryScore(.cardioSystemic)) * 0.10

        let wakeReference = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: now) ?? now
        let awakeHours = max(0, now.timeIntervalSince(wakeReference) / 3600.0)
        let daytimePenalty = clamp((awakeHours - 1.5) * 1.8, min: 0, max: 22)

        let stepsRatio = (snapshot.stepCountToday ?? 0) / max(todayStepGoal, 1)
        let activityPenalty = clamp(stepsRatio * 6.0, min: 0, max: 8)

        let systemicPenalty = clamp(Double(100 - recoveryScore(.cardioSystemic)) * 0.16, min: 0, max: 14)

        let sessionPenalty: Double
        if let session = historyStore.latestSession(), Calendar.current.isDate(session.date, inSameDayAs: now) {
            let duration = historyStore.todayRecord()?.workoutDurationMinutes ?? Double(recommendation.durationMinutes)
            let intensityFactor: Double
            switch session.sessionIntensity {
            case .low:
                intensityFactor = 0.75
            case .moderate:
                intensityFactor = 1.0
            case .high:
                intensityFactor = 1.25
            }

            let recentBoost: Double
            let hoursSinceSession = max(0, now.timeIntervalSince(session.date) / 3600.0)
            if hoursSinceSession < 2 {
                recentBoost = 4
            } else if hoursSinceSession < 5 {
                recentBoost = 2
            } else {
                recentBoost = 0
            }

            sessionPenalty = clamp((duration / 4.5) * intensityFactor + recentBoost, min: 0, max: 20)
        } else if historyStore.activeSessionStart != nil {
            sessionPenalty = 10
        } else {
            sessionPenalty = 0
        }

        let morningBoost: Double
        if Calendar.current.component(.hour, from: now) <= 10,
           let sleep = snapshot.lastNightSleepHours,
           let baselineSleep = baseline.sleep.rolling28,
           baselineSleep > 0,
           sleep >= baselineSleep * 1.03 {
            morningBoost = 4
        } else {
            morningBoost = 0
        }

        let score = Int(clamp(baseScore - daytimePenalty - activityPenalty - systemicPenalty - sessionPenalty + morningBoost, min: 18, max: 98).rounded())

        let label: String
        switch score {
        case 78...100:
            label = t("todayStatus.high")
        case 58...77:
            label = t("todayStatus.stable")
        case 40...57:
            label = t("todayStatus.dipping")
        default:
            label = t("todayStatus.low")
        }

        let reason: String
        if sessionPenalty >= 8 {
            reason = t("todayStatus.reason.training")
        } else if systemicPenalty >= 7 {
            reason = t("todayStatus.reason.systemic")
        } else if daytimePenalty >= 8 {
            reason = t("todayStatus.reason.daylight")
        } else if morningBoost > 0 {
            reason = t("todayStatus.reason.morning")
        } else if score >= 60 {
            reason = t("todayStatus.reason.ready")
        } else {
            reason = t("todayStatus.reason.keepEasy")
        }

        return DailyStatusState(score: score, label: label, reason: reason)
    }

    private var recentSleepValues: [Double] {
        let recent = snapshot.recentSleepHistory.suffix(7).map(\.hours)
        return recent.isEmpty ? historyStore.records.suffix(7).compactMap(\.sleepHours) : recent
    }

    private var restingTrendValues: [Double] {
        let values = snapshot.recentRestingHeartRateHistory.suffix(7).map(\.value)
        if values.isEmpty, let current = snapshot.restingHeartRate {
            return [current]
        }
        return values
    }

    private var restingTrendAverage: Double? {
        average(restingTrendValues)
    }

    private var hrvTrendValues: [Double] {
        let values = snapshot.recentHRVHistory.suffix(7).map(\.value)
        if values.isEmpty, let current = snapshot.hrv {
            return [current]
        }
        return values
    }

    private var hrvTrendAverage: Double? {
        average(hrvTrendValues)
    }

    private var hrvStatusTitle: String {
        guard let current = snapshot.hrv, let baselineValue = baseline.hrv.rolling28, baselineValue > 0 else {
            return t("hrv.status.missing")
        }

        let delta = (current - baselineValue) / baselineValue
        if delta >= 0.08 {
            return t("hrv.status.high")
        }
        if delta <= -0.08 {
            return t("hrv.status.low")
        }
        return t("hrv.status.stable")
    }

    private var hrvStatusMeaning: String {
        guard let current = snapshot.hrv, let baselineValue = baseline.hrv.rolling28, baselineValue > 0 else {
            return t("hrv.meaning.missing")
        }

        let delta = (current - baselineValue) / baselineValue
        if delta >= 0.08 {
            return t("hrv.meaning.high")
        }
        if delta <= -0.08 {
            return t("hrv.meaning.low")
        }
        return t("hrv.meaning.stable")
    }

    private var hrvStatusColor: Color {
        guard let current = snapshot.hrv, let baselineValue = baseline.hrv.rolling28, baselineValue > 0 else {
            return .gray
        }

        let delta = (current - baselineValue) / baselineValue
        if delta >= 0.08 {
            return .green
        }
        if delta <= -0.08 {
            return .orange
        }
        return AppTheme.accentPrimary
    }

    private var hrvAnalysisText: String {
        switch hrvStatusTitle {
        case t("hrv.status.high"):
            return t("hrv.analysis.high")
        case t("hrv.status.low"):
            return t("hrv.analysis.low")
        case t("hrv.status.stable"):
            return t("hrv.analysis.stable")
        default:
            return t("hrv.analysis.missing")
        }
    }

    private var rhrStatusTitle: String {
        guard let current = snapshot.restingHeartRate, let baselineValue = baseline.restingHeartRate.rolling28, baselineValue > 0 else {
            return t("rhr.status.missing")
        }

        let delta = (current - baselineValue) / baselineValue
        if delta <= -0.05 {
            return t("rhr.status.low")
        }
        if delta >= 0.06 {
            return t("rhr.status.high")
        }
        return t("rhr.status.stable")
    }

    private var rhrStatusMeaning: String {
        guard let current = snapshot.restingHeartRate, let baselineValue = baseline.restingHeartRate.rolling28, baselineValue > 0 else {
            return t("rhr.meaning.missing")
        }

        let delta = (current - baselineValue) / baselineValue
        if delta <= -0.05 {
            return t("rhr.meaning.low")
        }
        if delta >= 0.06 {
            return t("rhr.meaning.high")
        }
        return t("rhr.meaning.stable")
    }

    private var rhrStatusColor: Color {
        guard let current = snapshot.restingHeartRate, let baselineValue = baseline.restingHeartRate.rolling28, baselineValue > 0 else {
            return .gray
        }

        let delta = (current - baselineValue) / baselineValue
        if delta <= -0.05 {
            return .green
        }
        if delta >= 0.06 {
            return .orange
        }
        return AppTheme.accentWarm
    }

    private var rhrAnalysisText: String {
        switch rhrStatusTitle {
        case t("rhr.status.low"):
            return t("rhr.analysis.low")
        case t("rhr.status.high"):
            return t("rhr.analysis.high")
        case t("rhr.status.stable"):
            return t("rhr.analysis.stable")
        default:
            return t("rhr.analysis.missing")
        }
    }

    private var stepExpectedNow: Double {
        expectedStepsByNow
    }

    private var stepProgress: Double {
        guard todayStepGoal > 0 else { return 0 }
        let current = snapshot.stepCountToday ?? 0
        return min(1.0, max(0, current / todayStepGoal))
    }

    private var stepsExpectationText: String {
        "\(t("label.expectedNow")) \(Int(stepExpectedNow.rounded()))"
    }

    private var stepStatusText: String {
        let delta = Int((snapshot.stepCountToday ?? 0) - expectedStepsByNow)
        if delta >= 0 {
            return "\(t("label.ahead")) +\(delta)"
        }
        return "\(t("label.behind")) \(delta)"
    }

    private var todayHeadline: String {
        if historyStore.activeSessionStart != nil {
            return t("today.inProgress")
        }
        if historyStore.hasCompletedRecommendationToday {
            return t("today.doneTitle")
        }
        return localizedRecommendationHeadline
    }

    private var todaySubheadline: String {
        if historyStore.hasCompletedRecommendationToday, let session = historyStore.latestSession() {
            return completedSessionSummary(session)
        }
        return localization.recommendationDetail(recommendation)
    }

    private var todaySummaryText: String {
        if historyStore.hasCompletedRecommendationToday {
            return t("today.completedSummary")
        }
        if historyStore.activeSessionStart != nil {
            return t("today.inProgressSummary")
        }
        return localization.recommendationExplanation(recommendation)
    }

    private var tomorrowDirectionText: String {
        if recommendation.scores.recoveryScore < 45 {
            return t("today.tomorrowRecovery")
        }
        if recommendation.type == .strength {
            return t("today.tomorrowLighter")
        }
        return t("today.tomorrowBalanced")
    }

    private var localizedRecommendationHeadline: String {
        if recommendation.type == .strength, let focus = recommendation.targetFocus.first {
            switch focus {
            case .back, .biceps, .forearms:
                return t("rec.headline.back")
            case .chest:
                return t("rec.headline.chest")
            case .quads, .hamstrings, .glutes, .adductors, .calves:
                return t("rec.headline.lower")
            case .cardioSystemic:
                return localization.recommendationTitle(recommendation)
            }
        }
        switch recommendation.type {
        case .walk:
            return t("rec.headline.walk")
        case .easyRun:
            return t("rec.headline.run")
        case .mobility:
            return t("rec.headline.mobility")
        case .rest:
            return t("rec.headline.recovery")
        case .strength:
            return localization.recommendationTitle(recommendation)
        }
    }

    private func completedSessionSummary(_ session: CompletedWorkoutSession) -> String {
        let minutes = resolvedCompletedMinutes(for: session)
        return "\(t("today.completed")) • \(minutes) \(t("common.min"))"
    }

    private func resolvedCompletedMinutes(for session: CompletedWorkoutSession) -> Int {
        if let workoutDate = historyStore.todayRecord()?.workoutDate,
           Calendar.current.isDate(workoutDate, inSameDayAs: session.date),
           let duration = historyStore.todayRecord()?.workoutDurationMinutes,
           duration > 0 {
            return Int(duration.rounded())
        }

        if session.exercises.count == 1 {
            let fallbackMinutes = session.exercises[0].plannedReps
            if fallbackMinutes > 0 {
                return fallbackMinutes
            }
        }

        return max(1, recommendation.durationMinutes)
    }

    private func elapsedMinutesText(since start: Date, now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(start) / 60))
        return "\(minutes) \(t("common.min"))"
    }

    private func computeDailyStepGoal() -> Double {
        let baselineSteps = baseline.steps.rolling28 ?? 7000
        let goalMultiplier: Double
        switch profileStore.profile?.goal ?? .generalHealth {
        case .generalHealth:
            goalMultiplier = 1.0
        case .fatLoss:
            goalMultiplier = 1.12
        case .muscleGain:
            goalMultiplier = 0.96
        }

        var readinessAdjustment = 1.0
        if recommendation.scores.recoveryScore < 40 {
            readinessAdjustment = 0.82
        } else if recommendation.scores.recoveryScore > 68 {
            readinessAdjustment = 1.08
        }

        if historyStore.hasCompletedRecommendationToday {
            readinessAdjustment *= 0.95
        }

        let computed = baselineSteps * goalMultiplier * readinessAdjustment
        return min(16000, max(4500, computed.rounded()))
    }

    private func expectedProgressByHour(_ hour: Int) -> Double {
        switch hour {
        case ..<7:
            return 0.06
        case 7..<10:
            return 0.18
        case 10..<13:
            return 0.34
        case 13..<16:
            return 0.54
        case 16..<19:
            return 0.74
        case 19..<22:
            return 0.9
        default:
            return 1.0
        }
    }

    private func localizedRoutinePriority(_ priority: RoutinePriority) -> String {
        switch priority {
        case .restTonight:
            return t("routine.rest")
        case .lightTonight:
            return t("routine.light")
        case .normalTonight:
            return t("routine.normal")
        }
    }

    private func localizedRoutineExplanation(_ key: String) -> String {
        t(key)
    }

    private func localizedRoutineExplanation(_ keys: [String]) -> String {
        keys.map { t($0) }.joined(separator: " · ")
    }

    private func chipColor(for state: MuscleRecoveryState) -> Color {
        switch state {
        case .fresh:
            return .green
        case .recovering:
            return .yellow
        case .fatigued:
            return .orange
        }
    }

    private func deltaPill(current: Double?, baselineValue: Double?, lowerIsBetter: Bool) -> some View {
        Group {
            if let current, let baselineValue, baselineValue > 0 {
                let delta = (current - baselineValue) / baselineValue
                let percent = Int((delta * 100).rounded())
                let good = lowerIsBetter ? delta <= 0 : delta >= 0
                let color: Color = good ? .green : .orange
                Text(String(format: "%+d%%", percent))
                    .font(AppTheme.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(color.opacity(0.14)))
            } else {
                Text(t("common.nA"))
                    .font(AppTheme.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
    }

    private func statusPill(title: String, color: Color) -> some View {
        Text(title)
            .font(AppTheme.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func t(_ key: String) -> String { localization.text(key) }

    private func valueRow(title: String, value: Binding<Double>, field: ProfileField) -> some View {
        HStack {
            Text(title)
                .font(AppTheme.body)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
        }
    }

    private func optionalValueRow(title: String, value: Binding<Double?>, field: ProfileField) -> some View {
        HStack {
            Text(title)
                .font(AppTheme.body)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
        }
    }

    private func intRow(title: String, value: Binding<Int?>, field: ProfileField) -> some View {
        HStack {
            Text(title)
                .font(AppTheme.body)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
        }
    }

    private func metricRow(name: String, current: String, baselineValue: String, deviationValue: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(AppTheme.bodyStrong)
            Text("\(t("label.current")): \(current)")
                .font(AppTheme.body)
            Text("\(t("label.baseline")): \(baselineValue)")
                .font(AppTheme.caption)
                .foregroundStyle(.secondary)
            Text("\(t("label.deviation")): \(deviationValue)")
                .font(AppTheme.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func feedbackButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        if selected {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func planLine(for exercise: PlannedExercise) -> String {
        let intensity = localization.intensity(exercise.intensity)
        if let duration = exercise.durationMinutes {
            return "\(duration) \(t("common.min")) • \(intensity)"
        }
        let sets = exercise.sets ?? 0
        let reps = exercise.reps ?? "-"
        let rest = exercise.restSeconds ?? 0
        let load = exercise.loadGuidance ?? t("common.rpe")
        return "\(sets) x \(reps) • \(t("common.rest")) \(rest)s • \(load)"
    }

    private func deviationText(current: Double?, baselineValue: Double?) -> String {
        guard let current, let baselineValue, baselineValue != 0 else { return t("common.nA") }
        let percent = ((current - baselineValue) / baselineValue) * 100.0
        return String(format: "%+.1f%%", percent)
    }

    private var workoutBalanceText: String {
        "\(t("label.cardio")) \(baseline.workoutBalance28.cardioSessions) / \(t("label.strength")) \(baseline.workoutBalance28.strengthSessions) / \(t("label.mobility")) \(baseline.workoutBalance28.mobilitySessions)"
    }

    private func windowText(_ window: BaselineWindow) -> String {
        let s7 = window.recent7.map { String(format: "%.1f", $0) } ?? "-"
        let s28 = window.rolling28.map { String(format: "%.1f", $0) } ?? "-"
        let s84 = window.trend84.map { String(format: "%.1f", $0) } ?? "-"
        return "\(s7) / \(s28) / \(s84)"
    }

    private var lastLoadText: String {
        guard let date = healthKitManager.lastLoadTimestamp else { return t("common.notLoaded") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}

private struct Card<Content: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(AppTheme.cardTitle)
                .foregroundStyle(tint)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .fill(AppTheme.panelBackground.opacity(0.86))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                        .stroke(AppTheme.panelStroke, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }
}

private struct CircularGauge: View {
    let value: Int
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, value))) / 100.0)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
        }
    }
}

private struct MiniBarChart: View {
    let values: [Double]
    let baseline: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(values.max() ?? 1, baseline ?? 1, 1)
            let barWidth = max(8, (proxy.size.width - CGFloat(max(values.count - 1, 0)) * 6) / CGFloat(max(values.count, 1)))

            ZStack(alignment: .topLeading) {
                if let baseline {
                    let y = proxy.size.height * (1 - CGFloat(baseline / maxValue))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.white.opacity(0.28))
                }

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == values.count - 1 ? tint : tint.opacity(0.45))
                            .frame(
                                width: barWidth,
                                height: max(6, proxy.size.height * CGFloat(value / maxValue))
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let range = max(maxV - minV, 0.01)

            Path { path in
                for (index, value) in values.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                    let y = proxy.size.height * (1 - CGFloat((value - minV) / range))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct TrendSparkline: View {
    let values: [Double]
    let reference: Double?
    let baseline: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let minValue = min(values.min() ?? 0, reference ?? .greatestFiniteMagnitude, baseline ?? .greatestFiniteMagnitude)
            let maxValue = max(values.max() ?? 1, reference ?? 0, baseline ?? 0, 1)
            let safeMin = minValue.isFinite ? minValue : 0
            let range = max(maxValue - safeMin, 0.01)

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.04))

                if let baseline {
                    line(at: baseline, minValue: safeMin, range: range, in: proxy.size)
                        .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }

                if let reference {
                    line(at: reference, minValue: safeMin, range: range, in: proxy.size)
                        .stroke(tint.opacity(0.24), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }

                trendPath(minValue: safeMin, range: range, in: proxy.size)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))

                trendFill(minValue: safeMin, range: range, in: proxy.size)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.18), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
    }

    private func line(at value: Double, minValue: Double, range: Double, in size: CGSize) -> Path {
        let y = size.height * (1 - CGFloat((value - minValue) / range))
        return Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
    }

    private func trendPath(minValue: Double, range: Double, in size: CGSize) -> Path {
        Path { path in
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                let y = size.height * (1 - CGFloat((value - minValue) / range))
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }

    private func trendFill(minValue: Double, range: Double, in size: CGSize) -> Path {
        Path { path in
            guard !values.isEmpty else { return }
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                let y = size.height * (1 - CGFloat((value - minValue) / range))
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
    }
}

private struct MetricMetaPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MuscleChip: View {
    let name: String
    let stateText: String
    let score: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(stateText) \(score)")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

private struct RecoveryHeatChip: View {
    let title: String
    let score: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(score)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(14, proxy.size.width * CGFloat(score) / 100.0))
                }
            }
            .frame(height: 8)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(color.opacity(0.20), lineWidth: 1)
                )
        )
    }

    private var color: Color {
        switch score {
        case 76...100:
            return Color(red: 0.42, green: 0.70, blue: 0.60)
        case 46...75:
            return Color(red: 0.84, green: 0.66, blue: 0.32)
        default:
            return Color(red: 0.88, green: 0.36, blue: 0.28)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(LocalizationManager())
}
