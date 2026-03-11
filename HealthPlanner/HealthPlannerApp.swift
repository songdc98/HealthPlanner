import SwiftUI

@main
struct HealthPlannerApp: App {
    @StateObject private var localization = LocalizationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(localization)
        }
    }
}
