import Foundation

/// Every UserDefaults / App Group key the app writes, and what a backup does about it. The BA3 test fails when
/// production code uses a key that is not matched here, when an entry no longer matches any key in the code, and when
/// an entry claims a backup path that does not exist.
///
/// New persisted setting? Prefer a model field (and the BA1/BA2 rules). If it must live in UserDefaults, register it
/// here with its disposition.
enum PersistedKeyRegistry {

    enum Match {
        case exact(String)
        case prefix(String)
        case suffix(String)

        func matches(_ key: String) -> Bool {
            switch self {
            case .exact(let k): return key == k
            case .prefix(let p): return key.hasPrefix(p)
            case .suffix(let s): return key.hasSuffix(s)
            }
        }

        /// Whether a key literal found in code (which may be only the constant part of a built key) falls under this match.
        func covers(declared literal: String) -> Bool {
            switch self {
            case .exact(let k): return literal == k
            case .prefix(let p): return literal.hasPrefix(p) || p.hasPrefix(literal)
            case .suffix(let s): return literal.hasSuffix(s)
            }
        }
    }

    enum Disposition {
        /// Mirrored in `AppState.<field>`, which the backup exports and the importer restores.
        case appState(field: String)
        /// Its data is moved into `<entity>` rows, which the backup exports.
        case model(entity: String, via: String)
        /// Derived data: not exported, rebuilt from restored data on import.
        case rebuiltOnImport(String)
        /// Deliberately not backed up, with the reason.
        case excluded(String)
    }

    struct Entry {
        let match: Match
        let disposition: Disposition
    }

    static let entries: [Entry] = [
        // Meso lifecycle: UserDefaults mirrors of AppState (AppStateBridge keeps them in step).
        Entry(match: .exact("meso.activeStartDateEpoch"), disposition: .appState(field: "activeMesoStartDate")),
        Entry(match: .exact("meso.scheduledStartDateEpoch"), disposition: .appState(field: "scheduledNextMesoStartDate")),
        Entry(match: .exact("meso.promptSnoozeEpoch"), disposition: .appState(field: "mesoPromptSnoozeUntil")),
        Entry(match: .exact("meso.anchorDate"), disposition: .appState(field: "mesoAnchorDate")),
        Entry(match: .exact("meso.anchorDayNumber"), disposition: .appState(field: "mesoAnchorDayNumber")),

        // Session screen preference.
        Entry(match: .exact("warmup.isHidden.v1"), disposition: .appState(field: "warmupHidden")),

        // Custom exercises: SwiftData is the source of truth, this key is its context-free mirror.
        Entry(match: .exact("custom_exercises_v2"),
              disposition: .rebuiltOnImport("mirror of CustomExercise rows; ExerciseCatalog.rebuildCustomMirror runs on import")),

        // Legacy per-user custom-exercise stores: read-only inputs of an old migration.
        Entry(match: .prefix("custom_exercises_"),
              disposition: .excluded("legacy per-user keys, read-only migration inputs; never written")),

        // Legacy exercise notes: LegacyExerciseNotesBackfill moves them into ExerciseNote.
        Entry(match: .prefix("exerciseNotes.v1"),
              disposition: .model(entity: "ExerciseNote", via: "LegacyExerciseNotesBackfill")),

        // App Group projection for HealthDashboard.
        Entry(match: .prefix("mechanicalLoad."),
              disposition: .rebuiltOnImport("derived from SessionHistory; MechanicalLoadProjector.projectAll runs on import")),

        // Device-local.
        Entry(match: .prefix("dataSentinel."),
              disposition: .excluded("missing-data sentinel: the completed-session count of THIS device's store after its last successful launch (app-group defaults); describes the device, not the training data, so a restore must not carry it")),
        Entry(match: .prefix("autoBackup."),
              disposition: .excluded("automatic-backup status (last success, iCloud or not, last launch commit, banner dismissal): device state about THIS device's backups; a restore must not overwrite it, or an old backup would claim 'backed up just now'")),
        Entry(match: .prefix("legacyStore."),
              disposition: .excluded("legacy-store relocation: the older store files already offered to this device's lifter; describes files on THIS device, so a restore must not carry it")),
        Entry(match: .exact("activeSwiftDataStoreLabel.v1"),
              disposition: .excluded("read-only input: the store label pinned by builds before the one-way store opener; read to explain a relocation offer, never written")),
        Entry(match: .exact("prIndexRuleVersion"),
              disposition: .excluded("PRIndexRuleBackfill's applied rule version: device-local; PRIndex is rebuilt on import")),
        Entry(match: .suffix(".completed"),
              disposition: .excluded("migration completion flag: device-local; migrations are idempotent and report not needed after a restore")),

        // Exercise picker convenience.
        Entry(match: .exact("exercisePicker.recentIds.v1"),
              disposition: .excluded("the exercises last picked in a picker (recent picks): a device-local convenience, rebuilt by use; a restore need not carry it")),

        // Effort tracking.
        Entry(match: .exact("effortTracking.mode.v1"),
              disposition: .excluded("mirror of UserProfile.effortModeRaw (resolved): the profile field travels in the backup; the mirror is rebuilt from it at launch and after a restore (StartupBackfills.run)")),

        // Per-session UI state.
        Entry(match: .prefix("warmup_crankyJoint_"), disposition: .excluded("per-session UI state")),
        Entry(match: .prefix("warmup_done_"), disposition: .excluded("per-session UI state")),
    ]

    /// The entry for a concrete key: exact matches win over prefix and suffix matches.
    static func entry(for key: String) -> Entry? {
        entries.first { if case .exact = $0.match { return $0.match.matches(key) } else { return false } }
            ?? entries.first { $0.match.matches(key) }
    }
}
