import SwiftUI
import SwiftData
import UniformTypeIdentifiers

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

                                Picker("Equipment", selection: Binding(
                                    get: { profile.equipmentProfile },
                                    set: { profile.equipmentProfile = $0 }
                                )) {
                                    Text("Commercial Gym").tag(EquipmentProfile.commercial)
                                    Text("Home Gym").tag(EquipmentProfile.homeGym)
                                    Text("Dumbbells Only").tag(EquipmentProfile.dumbbellsOnly)
                                }

                                Toggle("Use Kilograms", isOn: Binding(
                                    get: { profile.usesKilograms },
                                    set: { profile.usesKilograms = $0 }
                                ))

                                HStack {
                                    Text("Min Load Increment")
                                    Spacer()
                                    TextField("lbs", value: Binding(
                                        get: { profile.minLoadIncrement },
                                        set: { profile.minLoadIncrement = $0 }
                                    ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                    Text(profile.usesKilograms ? "kg" : "lbs")
                                        .foregroundStyle(.secondary)
                                }

                                HStack {
                                    Text("Body Weight")
                                    Spacer()
                                    TextField("0", value: Binding(
                                        get: { profile.bodyWeight ?? 0 },
                                        set: { profile.bodyWeight = $0 > 0 ? $0 : nil }
                                    ), format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                    Text(profile.usesKilograms ? "kg" : "lbs")
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
            


            // MARK: - Mesocycle
                        Section("Mesocycle") {
                            Button(role: .destructive) {
                                let today = Calendar.current.startOfDay(for: Date())
                                MesoLifecycle.confirmStartNewMeso(on: today)
                                AppStateBridge.setActiveMesoStartDate(today, in: context)
                                AppStateBridge.setScheduledNextMesoStartDate(nil, in: context)
                                AppStateBridge.setMesoPromptSnoozeUntil(nil, in: context)
                                AppStateBridge.setMesoAnchor(date: today, dayNumber: 1, in: context)
                            } label: {
                                Text("Reset Mesocycle to Week 1")
                            }

                            Text("Use this if your program got out of sync. Resets week and day labels to W1D1 from today without deleting your history.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }


            
            // MARK: - Data Repair
            Section("Data Repair") {
                            Button("Repair Exercise Data") {
                                fixExerciseIdMismatches()
                            }
                            Text("Run this if exercise history is showing incorrect exercises. Safe to run at any time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                Button("Remove Unrecognized Exercises") {
                                    removeOrphanedExerciseItems()
                                    removeOrphanedHistoryExercises()
                                }
                            Text("Removes logged sets from exercises that can no longer be identified. Does not delete sessions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                Button("Sync meso start date") {
                    syncMesoStartDate()
                }
                Text("Re-anchors Analytics to the currently active mesocycle block. Use this if Analytics is showing data from a previous block.")
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
        }
        .navigationTitle("Settings")
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

        let uuidPattern = #"^[0-9a-fA-F\s\-]{32,}$"#
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


}

// MARK: - Sheet item wrapper

private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
