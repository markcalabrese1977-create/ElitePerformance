import SwiftUI
import SwiftData

@main
struct ElitePerformanceApp: App {

    private let sharedModelContainer: ModelContainer

    init() {
        // First line of the launch log, before any store work — so a console or
        // device log always opens with which build produced everything below it.
        print("ℹ️ \(BuildInfo.logLine)")

        let schema = AppSchema.makeSchema()

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

        // Backfills run through the gate: an interrupted restore is answered first (see StartupGate).
        func runStartupBackfills(using container: ModelContainer) {
            StartupGate.shared.begin(container: container)
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
            // Steady state, not a fault. The three candidates above are LEGACY store files in the app's own Application Support
            // folder (older builds named their stores). With an App Group entitlement SwiftData keeps the default store in the
            // group container instead, so none of them exists and the default store (the real one) opens here, every launch.
            print("ℹ️ No legacy SwiftData store files found (the default store lives in the app group container) — opening the DEFAULT store.")
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
            LaunchRoot(gate: StartupGate.shared) {
                ContentView()
                .id(appResetID)
                .onReceive(NotificationCenter.default.publisher(for: .didRestoreBackup)) { _ in
                    appResetID = UUID()
                }
                .modelContainer(sharedModelContainer)
            }
        }
    }
}

/// Shows the app once any interrupted restore has been answered; until then only the blocking prompt.
struct LaunchRoot<Content: View>: View {
    @ObservedObject var gate: StartupGate
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if gate.interrupted == nil { content() } else { Color(.systemBackground).ignoresSafeArea() }
        }
        .alert("Restore interrupted", isPresented: Binding(get: { gate.interrupted != nil && gate.errorMessage == nil }, set: { _ in })) {
            Button("Restore") { gate.restore() }
            Button("Keep current data", role: .cancel) { gate.keepCurrentData() }
        } message: {
            Text(gate.interrupted?.message ?? "")
        }
        .alert("Restore interrupted", isPresented: $gate.showsMissingSnapshotNotice) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(StartupGate.missingSnapshotMessage)
        }
        .alert("Restore failed", isPresented: Binding(get: { gate.errorMessage != nil }, set: { _ in })) {
            Button("Try again") { gate.dismissError() }
            Button("Keep current data", role: .cancel) { gate.dismissError(); gate.keepCurrentData() }
        } message: {
            Text(gate.errorMessage ?? "")
        }
    }
}

/// The startup migration list, in app order. Only repairs that are safe on any user's store are registered;
/// one-shot repairs have been removed (see git history).
enum StartupBackfills {
    /// The registered backfills, in run order. `run` iterates this list, so the log lines and this list cannot drift apart.
    static let registered: [(name: String, run: (ModelContext) -> Void)] = [
        (String(describing: ExerciseNameSnapshotBackfill.self), { ExerciseNameSnapshotBackfill.runIfNeeded(in: $0) }),
        (String(describing: CanonicalExerciseIdMigration.self), { CanonicalExerciseIdMigration.runIfNeeded(in: $0) }),
        (String(describing: CustomExerciseDedupMigration.self), { CustomExerciseDedupMigration.runIfNeeded(in: $0) }),
        (String(describing: SessionHistoryBlockBackfill.self), { SessionHistoryBlockBackfill.runIfNeeded(in: $0) }),
        (String(describing: MechanicalLoadRecoveryMigration.self), { MechanicalLoadRecoveryMigration.runIfNeeded(in: $0) }),
        (String(describing: CustomExerciseStoreMigration.self), { CustomExerciseStoreMigration.runIfNeeded(in: $0) }),
        (String(describing: CustomExerciseUserDefaultsSyncRepair.self), { CustomExerciseUserDefaultsSyncRepair.runIfNeeded(in: $0) }),
        (String(describing: MesoBlockIsMaintenanceBackfill.self), { MesoBlockIsMaintenanceBackfill.runIfNeeded(in: $0) }),
        (String(describing: BodyweightPhantomLoadMigration.self), { BodyweightPhantomLoadMigration.runIfNeeded(in: $0) }),
        (String(describing: PrescribedSetsBackfill.self), { PrescribedSetsBackfill.runIfNeeded(in: $0) }),
        (String(describing: PlannedDateBackfill.self), { PlannedDateBackfill.runIfNeeded(in: $0) }),
        (String(describing: PRIndexRuleBackfill.self), { PRIndexRuleBackfill.runIfNeeded(in: $0) }),
        (String(describing: LegacyExerciseNotesBackfill.self), { LegacyExerciseNotesBackfill.runIfNeeded(in: $0) }),
    ]

    /// Runs every registered backfill and logs exactly one line for each: "<TypeName>: <result>".
    static func run(using container: ModelContainer) {
        let context = ModelContext(container)
        for backfill in registered {
            BackfillLog.collector = []
            backfill.run(context)
            let notes = BackfillLog.collector ?? []
            BackfillLog.collector = nil
            let line = "ℹ️ Backfill \(backfill.name): \(BackfillLog.result(from: notes))"
            print(line)
            BackfillLog.lineSink?(line)
        }
    }
}
