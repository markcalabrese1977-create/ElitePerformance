import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var users: [User]

    @AppStorage(AppStorageKeys.appMode) private var appModeRaw: String = AppMode.mark.rawValue
    private var mode: AppMode { AppMode(rawValue: appModeRaw) ?? .mark }

    // MARK: - Export state
    @State private var exportItem: ExportShareItem? = nil
    @State private var exportError: String? = nil

    var body: some View {
        let user = users.first

        Form {
            Section("App Mode") {
                Picker("Mode", selection: $appModeRaw) {
                    ForEach(AppMode.allCases) { m in
                        Text(m.title).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("Switching modes does not change saved workout data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Coach Voice") {
                Picker(
                    "Style",
                    selection: Binding(
                        get: { user?.coachVoice ?? .casual },
                        set: { v in user?.coachVoice = v }
                    )
                ) {
                    Text("Casual").tag(User.CoachVoice.casual)
                    Text("Strict").tag(User.CoachVoice.strict)
                }
                .pickerStyle(.segmented)
            }

            Section("Progression") {
                Toggle(
                    "Auto-progression",
                    isOn: Binding(
                        get: { user?.progressionEnabled ?? true },
                        set: { v in user?.progressionEnabled = v }
                    )
                )
            }

            // ✅ Export
            Section("Export") {
                Button("Export Completed Sessions (CSV)") {
                    exportError = nil
                    do {
                        let result = try SetsV1CSVExporter.exportCompletedSessionsCSV(modelContext: context)

                        // Guard: rows exist
                        guard result.rowCount > 0 else {
                            exportItem = nil
                            exportError = "No completed sessions found to export."
                            return
                        }

                        // Guard: file exists
                        guard FileManager.default.fileExists(atPath: result.url.path) else {
                            exportItem = nil
                            exportError = "Export file was not created at:\n\(result.url.path)"
                            return
                        }

                        // Drive sheet from this (no Bool race)
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
                    Text("Exports completed sessions only. One row per set (sets_v1).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $exportItem) { item in
            ShareSheet(items: [item.url])
        }
    }
}

// MARK: - Sheet item wrapper

private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
