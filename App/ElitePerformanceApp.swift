import SwiftUI
import SwiftData

@main
struct ElitePerformanceApp: App {

    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            User.self,
            Session.self,
            SessionItem.self,
            SetLog.self,
            PRIndex.self,
            SessionHistory.self,
            SessionHistoryExercise.self
        ])

        let config = ModelConfiguration(isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(sharedModelContainer)   // 👈 single source of truth
        }
    }
}
