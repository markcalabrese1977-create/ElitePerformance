import SwiftUI
import SwiftData

@main
struct ElitePerformanceApp: App {

    private let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema([
            User.self,
            ProgramState.self,
            Session.self,
            SessionItem.self,
            SetLog.self,
            PRIndex.self,
            SessionHistory.self,
            SessionHistoryExercise.self,
            ExerciseNote.self,
            AppState.self,
            MesoBlock.self,
            UserProfile.self,
            CustomExercise.self
        ])

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let pinKey = "activeSwiftDataStoreLabel.v1"

        let candidates: [(label: String?, filename: String)] = [
            (nil, "default.store"),
            ("ElitePerformanceStore", "ElitePerformanceStore.store"),
            ("ElitePerformanceStore_v2", "ElitePerformanceStore_v2.store")
        ]

        func runStartupBackfills(using container: ModelContainer) {
            let context = ModelContext(container)
            ExerciseNameSnapshotBackfill.runIfNeeded(in: context)
            ExerciseNameSnapshotRepair.runIfNeeded(in: context)
            CanonicalExerciseIdMigration.runIfNeeded(in: context)
            CustomExerciseDedupMigration.runIfNeeded(in: context)
            D5ExerciseIdRepairMigration.runIfNeeded(in: context)
            Apr21SessionHistoryRepairMigration.runIfNeeded(in: context) 
            SessionHistoryBlockBackfill.runIfNeeded(in: context)
            SessionDayLabelBackfill.runIfNeeded(in: context)
            CustomExerciseStoreMigration.runIfNeeded(in: context)
            CustomExerciseUserDefaultsSyncRepair.runIfNeeded(in: context)
        }

        func openStore(label: String?) throws -> (container: ModelContainer, sessions: [Session]) {
            let config: ModelConfiguration

            if let name = label, name != "DEFAULT" {
                config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: false)
            } else {
                config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            }

            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)

            let sessions = try context.fetch(
                FetchDescriptor<Session>(sortBy: [SortDescriptor(\.date, order: .reverse)])
            )

            return (container, sessions)
        }

        func computeLoggedSetCount(from sessions: [Session]) -> Int {
            var count = 0
            for s in sessions {
                for item in s.items {
                    let hasLoad = item.actualLoads.contains(where: { $0 > 0 })
                    let hasReps = item.actualReps.contains(where: { $0 > 0 })
                    if hasLoad || hasReps {
                        count += 1
                    }
                }
            }
            return count
        }

        #if targetEnvironment(simulator)
        do {
            print("ℹ️ Simulator detected — using DEFAULT SwiftData store (no pin/scan).")
            let (container, _) = try openStore(label: nil)
            self.sharedModelContainer = container
            runStartupBackfills(using: container)
            return
        } catch {
            print("⚠️ Simulator store failed to open. Deleting default.store and recreating. Error: \(error)")

            let storeURL = appSupport.appendingPathComponent("default.store")
            let walURL = appSupport.appendingPathComponent("default.store-wal")
            let shmURL = appSupport.appendingPathComponent("default.store-shm")

            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)

            do {
                let (container, _) = try openStore(label: nil)
                self.sharedModelContainer = container
                runStartupBackfills(using: container)
                return
            } catch {
                fatalError("Simulator failed to recreate DEFAULT SwiftData store: \(error)")
            }
        }
        #endif

        if let pinned = UserDefaults.standard.string(forKey: pinKey) {
            let pinnedLabel: String? = (pinned == "DEFAULT") ? nil : pinned

            do {
                let (container, sessions) = try openStore(label: pinnedLabel)

                let sessionCount = sessions.count
                let completedCount = sessions.filter { $0.status == .completed }.count
                let loggedSetCount = computeLoggedSetCount(from: sessions)

                print("🔒 Using PINNED store: \(pinned) sessions=\(sessionCount) completed=\(completedCount) loggedItems=\(loggedSetCount)")

                self.sharedModelContainer = container
                runStartupBackfills(using: container)
                return
            } catch {
                print("⚠️ Failed to open PINNED store \(pinned). Falling back to scan. Error: \(error)")
            }
        }

        struct StoreScore {
            let container: ModelContainer
            let label: String
            let sessionCount: Int
            let completedCount: Int
            let loggedSetCount: Int

            var score: Int {
                (completedCount * 1_000_000) + (loggedSetCount * 1_000) + sessionCount
            }
        }

        var best: StoreScore? = nil

        for c in candidates {
            let fileURL = appSupport.appendingPathComponent(c.filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            do {
                let labelText = c.label ?? "DEFAULT"
                let (container, sessions) = try openStore(label: c.label)

                let sessionCount = sessions.count
                let completedCount = sessions.filter { $0.status == .completed }.count
                let loggedSetCount = computeLoggedSetCount(from: sessions)

                let scored = StoreScore(
                    container: container,
                    label: labelText,
                    sessionCount: sessionCount,
                    completedCount: completedCount,
                    loggedSetCount: loggedSetCount
                )

                print("✅ Opened store: \(labelText) sessions=\(sessionCount) completed=\(completedCount) loggedItems=\(loggedSetCount) score=\(scored.score)")

                if best == nil || scored.score > best!.score {
                    best = scored
                }
            } catch {
                let labelText = c.label ?? "DEFAULT"
                print("⚠️ Failed to open store \(labelText): \(error)")
            }
        }

        guard let best else {
            print("⚠️ No preferred SwiftData store found — falling back to DEFAULT store.")
            do {
                let (container, _) = try openStore(label: nil)
                self.sharedModelContainer = container
                runStartupBackfills(using: container)
                return
            } catch {
                fatalError("Failed to open DEFAULT store as fallback: \(error)")
            }
        }

        print("🏆 Using store: \(best.label) sessions=\(best.sessionCount) completed=\(best.completedCount) loggedItems=\(best.loggedSetCount)")

        UserDefaults.standard.set(best.label, forKey: pinKey)

        self.sharedModelContainer = best.container
        runStartupBackfills(using: best.container)
    }

    @State private var appResetID = UUID()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(appResetID)
                .onReceive(NotificationCenter.default.publisher(for: .didRestoreBackup)) { _ in
                    appResetID = UUID()
                }
                .modelContainer(sharedModelContainer)
        }
    }
}
