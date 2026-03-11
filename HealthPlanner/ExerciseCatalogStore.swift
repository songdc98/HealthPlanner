import Foundation
import Combine

enum ExerciseCategory: String, Codable, CaseIterable {
    case walking = "Walking"
    case running = "Running"
    case strength = "Strength"
    case mobility = "Mobility"
}

enum EquipmentType: String, Codable, CaseIterable {
    case none = "None"
    case gymMachine = "Gym Machine"
    case barbell = "Barbell"
    case pullUpBar = "Pull-up Bar"
    case bodyweight = "Bodyweight"
    case other = "Other"
}

enum MovementPattern: String, Codable {
    case gait = "Gait"
    case push = "Push"
    case pull = "Pull"
    case squat = "Squat"
    case hinge = "Hinge"
    case isolation = "Isolation"
    case mobility = "Mobility"
}

enum SessionPrescriptionMode: String, Codable {
    case durationBased = "Duration"
    case setsRepsLoad = "Sets/Reps/Load"
}

enum DefaultIntensityBehavior: String, Codable {
    case progressive = "Progressive"
    case steadyEasy = "Steady Easy"
    case conservative = "Conservative"
}

enum MuscleGroup: String, Codable, CaseIterable, Hashable {
    case chest
    case back
    case biceps
    case forearms
    case quads
    case hamstrings
    case glutes
    case adductors
    case calves
    case cardioSystemic = "Cardio/Systemic"
}

struct ExerciseItem: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var category: ExerciseCategory
    var equipmentType: EquipmentType
    var primaryMuscleGroups: [MuscleGroup]
    var secondaryMuscleGroups: [MuscleGroup]
    var movementPattern: MovementPattern
    var sessionPrescriptionMode: SessionPrescriptionMode
    var defaultIntensityBehavior: DefaultIntensityBehavior
    var suitabilityGoals: [TrainingGoal]
    var suitableForGeneralHealthByDefault: Bool
    var isCustom: Bool
}

private struct ExerciseCatalogData: Codable {
    var enabledExerciseIDs: Set<String>
    var customExercises: [ExerciseItem]
}

@MainActor
final class ExerciseCatalogStore: ObservableObject {
    @Published private(set) var enabledExerciseIDs: Set<String> = []
    @Published private(set) var customExercises: [ExerciseItem] = []

    private let fileURL: URL
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

        fileURL = appDir.appendingPathComponent("exercise_catalog.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()

        load()
        if enabledExerciseIDs.isEmpty {
            enabledExerciseIDs = Set(Self.seedExercises.filter { $0.suitableForGeneralHealthByDefault }.map { $0.id })
            persist()
        }
    }

    var allExercises: [ExerciseItem] {
        (Self.seedExercises + customExercises).sorted { $0.displayName < $1.displayName }
    }

    var enabledExercises: [ExerciseItem] {
        allExercises.filter { enabledExerciseIDs.contains($0.id) }
    }

    func isEnabled(_ exercise: ExerciseItem) -> Bool {
        enabledExerciseIDs.contains(exercise.id)
    }

    func toggleExercise(_ exercise: ExerciseItem) {
        if enabledExerciseIDs.contains(exercise.id) {
            enabledExerciseIDs.remove(exercise.id)
        } else {
            enabledExerciseIDs.insert(exercise.id)
        }
        persist()
    }

