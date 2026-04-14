import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var users: [User]
    @Query private var appStates: [AppState]
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    // MARK: - Export state
    @State private var exportItem: ExportShareItem? = nil
    @State private var exportError: String? = nil

    // MARK: - Meso generation feedback
    @State private var mesoGenerationMessage: String = ""
    @State private var showMesoGenerationAlert = false

    @State private var nextMesoDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()

    private var appState: AppState? {
        appStates.first
    }

    private var appModeBinding: Binding<String> {
        Binding(
            get: {
                appState?.appModeRaw
                    ?? UserDefaults.standard.string(forKey: AppStorageKeys.appMode)
                    ?? AppMode.mark.rawValue
            },
            set: { newValue in
                AppStateBridge.setAppMode(newValue, in: context)
            }
        )
    }

    private var scheduledStartDate: Date? {
        appState?.scheduledNextMesoStartDate ?? MesoLifecycle.scheduledStartDate
    }

    var body: some View {
        let user = users.first

        Form {
            Section("App Mode") {
                Picker("Mode", selection: appModeBinding) {
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
                    AppStateBridge.setScheduledNextMesoStartDate(d0, in: context)
                }

                Button("Generate Next Mesocycle Block") {
                    presentMesoGenerationMessage(
                        "Not available yet. Future meso generation is temporarily disabled until multi-mesocycle session grouping is fully supported."
                    )
                }
                .disabled(true)

                Text("Temporarily disabled until multi-mesocycle support is complete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let scheduled = scheduledStartDate {
                    Text("Scheduled for \(scheduled.formatted(date: .long, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        MesoLifecycle.clearScheduledNextMeso()
                        AppStateBridge.setScheduledNextMesoStartDate(nil, in: context)
                        AppStateBridge.setMesoPromptSnoozeUntil(nil, in: context)
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
                    let today = Calendar.current.startOfDay(for: Date())
                    MesoLifecycle.confirmStartNewMeso(on: today)
                    AppStateBridge.setActiveMesoStartDate(today, in: context)
                    AppStateBridge.setScheduledNextMesoStartDate(nil, in: context)
                    AppStateBridge.setMesoPromptSnoozeUntil(nil, in: context)
                    AppStateBridge.setMesoAnchor(date: today, dayNumber: 1, in: context)
                } label: {
                    Text("Start New Mesocycle Now (Reset to W1D1)")
                }

                Text("Uses a confirmation guard on the start date so you can delay if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // Optional: label-only reset (keep if you want)
                Button(role: .destructive) {
                    let today = Calendar.current.startOfDay(for: Date())
                    MesoLabel.startNewMeso(on: today)
                    AppStateBridge.setMesoAnchor(date: today, dayNumber: 1, in: context)
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
        .alert("Mesocycle", isPresented: $showMesoGenerationAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(mesoGenerationMessage)
        }
        .onAppear {
            if let scheduled = scheduledStartDate {
                nextMesoDate = Calendar.current.startOfDay(for: scheduled)
            }
        }
    }
    // MARK: - Safe next-meso generation

    private func presentMesoGenerationMessage(_ message: String) {
        mesoGenerationMessage = message
        showMesoGenerationAlert = true
    }

    private func inferredTrainingWeekdays() -> [Int] {
        let cal = Calendar.current

        // Prefer future/planned-ish sessions first, because they reflect the active template.
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

    private func generateNextMesocycleBlock() {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: nextMesoDate)

        // Safety 1: do not generate over existing sessions
        guard !hasSessionsOnOrAfter(startDay) else {
            presentMesoGenerationMessage(
                "Sessions already exist on or after \(startDay.formatted(date: .long, time: .omitted)). Choose a later start date or clear the overlap first."
            )
            return
        }

        // Safety 2: infer weekdays from current schedule
        let weekdays = inferredTrainingWeekdays()

        guard weekdays.count == DUP10WeekTemplate.template.trainingDaysPerWeek else {
            presentMesoGenerationMessage(
                "Could not infer a valid \(DUP10WeekTemplate.template.trainingDaysPerWeek)-day training schedule from existing sessions."
            )
            return
        }

        do {
            try DUPProgramSeeder.seed(
                startDate: startDay,
                trainingWeekdays: weekdays,
                context: context,
                template: DUP10WeekTemplate.template,
                calendar: cal
            )

            presentMesoGenerationMessage(
                "Generated a new 10-week DUP block starting \(startDay.formatted(date: .long, time: .omitted))."
            )
        } catch {
            presentMesoGenerationMessage(
                "Couldn’t generate the next mesocycle: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Sheet item wrapper

private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
