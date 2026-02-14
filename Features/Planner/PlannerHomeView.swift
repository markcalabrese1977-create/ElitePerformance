import SwiftUI
import SwiftData



struct PlannerHomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]
    @State private var openSessionId: PersistentIdentifier?
    @State private var showingNewSession = false

    private var todaySessions: [Session] {
        sessions.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var recentSessions: [Session] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -14, to: todayStart) ?? todayStart

        return sessions
            .filter { s in
                s.date >= from &&
                s.date < todayStart &&
                (s.status == .planned || s.status == .inProgress || s.status == .completed)
            }
            .sorted { $0.date > $1.date }   // newest first
    }
    
    private var upcomingSessions: [Session] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart

        return sessions.filter { s in
            s.date >= tomorrowStart &&
            (s.status == .planned || s.status == .inProgress)
        }
    }

    var body: some View {
        NavigationStack {
            NavigationLink(
                destination: Group {
                    if let id = openSessionId,
                       let session = sessions.first(where: { $0.persistentModelID == id }) {
                        PlannedSessionEditorView(session: session)
                    } else {
                        EmptyView()
                    }
                },
                isActive: Binding(
                    get: { openSessionId != nil },
                    set: { if !$0 { openSessionId = nil } }
                )
            ) {
                EmptyView()
            }
            .hidden()
            
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Workouts")
                            .font(.headline)

                        Button {
                            showingNewSession = true
                        } label: {
                            Label("Plan Workout", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Text("Plan workouts with simple steps. Add exercises. Start when ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if !todaySessions.isEmpty {
                    Section("Today") {
                        ForEach(todaySessions) { s in
                            NavigationLink {
                                PlannedSessionEditorView(session: s)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(s.date.formatted(date: .abbreviated, time: .omitted))
                                    Text(s.status.displayTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !recentSessions.isEmpty {
                    Section("Recent") {
                        ForEach(recentSessions) { s in
                            NavigationLink {
                                PlannedSessionEditorView(session: s)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(s.date.formatted(date: .abbreviated, time: .omitted))
                                    Text(s.status.displayTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                
                if !upcomingSessions.isEmpty {
                    Section("Upcoming") {
                        ForEach(upcomingSessions) { s in
                            NavigationLink {
                                PlannedSessionEditorView(session: s)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(s.date.formatted(date: .abbreviated, time: .omitted))
                                    Text(s.status.displayTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Planner")
            .sheet(isPresented: $showingNewSession) {
                NewPlannedSessionSheet { date in
                    let day = Calendar.current.startOfDay(for: date)

                    // If a session already exists for that day, open it.
                    if let existing = sessions.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
                        showingNewSession = false
                        openSessionId = existing.persistentModelID
                        return
                    }

                    // Otherwise create + open the new one.
                    let s = Session(date: day, status: .planned, weekIndex: 0)
                    context.insert(s)
                    try? context.save()

                    showingNewSession = false
                    openSessionId = s.persistentModelID
                } onCancel: {
                    showingNewSession = false
                }
            }
        }
    }
}
struct NewPlannedSessionSheet: View {
    let onCreate: (Date) -> Void
    let onCancel: () -> Void

    @State private var selectedDate = Calendar.current.startOfDay(for: Date())

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Workout date",
                    selection: $selectedDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
            }
            .navigationTitle("Plan Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let day = Calendar.current.startOfDay(for: selectedDate)
                        onCreate(day)
                    }
                }
            }
        }
    }
}