    func addCustomExercise(name: String, category: ExerciseCategory, equipment: EquipmentType, primary: [MuscleGroup], secondary: [MuscleGroup], movement: MovementPattern, mode: SessionPrescriptionMode) {
        let item = ExerciseItem(
            id: "custom-\(UUID().uuidString)",
            displayName: name,
            category: category,
            equipmentType: equipment,
            primaryMuscleGroups: primary,
            secondaryMuscleGroups: secondary,
            movementPattern: movement,
            sessionPrescriptionMode: mode,
            defaultIntensityBehavior: .conservative,
            suitabilityGoals: [.generalHealth, .fatLoss, .muscleGain],
            suitableForGeneralHealthByDefault: true,
            isCustom: true
        )
        customExercises.append(item)
        enabledExerciseIDs.insert(item.id)
        persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try decoder.decode(ExerciseCatalogData.self, from: data)
            enabledExerciseIDs = decoded.enabledExerciseIDs
            customExercises = decoded.customExercises
        } catch {
            print("[ExerciseCatalogStore] load failed: \(error.localizedDescription)")
        }
    }

    func clearAllData() {
        enabledExerciseIDs = Set(Self.seedExercises.filter { $0.suitableForGeneralHealthByDefault }.map { $0.id })
        customExercises = []
        persist()
    }

    private func persist() {
        do {
            let data = try encoder.encode(ExerciseCatalogData(enabledExerciseIDs: enabledExerciseIDs, customExercises: customExercises))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[ExerciseCatalogStore] persist failed: \(error.localizedDescription)")
        }
    }

    static func seedExerciseByID(_ id: String) -> ExerciseItem? {
        seedExercises.first { $0.id == id }
    }

    private static let allGoals: [TrainingGoal] = [.generalHealth, .fatLoss, .muscleGain]

    private static let seedExercises: [ExerciseItem] = [
        ExerciseItem(id: "walk", displayName: "Walk", category: .walking, equipmentType: .none, primaryMuscleGroups: [.cardioSystemic, .calves], secondaryMuscleGroups: [.glutes], movementPattern: .gait, sessionPrescriptionMode: .durationBased, defaultIntensityBehavior: .steadyEasy, suitabilityGoals: allGoals, suitableForGeneralHealthByDefault: true, isCustom: false),
        ExerciseItem(id: "run", displayName: "Run", category: .running, equipmentType: .none, primaryMuscleGroups: [.cardioSystemic, .quads, .calves], secondaryMuscleGroups: [.hamstrings, .glutes], movementPattern: .gait, sessionPrescriptionMode: .durationBased, defaultIntensityBehavior: .progressive, suitabilityGoals: [.generalHealth, .fatLoss], suitableForGeneralHealthByDefault: true, isCustom: false),
        ExerciseItem(id: "chest-press-machine", displayName: "Chest Press Machine", category: .strength, equipmentType: .gymMachine, primaryMuscleGroups: [.chest], secondaryMuscleGroups: [], movementPattern: .push, sessionPrescriptionMode: .setsRepsLoad, defaultIntensityBehavior: .progressive, suitabilityGoals: allGoals, suitableForGeneralHealthByDefault: true, isCustom: false),
        ExerciseItem(id: "lat-pulldown", displayName: "Lat Pulldown", category: .strength, equipmentType: .gymMachine, primaryMuscleGroups: [.back], secondaryMuscleGroups: [.biceps], movementPattern: .pull, sessionPrescriptionMode: .setsRepsLoad, defaultIntensityBehavior: .progressive, suitabilityGoals: allGoals, suitableForGeneralHealthByDefault: true, isCustom: false),
        ExerciseItem(id: "seated-row", displayName: "Seated Row / Row Machine", category: .strength, equipmentType: .gymMachine, primaryMuscleGroups: [.back], secondaryMuscleGroups: [.biceps, .forearms], movementPattern: .pull, sessionPrescriptionMode: .setsRepsLoad, defaultIntensityBehavior: .progressive, suitabilityGoals: allGoals, suitableForGeneralHealthByDefault: true, isCustom: false),
        ExerciseItem(id: "biceps-curl-machine", displayName: "Biceps Curl Machine", category: .strength, equipmentType: .gymMachine, primaryMuscleGroups: [.biceps], secondaryMuscleGroups: [.forearms], movementPattern: .isolation, sessionPrescriptionMode: .setsRepsLoad, defaultIntensityBehavior: .progressive, suitabilityGoals: allGoals, suitableForGeneralHealthByDefault: true, isCustom: false),
        ExerciseItem(id: "wrist-curl-machine", displayName: "Forearm / Wrist Curl Machine", category: .strength, equipmentType: .gymMachine, primaryMuscleGroups: [.forearms], secondaryMuscleGroups: [], movementPattern: .isolation, sessionPrescriptionMode: .setsRepsLoad, defaultIntensityBehavior: .conservative, suitabilityGoals: [.generalHealth, .muscleGain], suitableForGeneralHealthByDefault: false, isCustom: false),
        ExerciseItem(id: "leg-adduction-machine", displayName: "Leg Adduction Machine", category: .strength, equipmentType: .gymMachine, primaryMuscleGroups: [.adductors], secondaryMuscleGroups: [.glutes], movementPattern: .isolation, sessionPrescriptionMode: .setsRepsLoad, defaultIntensityBehavior: .conservative, suitabilityGoals: allGoals, suitableForGeneralHealthByDefault: true, isCustom: false),
        ExerciseItem(id: "leg-curl-machine", displayName: "Leg Curl Machine", category: .strength, equipmentType: .gymMachine, primaryMuscleGroups: [.hamstrings], secondaryMuscleGroups: [.glutes], movementPattern: .hinge, sessionPrescriptionMode: .setsRepsLoad, defaultIntensityBehavior: .progressive, suitabilityGoals: allGoals, suitableForGeneralHealthByDefault: true, isCustom: false),
        ExerciseItem(id: "squat", displayName: "Squat", category: .strength, equipmentType: .barbell, primaryMuscleGroups: [.quads, .glutes], secondaryMuscleGroups: [.hamstrings, .adductors], movementPattern: .squat, sessionPrescriptionMode: .setsRepsLoad, defaultIntensityBehavior: .progressive, suitabilityGoals: [.generalHealth, .muscleGain], suitableForGeneralHealthByDefault: true, isCustom: false),
        ExerciseItem(id: "pull-up", displayName: "Pull-Up", category: .strength, equipmentType: .pullUpBar, primaryMuscleGroups: [.back, .biceps], secondaryMuscleGroups: [.forearms], movementPattern: .pull, sessionPrescriptionMode: .setsRepsLoad, defaultIntensityBehavior: .progressive, suitabilityGoals: [.generalHealth, .muscleGain], suitableForGeneralHealthByDefault: true, isCustom: false)
    ]
}
