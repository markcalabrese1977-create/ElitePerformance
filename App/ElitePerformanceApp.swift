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

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        // ✅ Store pin (prevents “accidental flip” between stores)
        let pinKey = "activeSwiftDataStoreLabel.v1"

        // Candidate stores we may have created over time.
        // IMPORTANT: we only try ones that already exist, so we don't create new empty stores.
        let candidates: [(label: String?, filename: String)] = [
            (nil, "default.store"),
            ("ElitePerformanceStore", "ElitePerformanceStore.store"),
            ("ElitePerformanceStore_v2", "ElitePerformanceStore_v2.store")
        ]

        // MARK: - Helper: open a specific store label (DEFAULT or named)

        func openStore(label: String?) throws -> (container: ModelContainer, sessions: [Session]) {
            let config: ModelConfiguration
            if let name = label, name != "DEFAULT" {
                config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: false)
            } else {
                // Default (unnamed) store
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
                    if hasLoad || hasReps { count += 1 }
                }
            }
            return count
        }

        // ✅ 1) If we have a pinned store, ALWAYS use it (no scanning)
        if let pinned = UserDefaults.standard.string(forKey: pinKey) {
            let pinnedLabel: String? = (pinned == "DEFAULT") ? nil : pinned

            do {
                let (container, sessions) = try openStore(label: pinnedLabel)

                let sessionCount = sessions.count
                let completedCount = sessions.filter { $0.status == .completed }.count
                let loggedSetCount = computeLoggedSetCount(from: sessions)

                print("🔒 Using PINNED store: \(pinned) sessions=\(sessionCount) completed=\(completedCount) loggedItems=\(loggedSetCount)")

                self.sharedModelContainer = container
                return
            } catch {
                print("⚠️ Failed to open PINNED store \(pinned). Falling back to scan. Error: \(error)")
                // fall through to scan (recovery only)
            }
        }

        // ✅ 2) Otherwise, scan existing stores and choose best, then PIN it

        struct StoreScore {
            let container: ModelContainer
            let label: String
            let sessionCount: Int
            let completedCount: Int
            let loggedSetCount: Int

            // Heuristic:
            // - Completed sessions dominate
            // - Then actual logged sets (loads/reps)
            // - Then raw session count
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
            fatalError("No SwiftData store could be opened.")
        }

        print("🏆 Using store: \(best.label) sessions=\(best.sessionCount) completed=\(best.completedCount) loggedItems=\(best.loggedSetCount)")

        // ✅ Pin the chosen store so future launches cannot “flip”
        UserDefaults.standard.set(best.label, forKey: pinKey)

        self.sharedModelContainer = best.container
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(sharedModelContainer)
        }
    }
}
