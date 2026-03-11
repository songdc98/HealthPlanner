import Foundation
import Combine

enum TrainingGoal: String, CaseIterable, Codable {
    case generalHealth = "General Health"
    case fatLoss = "Fat Loss"
    case muscleGain = "Muscle Gain"
}

enum TrainingExperience: String, CaseIterable, Codable {
    case beginner = "Beginner"
    case intermediate = "Intermediate"
    case advanced = "Advanced"
}

enum BiologicalSex: String, CaseIterable, Codable {
    case female = "Female"
    case male = "Male"
    case nonBinary = "Non-binary"
    case preferNotToSay = "Prefer not to say"
}

struct UserProfile: Codable {
    var heightCm: Double
    var weightKg: Double
    var age: Int?
    var biologicalSex: BiologicalSex
    var goal: TrainingGoal
    var experience: TrainingExperience
    var estimated5kMinutes: Double?
    var maxPushUps: Int?
    var maxPullUps: Int?
    var estimatedBenchPressKg: Double?
    var estimatedLatPulldownKg: Double?
    var estimatedSquatKg: Double?
    var hasGymAccess: Bool
    var equipmentNotes: String
}

private struct PersistedProfilePayload: Codable {
    var profile: UserProfile
    var lastSavedAt: Date
}

@MainActor
final class UserProfileStore: ObservableObject {
    @Published private(set) var profile: UserProfile?
    @Published private(set) var lastSavedAt: Date?

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

        fileURL = appDir.appendingPathComponent("user_profile.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    var hasCompletedOnboarding: Bool {
        profile != nil
    }

    var isProfileSufficientForRecommendations: Bool {
        guard let profile else { return false }
        return profile.heightCm > 0 && profile.weightKg > 0
    }

    @discardableResult
    func saveProfile(_ profile: UserProfile) -> Date {
        let now = Date()
        self.profile = profile
        self.lastSavedAt = now
        persist()
        return now
    }

    func clearAllData() {
        profile = nil
        lastSavedAt = nil
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            print("[UserProfileStore] clear failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profile = nil
            lastSavedAt = nil
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            if let payload = try? decoder.decode(PersistedProfilePayload.self, from: data) {
                profile = payload.profile
                lastSavedAt = payload.lastSavedAt
            } else {
                // Backward compatibility for old profile-only payload.
                profile = try decoder.decode(UserProfile.self, from: data)
                lastSavedAt = nil
            }
        } catch {
            print("[UserProfileStore] load failed: \(error.localizedDescription)")
            profile = nil
            lastSavedAt = nil
        }
    }

    private func persist() {
        guard let profile, let lastSavedAt else {
            return
        }

        do {
            let payload = PersistedProfilePayload(profile: profile, lastSavedAt: lastSavedAt)
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[UserProfileStore] persist failed: \(error.localizedDescription)")
        }
    }
}
