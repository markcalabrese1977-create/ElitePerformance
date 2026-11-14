import SwiftUI
import SwiftData

@main
struct ElitePerformanceApp: App {

    private let store: StoreOpenResult

    init() {
        // First line of the launch log, before any store work — so a console or
        // device log always opens with which build produced everything below it.
        print("ℹ️ \(BuildInfo.logLine)")

        // ONE way to open the store, in every build configuration. If it cannot be opened nothing else happens: no
        // backfills, no writes, no deleting, moving or recreating of any store file (see AppStoreOpener).
        let result = AppStoreOpener.open()
        self.store = result
        if case .opened(let container) = result {
            // Backfills run through the gate: an interrupted restore is answered first (see StartupGate).
            StartupGate.shared.begin(container: container)
        }
    }

    @State private var appResetID = UUID()

    var body: some Scene {
        WindowGroup {
            switch store {
            case .opened(let container):
                LaunchRoot(gate: StartupGate.shared) {
                    ContentView()
                        .id(appResetID)
                        .onReceive(NotificationCenter.default.publisher(for: .didRestoreBackup)) { _ in
                            appResetID = UUID()
                        }
                        .modelContainer(container)
                }
            case .failed(let message):
                StoreOpenFailedView(message: message)
            }
        }
    }
}

/// Shown instead of the app when the store cannot be opened. Nothing has been changed.
struct StoreOpenFailedView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your data couldn't be opened — nothing has been changed")
                .font(.title2.bold())
            Text("Close and reopen the app. If this keeps happening, your data is still on this device untouched; send this message so it can be fixed:")
            ScrollView { Text(message).font(.footnote.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(24)
    }
}

/// Shows the app once any interrupted restore has been answered; until then only the blocking prompt.
struct LaunchRoot<Content: View>: View {
    @ObservedObject var gate: StartupGate
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if let missing = gate.missingData {
                MissingDataView(gate: gate, expected: missing.expectedSessions)
            } else if gate.interrupted == nil {
                content()
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
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
        (String(describing: SessionHistoryExerciseOrderBackfill.self), { SessionHistoryExerciseOrderBackfill.runIfNeeded(in: $0) }),
        (String(describing: MissedSourceSeedBackfill.self), { MissedSourceSeedBackfill.runIfNeeded(in: $0) }),
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

/// Blocking screen: the store opened with no completed sessions although the last successful launch had some.
struct MissingDataView: View {
    @ObservedObject var gate: StartupGate
    let expected: Int
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(StartupGate.missingDataMessage).font(.title2.bold())
            Text("The last time the app opened successfully it held \(expected) completed sessions; now it holds none.")
            if let error = gate.missingDataError { Text(error).foregroundStyle(.red) }
            if !gate.backupLookupDone {
                ProgressView("Looking for a backup…")
            } else if let backup = gate.newestBackup, let summary = gate.newestBackupSummary {
                Text("Newest verified backup: \(backup.date.formatted(date: .abbreviated, time: .shortened)) · \(summary.completedSessions) completed sessions.")
                Button("Restore newest backup") { gate.restoreNewestBackup() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("No backup was found on this device or in iCloud.")
                Text("To use the app with empty data anyway, type \(StartupGate.continueWord).")
                TextField(StartupGate.continueWord, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Continue with empty data", role: .destructive) { gate.continueWithEmptyData(typed: typed) }
                    .buttonStyle(.bordered)
                    .disabled(!StartupGate.acceptsContinue(typed: typed))
            }
            Spacer()
        }
        .padding(24)
    }
}
