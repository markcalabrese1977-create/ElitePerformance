import SwiftUI
import SwiftData

@main
struct ElitePerformanceApp: App {

    private let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema([
            User.self,
            Session.self,
            SessionItem.self,
            SetLog.self,
            PRIndex.self,
            SessionHistory.self,
            SessionHistoryExercise.self
        ])

        // Attempt #1: try opening the existing store (whatever name/url it previously used)
        do {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            self.sharedModelContainer = try ModelContainer(for: schema, configurations: [config])
            return
        } catch {
            print("⚠️ SwiftData store failed to load (likely schema mismatch): \(error)")
        }

        // Attempt #2: fall back to a NEW store file (no uninstall required)
        do {
            let freshConfig = ModelConfiguration(
                "ElitePerformanceStore_v2",
                schema: schema,
                isStoredInMemoryOnly: false
            )
            self.sharedModelContainer = try ModelContainer(for: schema, configurations: [freshConfig])
            print("✅ Created fresh SwiftData store: ElitePerformanceStore_v2")
        } catch {
            fatalError("Could not create ModelContainer (fresh store also failed): \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(sharedModelContainer)
        }
    }
}
