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

    /// Restore: the automatic backups on this device and in iCloud, and the pre-import undo. Every row here replaces the data on
    /// this device after a confirmation (see `RestoreConfirmSheet`), so they are red and live one screen away from Settings.
    private var restoreScreen: some View {
        List {
            Section {
                if backupFiles.isEmpty {
                    Text("No automatic backups found on this device or in iCloud.").foregroundStyle(.secondary)
                }
                ForEach(backupFiles.prefix(10)) { file in
                    Button {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: file.url)
                        pendingRestore = PendingRestore(url: file.url, isTemporaryCopy: false)
                    } label: {
                        Text("Restore from \(file.date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    .foregroundStyle(.red)
                }
            } header: {
                Text("Automatic backups")
            } footer: {
                Text("Restoring replaces the data on this device. A copy of your current data is saved first, and you see both side by side before anything changes.")
            }
            Section {
                if let snapshot = PreImportSnapshots.undoCandidate() {
                    Button("Restore pre-import state (\(snapshot.date.formatted(date: .abbreviated, time: .shortened)))") {
                        pendingRestore = PendingRestore(url: snapshot.url, isTemporaryCopy: false)
                    }
                    .foregroundStyle(.red)
                } else {
                    Text("Nothing to undo.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Undo the last restore")
            } footer: {
                Text("Your data as it was just before the last import or restore. Available for 30 days.")
            }
        }
        .navigationTitle("Restore")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshBackups() }
    }

    /// Move data: bring a file in, or take your data out.
    private var moveDataScreen: some View {
        List {
            Section("Import") {
                Button("Import Full Backup (JSON)") {
                    showImportBackupPicker = true
                }
                .foregroundStyle(.red)
            }
            Section("Export") {
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
                .disabled(!rowAvailability.exportEnabled)

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
                .disabled(!rowAvailability.exportEnabled)

                if !rowAvailability.exportEnabled {
                    Text("Nothing to export yet. Import works any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("The JSON backup holds everything needed to rebuild this app: your profile and settings, training blocks, every session with its plan and logged sets, history, custom exercises and notes. The CSV holds completed sessions only (sets_v1 format), for spreadsheets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Move data")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Automatic backups
    @ObservedObject private var autoBackup = AutoBackupService.shared
    @State private var backupFiles: [AutoBackupFile] = []
    @State private var backupsAreOffDevice = true
    @State private var backupBusy = false
    @State private var backupMessage: String = ""
    @State private var showBackupMessage = false

    @State private var showImportBackupPicker = false
    @State private var importMessage: String = ""
    @State private var showImportAlert = false
    /// A file chosen for restore (from the picker, or a pre-import snapshot), waiting for the user's confirmation.
    @State private var pendingRestore: PendingRestore? = nil

    struct PendingRestore: Identifiable {
        let id = UUID()
        let url: URL
        /// A temp copy of a picked file, deleted when the restore is cancelled or done. A snapshot is never deleted.
        let isTemporaryCopy: Bool
    }

    // MARK: - Meso generation feedback

    // MARK: - About
    @State private var didCopyBuildInfo = false
    @State private var showMuscleRanges = false
    

    /// The NavigationStack lives here: without one the Restore and Move data links are disabled (greyed, they do nothing).
    @ObservedObject private var route = AppRoute.shared
    @State private var showRestoreScreen = false

    var body: some View {
        NavigationStack { settingsForm }
    }

    /// The form plus the programmatic route to the Restore screen: "Restore from a backup" on the welcome sheet lands
    /// here, on the same screen as the row in Backup & Restore.
    private var settingsForm: some View {
        settingsFormBody
            .navigationDestination(isPresented: $showRestoreScreen) { restoreScreen }
            .onAppear { openRestoreIfRequested() }
            .onChange(of: route.restoreRequested) { _, _ in openRestoreIfRequested() }
    }

    private func openRestoreIfRequested() {
        guard route.restoreRequested else { return }
        route.restoreRequested = false
        showRestoreScreen = true
    }

    @ViewBuilder private var settingsFormBody: some View {
        Form {
            // MARK: - Profile
                        if let profile = profiles.first {
                            Section("Training") {
                                UnitSection(profile: profile)

                                HStack {
                                    Text("Default load step (all lifts unless overridden per exercise)")
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
                                Text("Set a lift's own step from its note sheet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

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
                                            // Borderless: in a Form row a plain Button takes taps for the whole row (a tap on the date cleared it).
                                            Button("Clear") { profile.birthDateOverride = nil }
                                                .buttonStyle(.borderless)
                                        } else {
                                            Button("Set") {
                                                profile.birthDateOverride = Calendar.current.date(byAdding: .year, value: -30, to: Date())
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                    Text("Only used for heart-rate zones, when Health doesn't have your date of birth.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
            


            // Goal, experience, equipment, session length and joints are not edited here: only the program builder reads
            // them, so they live in Program > Change program, which rebuilds the program from them.

            // MARK: - Effort tracking
            if let profile = profiles.first {
                Section {
                    Picker("Effort tracking", selection: Binding(
                        get: { EffortTracking.resolved(profile: profile, in: context) },
                        set: { EffortTracking.choose($0, in: context) }
                    )) {
                        ForEach(EffortMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text(EffortTracking.resolved(profile: profile, in: context).oneLine)
                }
            }

            // MARK: - Exercises
            Section("Exercises") {
                NavigationLink("Exercise library") { ExerciseLibraryView() }
            }

            // MARK: - Analytics
            if let profile = profiles.first {
                Section("Analytics") {
                    Button(profile.muscleSetRangesStored == nil ? "Weekly set ranges" : "Weekly set ranges (customized)") {
                        showMuscleRanges = true
                    }
                }
            }

            // MARK: - Backup & Restore
            Section("Backup & Restore") {
                Text(backupStatusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !backupsAreOffDevice {
                    Text("Backups are saved on this device only. " + (autoBackup.iCloudAvailability.explanation ?? "iCloud isn't available right now.") + (autoBackup.status.localOnly ? " (You chose local backups only.)" : ""))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let e = autoBackup.lastError {
                    Text("Last backup attempt failed: \(e)").font(.caption).foregroundStyle(.orange)
                }
                Button(backupBusy ? "Backing up…" : "Back up now") { Task { await backUpNow() } }
                    .disabled(backupBusy)
                Button("Verify latest backup") { verifyLatestBackup() }
                    .disabled(!rowAvailability.verifyEnabled)
                NavigationLink("Restore from a backup") { restoreScreen }
                    .foregroundStyle(.primary)
                NavigationLink("Move data (import and export)") { moveDataScreen }
                    .foregroundStyle(.primary)
            }
            .task(id: autoBackup.statusRevision) { await refreshBackups() }
            .task { await autoBackup.refreshICloudAvailability() }

            // MARK: - Help
            Section("Help") {
                NavigationLink("User Guide") { UserGuideView() }
                    .foregroundStyle(.primary)
                if let mail = UserGuide.supportMailURLForThisBuild {
                    Link("Contact support", destination: mail)
                        .foregroundStyle(.primary)
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
        .keyboardDismissal()   // the decimal pads (body weight, default load step) have no Return key
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
                // Copy the picked file out of its security scope now, so confirming later does not depend on it.
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("restore_\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: url, to: copy)
                pendingRestore = PendingRestore(url: copy, isTemporaryCopy: true)
            } catch {
                importMessage = "Backup import failed: \(error.localizedDescription)"
                showImportAlert = true
            }
        }
        .sheet(item: $pendingRestore, onDismiss: { }) { pending in
            RestoreConfirmSheet(
                url: pending.url,
                onConfirm: { runRestore(pending) },
                onCancel: { cancelPendingRestore() })
        }
        .alert("Backup", isPresented: $showBackupMessage) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupMessage)
        }
        .alert("Backup Import", isPresented: $showImportAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importMessage)
        }
        
    }

    // MARK: - Automatic backups

    private var backupStatusLine: String {
        guard let last = autoBackup.status.lastSuccess else { return "Last backup: none yet" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        let when = f.localizedString(for: last, relativeTo: Date())
        return "Last backup: \(when) · iCloud \(autoBackup.status.lastWasOffDevice ? "✓" : "✗")\(autoBackup.status.lastVerified ? " · verified" : "")"
    }

    /// Restore and Move data are never gated on this device's data or on a backup existing (a new phone has neither).
    private var rowAvailability: BackupRowAvailability {
        BackupRowAvailability.of(backupCount: backupFiles.count, storeHasData: !sessions.isEmpty || !profiles.isEmpty, busy: backupBusy)
    }

    private func refreshBackups() async {
        let result = await autoBackup.availableBackups()
        backupFiles = result.files
        backupsAreOffDevice = result.destination.isOffDevice
    }

    private func backUpNow() async {
        backupBusy = true
        defer { backupBusy = false }
        switch await autoBackup.backUpNow(container: context.container) {
        case .success: await refreshBackups()
        case .failure(let e): backupMessage = "Backup failed: \(e.localizedDescription)"; showBackupMessage = true
        }
    }

    /// Decodes the newest backup into a scratch in-memory store through the real importer and compares counts with this device.
    private func verifyLatestBackup() {
        guard let latest = backupFiles.first else { return }
        do {
            let report = try AutoBackupVerification.verify(file: latest.url, against: context)
            backupMessage = "\(latest.date.formatted(date: .abbreviated, time: .shortened))\n\(report.summary)"
        } catch {
            backupMessage = "Could not verify \(latest.url.lastPathComponent): \(error.localizedDescription)"
        }
        showBackupMessage = true
    }

    // MARK: - Restore

    private func cancelPendingRestore() {
        if let p = pendingRestore, p.isTemporaryCopy { try? FileManager.default.removeItem(at: p.url) }
        pendingRestore = nil
    }

    /// The one restore path for the picker AND "Restore pre-import state": `BackupRestoreCoordinator` snapshots first.
    private func runRestore(_ pending: PendingRestore) {
        pendingRestore = nil
        // Post notification first — tears down live SwiftData views before deletion
        RestoreActivity.inProgress = true      // the rebuilt root must not show the first-run welcome sheet over the restore
        NotificationCenter.default.post(name: .didRestoreBackup, object: nil)
        Task { @MainActor in
            defer {
                RestoreActivity.inProgress = false
                if pending.isTemporaryCopy { try? FileManager.default.removeItem(at: pending.url) }
            }
            try? await Task.sleep(for: .milliseconds(150))
            do {
                let restore = try BackupRestoreCoordinator.restore(from: pending.url, container: context.container)
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
    }

    // MARK: - Helpers

    /// The Profile section (including Body Weight) only renders when a UserProfile
    /// exists. Onboarding normally creates one, but accounts that skipped that path
    /// would otherwise see no Profile section and no way to create one.
    private func ensureProfileExists() {
        guard profiles.isEmpty else { return }
        let fresh = UserProfile()
        fresh.effortModeRaw = EffortMode.simple.rawValue   // a profile created here is new: Simple, stored
        context.insert(fresh)
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
    @State private var confirmResetAll = false

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
                Button("Reset all to defaults", role: .destructive) { confirmResetAll = true }
                    .disabled(profile.muscleSetRangesStored == nil)
                    .confirmationDialog("Reset all ranges?", isPresented: $confirmResetAll, titleVisibility: .visible) {
                        Button("Reset all to defaults", role: .destructive) { profile.muscleSetRanges = MuscleVolumeRanges.defaults }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Every weekly set range you changed goes back to the default.")
                    }
            }
        }
        .navigationTitle("Weekly set ranges")
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// Shown before any import: the incoming file next to what is on this device. A file that would move the store backwards
/// (fewer completed sessions, or an earlier last completed session) needs the word REPLACE typed to continue.
struct RestoreConfirmSheet: View {
    let url: URL
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var context
    @State private var incoming: BackupContentSummary?
    @State private var current: BackupContentSummary?
    @State private var loadError: String?
    @State private var typed = ""

    private func row(_ title: String, _ s: BackupContentSummary, showExported: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if showExported {
                Text("Exported: \(s.exportedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown")")
                if let identity = s.buildIdentity { Text(identity) }
                if let warning = s.newerFormatWarning { Text(warning).foregroundStyle(.red) }
            }
            Text("Completed sessions: \(s.completedSessions)")
            Text("Last completed session: \(s.lastCompletedDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "none")")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let loadError {
                    Section { Text("This file can't be read as a backup: \(loadError)").foregroundStyle(.red) }
                } else if let incoming, let current {
                    let verdict = ImportStalenessGuard.assess(incoming: incoming, current: current)
                    Section { row("Backup file", incoming, showExported: true) }
                    Section { row("On this device now", current, showExported: false) }
                    if case .requireTypedReplace(let reasons) = verdict {
                        Section {
                            ForEach(reasons, id: \.self) { Text($0).foregroundStyle(.red) }
                            Text("Type \(ImportStalenessGuard.confirmationWord) to replace your data anyway.")
                            TextField(ImportStalenessGuard.confirmationWord, text: $typed)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        } header: { Text("This file is older than your data") }
                    }
                    Section {
                        Button("Replace my data with this backup", role: .destructive, action: onConfirm)
                            .disabled(verdict.requiresTypedWord && !ImportStalenessGuard.accepts(typed: typed))
                    } footer: {
                        Text("A copy of your current data is saved first; Settings → Backup & Restore → Restore can undo this.")
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Restore backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
        }
        .interactiveDismissDisabled()
        .task {
            do {
                incoming = try BackupContentSummary.of(file: url)
                current = try BackupContentSummary.of(store: context)
            } catch { loadError = error.localizedDescription }
        }
    }
}
