import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context


        @Query(sort: \Session.date, order: .forward) private var sessions: [Session]
        @Query private var profiles: [UserProfile]

    // MARK: - Export state
    @State private var exportItem: ExportShareItem? = nil
    @State private var exportError: String? = nil

    @State private var showImportBackupPicker = false
    @State private var importMessage: String = ""
    @State private var showImportAlert = false

    // MARK: - Meso generation feedback
    @State private var mesoGenerationMessage: String = ""
    @State private var showMesoGenerationAlert = false

    // MARK: - About
    @State private var didCopyBuildInfo = false
    @State private var showMuscleRanges = false
    @State private var pendingRepair: SettingsRepair?
    

    var body: some View {


        Form {
            // MARK: - Profile
                        if let profile = profiles.first {
                            Section("Profile") {
                                Picker("Goal", selection: Binding(
                                    get: { profile.primaryGoal },
                                    set: { profile.primaryGoal = $0 }
                                )) {
                                    Text("Hypertrophy").tag(PrimaryGoal.hypertrophy)
                                    Text("Strength").tag(PrimaryGoal.strength)
                                    Text("Fat Loss").tag(PrimaryGoal.fatLoss)
                                    Text("Longevity").tag(PrimaryGoal.longevity)
                                }

                                Picker("Experience", selection: Binding(
                                    get: { profile.experience },
                                    set: { profile.experience = $0 }
                                )) {
                                    ForEach(TrainingExperience.allCases, id: \.self) {
                                        Text($0.label).tag($0)
                                    }
                                }

                                UnitSection(profile: profile)

                                HStack {
                                    Text("Min Load Increment")
                                    Spacer()
                                    TextField(profile.loadUnit.label, value: Binding(
                                        get: { profile.minLoadIncrement },
                                        set: { profile.minLoadIncrement = $0 }
                                    ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                    Text(profile.loadUnit.label)
                                        .foregroundStyle(.secondary)
                                }

                                HStack {
                                    Text("Body Weight")
                                    Spacer()
                                    StoredLoadField(placeholder: "0", unit: profile.loadUnit, stored: profile.bodyWeight) {
                                        profile.bodyWeight = ($0 ?? 0) > 0 ? $0 : nil
                                    }
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                    Text(profile.loadUnit.label)
                                        .foregroundStyle(.secondary)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Birthdate")
                                        Spacer()
                                        if let birth = profile.birthDateOverride {
                                            DatePicker(
                                                "Birthdate",
                                                selection: Binding(
                                                    get: { birth },
                                                    set: { profile.birthDateOverride = $0 }
                                                ),
                                                in: ...Date(),
                                                displayedComponents: .date
                                            )
                                            .labelsHidden()
                                            Button("Clear") { profile.birthDateOverride = nil }
                                        } else {
                                            Button("Set") {
                                                profile.birthDateOverride = Calendar.current.date(byAdding: .year, value: -30, to: Date())
                                            }
                                        }
                                    }
                                    Text("Only used for heart-rate zones, when Health doesn't have your date of birth.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack {
                                    Text("Session Length")
                                    Spacer()
                                    TextField("min", value: Binding(
                                        get: { profile.sessionLengthMinutes },
                                        set: { profile.sessionLengthMinutes = $0 }
                                    ), format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                    Text("min")
                                        .foregroundStyle(.secondary)
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Joint Limitations")
                                        .font(.subheadline)
                                    FlowLayout(spacing: 8) {
                                        ForEach(InjuryFlag.allCases, id: \.self) { flag in
                                            let isSelected = profile.injuryFlags.contains(flag)
                                            Button {
                                                var flags = profile.injuryFlags
                                                if isSelected {
                                                    flags.removeAll { $0 == flag }
                                                } else {
                                                    flags.append(flag)
                                                }
                                                profile.injuryFlags = flags
                                            } label: {
                                                Text(flag.rawValue.camelCaseToWords())
                                                    .font(.caption)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 5)
                                                    .background(isSelected ? Color.blue : Color(.systemGray5))
                                                    .foregroundColor(isSelected ? .white : .primary)
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
            


            // MARK: - Equipment
            if let profile = profiles.first {
                Section {
                    EquipmentEditor(
                        preset: Binding(
                            get: { profile.equipmentPreset },
                            set: { profile.equipmentPreset = $0 }
                        ),
                        checklist: Binding(
                            get: { profile.equipmentChecklist },
                            set: { profile.equipmentChecklist = $0 }
                        )
                    )
                } header: {
                    Text("Equipment")
                } footer: {
                    Text("Changes apply to your next program. Your current meso is unchanged.")
                }
            }

            // MARK: - Mesocycle
                        Section("Mesocycle") {
                            Button(role: .destructive) {
                                pendingRepair = .resetMeso
                            } label: {
                                Text("Reset Mesocycle to Week 1")
                            }

                            Text("Use this if your program got out of sync. Resets week and day labels to W1D1 from today without deleting your history.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }


            // MARK: - Analytics
            if let profile = profiles.first {
                Section("Analytics") {
                    Button(profile.muscleSetRangesStored == nil ? "Weekly set ranges" : "Weekly set ranges (customized)") {
                        showMuscleRanges = true
                    }
                }
            }

            // MARK: - Data Repair
            Section("Data Repair") {
                            Button("Repair Exercise Data") {
                                pendingRepair = .exerciseData
                            }
                            Text("Run this if exercise history is showing incorrect exercises. Safe to run at any time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                Button("Remove Unrecognized Exercises") {
                                    pendingRepair = .unrecognized
                                }
                            Text("Removes logged sets from exercises that can no longer be identified. Does not delete sessions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                Button("Sync meso start date") {
                    pendingRepair = .syncMeso
                }
                Text("Re-anchors Analytics to the currently active mesocycle block. Use this if Analytics is showing data from a previous block.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Repair maintenance loads") {
                    pendingRepair = .maintenanceLoads
                }
                Text("Resets inflated planned loads on upcoming maintenance sessions back to your last completed actuals for that exercise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                        }

            // MARK: - Export
            Section("Export") {
                Button("Import Full Backup (JSON)") {
                    showImportBackupPicker = true
                }
                .foregroundStyle(.red)

                Button("Export Full Backup (JSON)") {
                    exportError = nil
                    do {
                        let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: context)
                        guard FileManager.default.fileExists(atPath: result.url.path) else {
                            exportItem = nil
                            exportError = "Backup file was not created at:\n\(result.url.path)"
                            return
                        }
                        exportItem = ExportShareItem(url: result.url)
                    } catch {
                        exportItem = nil
                        exportError = error.localizedDescription
                    }
                }

                Button("Export Completed Sessions (CSV)") {
                    exportError = nil
                    do {
                        let result = try SetsV1CSVExporter.exportCompletedSessionsCSV(modelContext: context)
                        guard result.rowCount > 0 else {
                            exportItem = nil
                            exportError = "No completed sessions found to export."
                            return
                        }
                        guard FileManager.default.fileExists(atPath: result.url.path) else {
                            exportItem = nil
                            exportError = "Export file was not created at:\n\(result.url.path)"
                            return
                        }
                        exportItem = ExportShareItem(url: result.url)
                    } catch {
                        exportItem = nil
                        exportError = error.localizedDescription
                    }
                }

                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("JSON backup exports app state, meso blocks, sessions, history, and notes. CSV exports completed sessions only in sets_v1 format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - About
            // Tap to copy, so a bug report can carry the exact build without the
            // user retyping a git hash.
            Section("About") {
                Button {
                    UIPasteboard.general.string = BuildInfo.description
                    withAnimation { didCopyBuildInfo = true }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(BuildInfo.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        if didCopyBuildInfo {
                            Label("Copied", systemImage: "checkmark")
                                .font(.caption2)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        } else {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Build information")
                .accessibilityValue(BuildInfo.description)
                .accessibilityHint("Double tap to copy")
                .onChange(of: didCopyBuildInfo) { _, copied in
                    guard copied else { return }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { didCopyBuildInfo = false }
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showMuscleRanges) {
            if let profile = profiles.first {
                NavigationStack {
                    MuscleRangesEditor(profile: profile)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showMuscleRanges = false } } }
                }
            }
        }
        .onAppear(perform: ensureProfileExists)
        .sheet(item: $exportItem) { item in
            ShareSheet(items: [item.url])
        }

        .fileImporter(
            isPresented: $showImportBackupPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }

                let didAccess = url.startAccessingSecurityScopedResource()

                // Post notification first — tears down live SwiftData views before deletion
                NotificationCenter.default.post(name: .didRestoreBackup, object: nil)

                Task { @MainActor in
                    defer {
                        if didAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    do {
                        let restore = try BackupSnapshotImporter.importFullBackupJSON(
                            from: url,
                            modelContainer: context.container
                        )
                        importMessage = """
                        Restored backup successfully.

                        Meso blocks: \(restore.mesoBlockCount)
                        Sessions: \(restore.sessionCount)
                        Session history: \(restore.sessionHistoryCount)
                        Exercise notes: \(restore.exerciseNoteCount)
                        """
                    } catch {
                        importMessage = "Backup import failed: \(error.localizedDescription)"
                    }
                    showImportAlert = true
                }
            } catch {
                importMessage = "Backup import failed: \(error.localizedDescription)"
                showImportAlert = true
            }
        }
        .confirmationDialog(
            pendingRepair?.title ?? "",
            isPresented: Binding(get: { pendingRepair != nil }, set: { if !$0 { pendingRepair = nil } }),
            titleVisibility: .visible,
            presenting: pendingRepair
        ) { repair in
            Button(repair.confirmLabel, role: repair.isDestructive ? .destructive : nil) { runRepair(repair) }
            Button("Cancel", role: .cancel) { }
        } message: { repair in
            Text(repair.message)
        }
        .alert("Mesocycle", isPresented: $showMesoGenerationAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(mesoGenerationMessage)
        }
        .alert("Backup Import", isPresented: $showImportAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importMessage)
        }
        
    }

    // MARK: - Helpers

    private func runRepair(_ repair: SettingsRepair) {
        switch repair {
        case .resetMeso:
            let today = Calendar.current.startOfDay(for: Date())
            MesoLifecycle.confirmStartNewMeso(on: today)
            AppStateBridge.setActiveMesoStartDate(today, in: context)
            AppStateBridge.setScheduledNextMesoStartDate(nil, in: context)
            AppStateBridge.setMesoPromptSnoozeUntil(nil, in: context)
            AppStateBridge.setMesoAnchor(date: today, dayNumber: 1, in: context)
        case .exerciseData: fixExerciseIdMismatches()
        case .unrecognized:
            removeOrphanedExerciseItems()
            removeOrphanedHistoryExercises()
        case .syncMeso: syncMesoStartDate()
        case .maintenanceLoads: repairMaintenanceLoads()
        }
    }

    private func fixExerciseIdMismatches() {
        let descriptor = FetchDescriptor<SessionItem>()
        guard let items = try? context.fetch(descriptor) else {
            presentMesoGenerationMessage("Failed to fetch session items.")
            return
        }

        var fixedCount = 0

        for item in items {
            guard let snapshot = item.exerciseNameSnapshot,
                  !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let correctId = ExerciseCatalog.canonicalBuiltInId(forExerciseName: snapshot) else { continue }
            if item.exerciseId != correctId {
                print("🔧 Fixing \(snapshot): \(item.exerciseId) → \(correctId)")
                item.exerciseId = correctId
                fixedCount += 1
            }
        }

        if fixedCount > 0 {
            try? context.save()
            presentMesoGenerationMessage("Fixed \(fixedCount) exercise ID mismatch\(fixedCount == 1 ? "" : "es").")
        } else {
            presentMesoGenerationMessage("No mismatches found.")
        }
    }
    
    private func removeOrphanedExerciseItems() {
            let descriptor = FetchDescriptor<SessionItem>()
            guard let items = try? context.fetch(descriptor) else {
                presentMesoGenerationMessage("Failed to fetch session items.")
                return
            }

            var removedCount = 0

            for item in items {
                let id = item.exerciseId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }

                let canonical = ExerciseCatalog.canonicalExerciseId(for: id)
                let isKnown = ExerciseCatalog.builtIn.contains { $0.id == canonical }
                let isCustomId = canonical.hasPrefix("custom_")

                if !isKnown && !isCustomId {
                    context.delete(item)
                    removedCount += 1
                }
            }

            if removedCount > 0 {
                try? context.save()
                presentMesoGenerationMessage("Removed \(removedCount) unrecognized exercise\(removedCount == 1 ? "" : "s").")
            } else {
                presentMesoGenerationMessage("No unrecognized exercises found.")
            }
        }

    private func removeOrphanedHistoryExercises() {
            let descriptor = FetchDescriptor<SessionHistory>()
            guard let histories = try? context.fetch(descriptor) else { return }

            var removedCount = 0

            for history in histories {
                let before = history.exercises.count
                history.exercises = history.exercises.filter { exercise in
                    let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let words = name.components(separatedBy: .whitespaces)
                                        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
                                        let isUUID = words.count >= 2 && words.allSatisfy { word in
                                            !word.isEmpty && word.unicodeScalars.allSatisfy { hexChars.contains($0) }
                                        }
                    return !isUUID
                }
                removedCount += before - history.exercises.count
            }

            if removedCount > 0 {
                try? context.save()
                presentMesoGenerationMessage("Removed \(removedCount) unrecognized exercise record\(removedCount == 1 ? "" : "s") from history.")
            } else {
                presentMesoGenerationMessage("No unrecognized records found.")
            }
        }
    
    private func presentMesoGenerationMessage(_ message: String) {
        mesoGenerationMessage = message
        showMesoGenerationAlert = true
    }

    private func syncMesoStartDate() {
        let descriptor = FetchDescriptor<MesoBlock>()
        guard let blocks = try? context.fetch(descriptor) else {
            presentMesoGenerationMessage("Failed to fetch meso blocks.")
            return
        }
        guard let activeMeso = blocks.first(where: { $0.status == .active }) else {
            presentMesoGenerationMessage("No active mesocycle found.")
            return
        }

        MesoLifecycle.confirmStartNewMeso(on: activeMeso.startDate)
        AppStateBridge.setActiveMesoStartDate(activeMeso.startDate, in: context)
        let formatted = activeMeso.startDate.formatted(date: .abbreviated, time: .omitted)
        presentMesoGenerationMessage("Synced meso start date to \(formatted).")
    }

    /// One-time repair for loads that were inflated by progressive overload
    /// before LoadProjectionService/PlanMemoryEngine learned to hold
    /// maintenance/deload items. Resets each upcoming maintenance item's
    /// suggestedLoad/plannedLoadsBySet back to the most recently completed
    /// session's actual loads for that exercise, scoped to the active meso.
    private func repairMaintenanceLoads() {
        let descriptor = FetchDescriptor<MesoBlock>()
        guard let blocks = try? context.fetch(descriptor) else {
            presentMesoGenerationMessage("Failed to fetch meso blocks.")
            return
        }
        guard let activeMeso = blocks.first(where: { $0.status == .active }) else {
            presentMesoGenerationMessage("No active mesocycle found.")
            return
        }

        let blockSessions = activeMeso.sessions
        let completedSessionsByDateDesc = blockSessions
            .filter { $0.status == .completed }
            .sorted { $0.date > $1.date }
        let upcomingSessions = blockSessions.filter {
            $0.status == .planned || $0.status == .inProgress
        }

        var repairedDetails: [String] = []
        let repairUnit = (try? context.fetch(FetchDescriptor<UserProfile>()).first)?.loadUnit ?? .lb

        for upcoming in upcomingSessions {
            for item in upcoming.items {
                guard item.waveRaw?.lowercased() == "deload", item.suggestedLoad > 0 else { continue }

                guard let mostRecentCompletedItem = completedSessionsByDateDesc
                    .compactMap({ $0.items.first { $0.exerciseId == item.exerciseId } })
                    .first
                else { continue } // no completed session for this exercise yet — leave seeded value

                let oldLoad = item.suggestedLoad
                let actualLoad = mostRecentCompletedItem.actualLoads.first(where: { $0 > 0 }) ?? 0

                item.suggestedLoad = actualLoad
                item.plannedLoadsBySet = mostRecentCompletedItem.actualLoads

                let name = item.exerciseNameSnapshot ?? item.exerciseId
                repairedDetails.append("\(name): \(LoadFormatter(unit: repairUnit).oneDecimal(oldLoad)) → \(LoadFormatter(unit: repairUnit).oneDecimal(actualLoad))")
            }
        }

        if !repairedDetails.isEmpty {
            try? context.save()
            presentMesoGenerationMessage(
                "Repaired \(repairedDetails.count) maintenance load\(repairedDetails.count == 1 ? "" : "s"):\n"
                + repairedDetails.joined(separator: "\n")
            )
        } else {
            presentMesoGenerationMessage("No inflated maintenance loads found.")
        }
    }

    private func inferredTrainingWeekdays() -> [Int] {
        let cal = Calendar.current
        let candidateSessions = sessions
            .filter { $0.items.isEmpty == false }
            .sorted { $0.date < $1.date }
        let weekdays = Array(
            Set(candidateSessions.map { cal.component(.weekday, from: $0.date) })
        ).sorted()
        return weekdays
    }

    private func hasSessionsOnOrAfter(_ startDate: Date) -> Bool {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: startDate)
        return sessions.contains { session in
            cal.startOfDay(for: session.date) >= startDay
        }
    }

    /// The Profile section (including Body Weight) only renders when a UserProfile
    /// exists. Onboarding normally creates one, but accounts that skipped that path
    /// would otherwise see no Profile section and no way to create one.
    private func ensureProfileExists() {
        guard profiles.isEmpty else { return }
        context.insert(UserProfile())
        try? context.save()
    }

}

// MARK: - Sheet item wrapper

private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}


// MARK: - Weekly set ranges

/// Edits the weekly hard-set range per muscle used by "Weekly sets per muscle". Only numbers that differ from the
/// defaults are stored; Reset returns a muscle (or all of them) to the defaults.
struct MuscleRangesEditor: View {
    let profile: UserProfile

    private func range(_ m: FineMuscle) -> MuscleSetRange { profile.muscleSetRanges[m] ?? MuscleVolumeRanges.defaults[m]! }
    private func isCustom(_ m: FineMuscle) -> Bool { range(m) != MuscleVolumeRanges.defaults[m] }

    private func set(_ m: FineMuscle, _ r: MuscleSetRange) {
        var all = profile.muscleSetRanges
        all[m] = r
        profile.muscleSetRanges = all
    }

    var body: some View {
        List {
            Section {
                ForEach(FineMuscle.allCases, id: \.self) { m in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(m.displayName).font(.subheadline).fontWeight(.semibold)
                            Spacer()
                            if isCustom(m) {
                                Button("Reset") { set(m, MuscleVolumeRanges.defaults[m]!) }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                            }
                        }
                        Stepper(value: Binding(get: { range(m).min }, set: { set(m, MuscleSetRange(min: $0, max: range(m).max)) }),
                                in: 0...range(m).max, step: 1) {
                            Text("Minimum: \(Int(range(m).min)) sets / week")
                        }
                        Stepper(value: Binding(get: { range(m).max }, set: { set(m, MuscleSetRange(min: range(m).min, max: $0)) }),
                                in: range(m).min...40, step: 1) {
                            Text("Maximum: \(Int(range(m).max)) sets / week")
                        }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Starting points from common hypertrophy guidance, not a prescription. Counts are weighted hard sets: a synergist counts 0.25 or 0.5 of a set.")
            }
            Section {
                Button("Reset all to defaults", role: .destructive) { profile.muscleSetRanges = MuscleVolumeRanges.defaults }
                    .disabled(profile.muscleSetRangesStored == nil)
            }
        }
        .navigationTitle("Weekly set ranges")
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// The Settings actions that rewrite stored data. Each is confirmed first, saying what it scans and what it can change.
enum SettingsRepair: Identifiable {
    case resetMeso, exerciseData, unrecognized, syncMeso, maintenanceLoads
    var id: Self { self }

    var title: String {
        switch self {
        case .resetMeso: return "Reset mesocycle to Week 1?"
        case .exerciseData: return "Repair exercise data?"
        case .unrecognized: return "Remove unrecognized exercises?"
        case .syncMeso: return "Sync meso start date?"
        case .maintenanceLoads: return "Repair maintenance loads?"
        }
    }

    var message: String {
        switch self {
        case .resetMeso:
            return "Relabels this block as Week 1, Day 1 starting today and clears the scheduled next-meso date. Your logged history is not deleted, but week and day labels change and cannot be restored automatically."
        case .exerciseData:
            return "Scans every session and history entry and re-links exercise ids that no longer match the catalog. It changes only the ids stored on logged exercises, never sets, reps or loads. Cannot be undone."
        case .unrecognized:
            return "Scans all sessions and history for exercises that can no longer be identified and permanently deletes their logged sets. Sessions themselves are kept. Export a backup first if unsure."
        case .syncMeso:
            return "Moves the analytics start date to the currently active mesocycle block. Only the start date changes; no sessions are edited."
        case .maintenanceLoads:
            return "Scans upcoming maintenance sessions and resets planned loads that are above your last completed load for that exercise back to that load. Completed sessions are not changed. Cannot be undone."
        }
    }

    var confirmLabel: String {
        switch self {
        case .resetMeso: return "Reset to Week 1"
        case .unrecognized: return "Delete sets"
        default: return "Run repair"
        }
    }

    var isDestructive: Bool { self == .resetMeso || self == .unrecognized }
}
