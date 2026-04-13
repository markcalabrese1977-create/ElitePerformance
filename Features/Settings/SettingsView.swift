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
    
    

    // MARK: - Mesocycle state (bind to the SAME key MesoLifecycle uses)
    @AppStorage("meso.scheduledStartDateEpoch") private var scheduledStartEpoch: Double = 0

    @State private var nextMesoDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()

    private var scheduledStartDate: Date? {
        scheduledStartEpoch > 0 ? Date(timeIntervalSince1970: scheduledStartEpoch) : nil
    }

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

            // MARK: - Mesocycle (single section)
            Section("Mesocycle") {

                // Future date picker (for scheduling)
                DatePicker("Next meso start", selection: $nextMesoDate, displayedComponents: [.date])

                Button("Schedule Next Mesocycle") {
                    let d0 = Calendar.current.startOfDay(for: nextMesoDate)
                    MesoLifecycle.scheduleNextMeso(on: d0)

                    // Mirror so the UI updates immediately (AppStorage is reactive)
                    scheduledStartEpoch = d0.timeIntervalSince1970
                }

                if let scheduled = scheduledStartDate {
                    Text("Scheduled for \(scheduled.formatted(date: .long, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        MesoLifecycle.clearScheduledNextMeso()
                        scheduledStartEpoch = 0
                    } label: {
                        Text("Cancel Scheduled Start")
                    }
                } else {
                    Text("Not scheduled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Full rollover (label reset + activeStartDate metrics cutoff + clear schedule)
                Button(role: .destructive) {
                    MesoLifecycle.confirmStartNewMeso(on: Date())
                    scheduledStartEpoch = 0
                } label: {
                    Text("Start New Mesocycle Now (Reset to W1D1)")
                }

                Text("Uses a confirmation guard on the start date so you can delay if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // Optional: label-only reset (keep if you want)
                Button(role: .destructive) {
                    MesoLabel.startNewMeso(on: Date())
                } label: {
                    Text("Reset Labels Only (W1D1 from Today)")
                }

                Text("Resets week/day labels only. Does not modify history or active meso metrics cutoff.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            
            
            // MARK: - Export
            Section("Export") {
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
        .onAppear {
            // If a schedule exists, reflect it in the DatePicker.
            if let scheduled = MesoLifecycle.scheduledStartDate {
                nextMesoDate = scheduled
                scheduledStartEpoch = Calendar.current.startOfDay(for: scheduled).timeIntervalSince1970
            }
        }
    }
}

// MARK: - Sheet item wrapper

private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
