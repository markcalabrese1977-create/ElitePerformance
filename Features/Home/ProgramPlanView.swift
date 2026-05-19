import SwiftUI
import SwiftData

/// Shows the active future block when available, otherwise falls back to legacy future sessions.
/// Change-program actions are owned by `HomeView`.
struct ProgramPlanView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.date, order: .forward)
    private var sessions: [Session]
    

    // Swipe delete (surgical)
    @State private var sessionPendingDelete: Session?
    @State private var showDeleteConfirm = false

    // Add session (date-targeted)
    @State private var showAddSessionSheet = false
    @State private var newSessionDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var newSessionDayLabel: String = ""
    @State private var addSessionErrorMessage: String?
    @State private var showAddSessionError = false


    // MARK: - Body

    private var activeBlockFutureSessions: [Session] {
        let today0 = Calendar.current.startOfDay(for: Date())

        return sessions.filter { session in
            session.status != .completed &&
            session.date >= today0 &&
            session.meso?.status == .active
        }
    }

    private var legacyFutureSessions: [Session] {
        let today0 = Calendar.current.startOfDay(for: Date())

        return sessions.filter { session in
            session.status != .completed &&
            session.date >= today0
        }
    }

    private var visibleSessions: [Session] {
        if !activeBlockFutureSessions.isEmpty {
            return activeBlockFutureSessions
        }
        return legacyFutureSessions
    }
    
    

    private var activeBlockName: String? {
        activeMesoBlock?.name
    }

    private var activeBlockStartDate: Date? {
        activeMesoBlock?.startDate
    }

    private var activeBlockSessionCount: Int {
        visibleSessions.count
    }
    
    var body: some View {
        content
    }

    private var activeBlockHeaderSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(activeBlockName ?? "Program")
                    .font(.headline)

                if let startDate = activeBlockStartDate {
                    Text("Active since \(startDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("\(activeBlockSessionCount) upcoming session\(activeBlockSessionCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
    
    private var content: some View {
        List {
            if activeBlockName != nil {
                activeBlockHeaderSection
            }

            if visibleSessions.isEmpty {
                emptyStateSection
            } else {
                ForEach(weekGroups) { weekGroup in
                    Section(
                        header: VStack(alignment: .leading, spacing: 2) {
                            Text("Week \(weekGroup.weekIndex)")
                                .font(.headline)


                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    ) {
                        ForEach(Array(weekGroup.sessions.enumerated()), id: \.element.id) { index, session in
                            NavigationLink {
                                ProgramDayDetailView(session: session)
                            } label: {
                                programRow(
                                                                    for: session,
                                                                    computedWeek: weekGroup.weekIndex,
                                                                    computedDay: session.dayNumberInWeek
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if session.status == .planned && session.items.isEmpty {
                                    Button(role: .destructive) {
                                        sessionPendingDelete = session
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newSessionDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    newSessionDayLabel = ""
                    showAddSessionSheet = true
                } label: {
                    Label("Add Session", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSessionSheet) {
            // keep your existing sheet content
            addSessionSheet
        }
        .alert("Couldn’t add session", isPresented: $showAddSessionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(addSessionErrorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            "Delete this planned session?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deletePendingSession()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Group {
                if let s = sessionPendingDelete {
                    Text("\(s.date.formatted(date: .abbreviated, time: .omitted)) • \(s.items.count) exercise\(s.items.count == 1 ? "" : "s")")
                } else {
                    Text("")
                }
            }
        }
    }

    
    private var addSessionSheet: some View {
        NavigationStack {
            Form {
                Section("Create session for date") {
                    DatePicker(
                        "Date",
                        selection: $newSessionDate,
                        displayedComponents: [.date]
                    )

                    TextField("Day label (optional)", text: $newSessionDayLabel)
                        .textInputAutocapitalization(.words)
                }

                Section("Quick pick") {
                    Button("Tomorrow") {
                        newSessionDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    }
                    Button("Thursday (next occurrence)") {
                        newSessionDate = nextWeekday(.thursday)
                    }
                }

                Section {
                    Button("Create") {
                        addSession(for: newSessionDate, dayLabel: newSessionDayLabel)
                    }
                }

                Section("Advanced") {
                    Button("Append extra session to end of meso") {
                        addExtraSession()
                        showAddSessionSheet = false
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddSessionSheet = false }
                }
            }
        }
    }

    // MARK: - Week math

    // MARK: - Week math (MesoLabel)

    private func weekIndex(for date: Date) -> Int {
        if let exact = visibleSessions.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) {
            return exact.weekIndex
        }
        return 1
    }

    /// 1–6 training day within a training week (Thu rest is skipped by lift-day counting)
    private func dayIndexInWeek(for date: Date) -> Int {
        let day = Calendar.current.startOfDay(for: date)

        let sameWeekSessions = visibleSessions
            .filter {
                $0.weekIndex == weekIndex(for: day) &&
                $0.status != .completed
            }
            .sorted { $0.date < $1.date }

        if let idx = sameWeekSessions.firstIndex(where: {
            Calendar.current.isDate($0.date, inSameDayAs: day)
        }) {
            return idx + 1
        }

        return 1
    }

    // MARK: - Optional: realign stored weekIndex so other screens match

    

    // MARK: - Add Session (date-targeted)

    private func addSession(for date: Date, dayLabel: String?) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)

        // Block duplicates with an explicit alert (no silent failure).
        let alreadyExists = sessions.contains { calendar.isDate($0.date, inSameDayAs: day) }
        if alreadyExists {
            addSessionErrorMessage = "A session already exists on \(day.formatted(date: .abbreviated, time: .omitted))."
            showAddSessionError = true
            return
        }

        let computedWeek = insertionWeekIndex(for: day)

        let trimmedDayLabel = dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDayLabel = (trimmedDayLabel?.isEmpty == false) ? trimmedDayLabel : nil

        let newSession = Session(
            date: day,
            status: .planned,
            readinessStars: 0,
            sessionNotes: nil,
            weekIndex: computedWeek,
            dayLabel: normalizedDayLabel,
            items: [],
            completedAt: nil
        )

        newSession.meso = activeMesoBlock

        modelContext.insert(newSession)

        do {
            try modelContext.save()
            Haptics.success()
            print("✅ Added session on \(day) (week \(computedWeek))")
            showAddSessionSheet = false
        } catch {
            addSessionErrorMessage = "Save failed: \(error)"
            showAddSessionError = true
            print("⚠️ Failed to save session: \(error)")
        }
    }

    private enum Weekday {
        case thursday

        /// Calendar weekday: 1=Sunday ... 7=Saturday
        var calendarValue: Int {
            switch self {
            case .thursday: return 5
            }
        }
    }

    private func nextWeekday(_ weekday: Weekday) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let target = weekday.calendarValue
        let current = cal.component(.weekday, from: today)

        var delta = target - current
        if delta <= 0 { delta += 7 } // next occurrence (not today)

        return cal.date(byAdding: .day, value: delta, to: today) ?? today
    }

    // MARK: - Legacy: Extra Session (append-to-end)

    /// Adds an extra planned session AFTER the last scheduled session date (not "today").
    /// This prevents accidental spam duplicates on the same day.
    private func addExtraSession() {
        let calendar = Calendar.current

        // Start from the last scheduled day (or today if none)
        let lastDate = sessions.map(\.date).max() ?? Date()
        var candidate = calendar.startOfDay(for: lastDate)

        // Move forward until we find a day with no existing session
        // (so one tap = one new day)
        for _ in 0..<30 {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            let alreadyExists = sessions.contains { calendar.isDate($0.date, inSameDayAs: candidate) }
            if !alreadyExists { break }
        }

        let computedWeek = insertionWeekIndex(for: candidate)

        let newSession = Session(
            date: candidate,
            status: .planned,
            readinessStars: 0,
            sessionNotes: nil,
            weekIndex: computedWeek,
            dayLabel: "Extra Session",
            items: [],
            completedAt: nil
        )

        newSession.meso = activeMesoBlock

        modelContext.insert(newSession)

        do {
            try modelContext.save()
            Haptics.success()
            print("✅ Added extra session on \(candidate) (week \(computedWeek))")
        } catch {
            print("⚠️ Failed to save extra session: \(error)")
        }
    }
    
    
    // MARK: - Delete handler

    private func deletePendingSession() {
        guard let s = sessionPendingDelete else { return }

        modelContext.delete(s)

        do {
            try modelContext.save()
            Haptics.success()
        } catch {
            print("⚠️ Delete failed: \(error)")
        }

        sessionPendingDelete = nil
    }

    // MARK: - Empty State

    private var emptyStateSection: some View {
        Section {
            Text("No program scheduled yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Use “Change Program” to create your first training block.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Grouping (computed)

    private var weekGroups: [WeekGroup] {
        let grouped = Dictionary(grouping: visibleSessions) { $0.weekIndex }

        return grouped.keys.sorted().map { week in
            let daySessions = (grouped[week] ?? [])
                .sorted { lhs, rhs in
                    if let l = lhs.programIndex, let r = rhs.programIndex {
                        return l < r
                    }
                    return lhs.date < rhs.date
                }


            return WeekGroup(
                weekIndex: week,

                sessions: daySessions
            )
        }
    }

    private struct WeekGroup: Identifiable {
        let weekIndex: Int
        let sessions: [Session]

        var id: Int { weekIndex }

        
    }

    // MARK: - Row view

    @ViewBuilder
    private func programRow(for session: Session, computedWeek: Int, computedDay: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let dayLabel = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !dayLabel.isEmpty {
                    Text(dayLabel)
                        .font(.headline)
                } else {
                    Text("W\(computedWeek)D\(computedDay) · \(dayName(for: session.date))")
                        .font(.headline)
                }

                Text("W\(computedWeek)D\(computedDay) · \(dayName(for: session.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(session.items.count) exercise\(session.items.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(session.status.displayTitle)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor(for: session.status).opacity(0.15))
                .foregroundColor(statusColor(for: session.status))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func insertionWeekIndex(for date: Date) -> Int {
        let day = Calendar.current.startOfDay(for: date)

        if let exact = visibleSessions.first(where: {
            Calendar.current.isDate($0.date, inSameDayAs: day)
        }) {
            return exact.weekIndex
        }

        let sorted = visibleSessions.sorted { $0.date < $1.date }

        if let previous = sorted.last(where: { $0.date < day }) {
            return previous.weekIndex
        }

        if let next = sorted.first(where: { $0.date > day }) {
            return next.weekIndex
        }

        return 1
    }
    
    private var activeMesoBlock: MesoBlock? {
        sessions.first(where: { $0.meso?.status == .active })?.meso
    }
    
    private func dayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func statusColor(for status: SessionStatus) -> Color {
        switch status {
        case .planned:     return .secondary
        case .inProgress:  return .blue
        case .completed:   return .green
        }
    }
}
