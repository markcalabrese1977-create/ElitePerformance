import SwiftUI

struct MesoRolloverGuardSheet: View {
    @Binding var isPresented: Bool
    @Binding var rescheduleDate: Date

    var body: some View {
        NavigationStack {
            Form {
                Section("Next mesocycle is due") {
                    if let scheduled = MesoLifecycle.scheduledStartDate {
                        Text("Scheduled start: \(scheduled.formatted(date: .long, time: .omitted))")
                            .font(.subheadline)
                    } else {
                        Text("Scheduled start: (missing)")
                            .font(.subheadline)
                    }

                    Text("Start now to reset W/D labeling and begin new block metrics. If life happened, delay or choose a new start date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        MesoLifecycle.confirmStartNewMeso(on: Date())
                        isPresented = false
                        Haptics.success()
                    } label: {
                        Text("Start Today (W1D1)")
                    }
                }

                Section("Delay") {
                    Button {
                        MesoLifecycle.delayScheduledStart(byDays: 1)
                        isPresented = false
                    } label: {
                        Text("Delay 1 day")
                    }

                    Button {
                        MesoLifecycle.delayScheduledStart(byDays: 7)
                        isPresented = false
                    } label: {
                        Text("Delay 1 week")
                    }
                }

                Section("Choose a new start date") {
                    DatePicker("New start date", selection: $rescheduleDate, displayedComponents: [.date])

                    Button {
                        MesoLifecycle.scheduleNextMeso(on: rescheduleDate)
                        isPresented = false
                    } label: {
                        Text("Reschedule")
                    }
                }

                Section {
                    Button {
                        MesoLifecycle.snoozePromptUntilTomorrow()
                        isPresented = false
                    } label: {
                        Text("Not now (remind me tomorrow)")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Start New Mesocycle?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        // keep it due; will prompt again next time unless snoozed
                        isPresented = false
                    }
                }
            }
        }
    }
}
