import SwiftUI
import SwiftData

/// Shows your current block grouped by week.
/// Change-program actions are owned by `HomeView`.
struct ProgramPlanView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    // MARK: - Meso Anchor (UI + Week math)

    /// If you already store an anchor elsewhere, you can wire these keys to match.
    /// For now: if missing, we default to "today is W2D2".
    @AppStorage("meso_anchor_week") private var anchorWeek: Int = 0
    @AppStorage("meso_anchor_day")  private var anchorDay: Int = 0
    @AppStorage("meso_anchor_date") private var anchorDateEpoch: Double = 0

    @State private var didAttemptRealign = false

    // Swipe delete (surgical)
    @State private var sessionPendingDelete: Session?
    @State private var showDeleteConfirm = false

    // Add session (date-targeted)
    @State private var showAddSessionSheet = false
    @State private var newSessionDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var addSessionErrorMessage: String?
    @State private var showAddSessionError = false

    private var anchorDate: Date {
        if anchorDateEpoch > 0 {
            return Date(timeIntervalSince1970: anchorDateEpoch)
        }
        return Date()
    }

    /// Week 1 / Day 1 date computed from the anchor.
    /// Example: if today is W2D2, this returns 8 days ago.
    private var week1Day1: Date {
        let deltaDays = ((effectiveAnchorWeek - 1) * 7) + (effectiveAnchorDay - 1)
        let start = Calendar.current.startOfDay(for: anchorDate)
        return Calendar.current.date(byAdding: .day, value: -deltaDays, to: start) ?? start
    }

    private var effectiveAnchorWeek: Int { max(1, anchorWeek) }
    private var effectiveAnchorDay: Int  { max(1, anchorDay) }

    // MARK: - Body

    var body: some View {
        List {
            if sessions.isEmpty {
                emptyStateSection
            } else {
                ForEach(weekGroups) { weekGroup in
                    Section(
                        header: VStack(alignment: .leading, spacing: 2) {
                            Text("Week \(weekGroup.weekIndex)")
                                .font(.headline)

                            Text(weekGroup.rangeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    ) {
                        ForEach(weekGroup.sessions) { session in
                            NavigationLink {
                                ProgramDayDetailView(session: session)
                            } label: {
                                programRow(
                                    for: session,
                                    computedWeek: weekIndex(for: session.date),
                                    computedDay: dayIndexInWeek(for: session.date)
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // SAFETY: only allow deleting "junk" planned sessions (planned + empty).
                                // This is the surgical tool for cleaning duplicates without risking real history.
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
                    // default to tomorrow on open
                    newSessionDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    showAddSessionSheet = true
                } label: {
                    Label("Add Session", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSessionSheet) {
            NavigationStack {
                Form {
                    Section("Create session for date") {
                        DatePicker(
                            "Date",
                            selection: $newSessionDate,
                            displayedComponents: [.date]
                        )
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
                            addSession(for: newSessionDate)
                        }
                    }

                    // Optional: keep legacy behavior accessible for debugging / power use.
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
        .onAppear {
            ensureAnchorDefaultsIfMissing()
        }
        .onChange(of: sessions.count) { _ in
            // When sessions arrive/refresh, we can realign once.
            if !didAttemptRealign {
                didAttemptRealign = true
                realignStoredWeekIndexesIfNeeded()
            }
        }
    }

    // MARK: - Anchor defaults

    private func ensureAnchorDefaultsIfMissing() {
        // If nothing set yet, assume "today is W2D2"
        if anchorWeek == 0 { anchorWeek = 2 }
        if anchorDay == 0 { anchorDay = 2 }
        if anchorDateEpoch == 0 {
            anchorDateEpoch = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        }
    }

    // MARK: - Week math

    private func weekIndex(for date: Date) -> Int {
        let start = week1Day1
        let d0 = Calendar.current.startOfDay(for: date)
        let days = Calendar.current.dateComponents([.day], from: start, to: d0).day ?? 0
        // days 0...6 => week 1, 7...13 => week 2, etc.
        return max(1, (days / 7) + 1)
    }

    /// 1–7 within a week (Day 1 = week start)
    private func dayIndexInWeek(for date: Date) -> Int {
        let start = week1Day1
        let d0 = Calendar.current.startOfDay(for: date)
        let days = Calendar.current.dateComponents([.day], from: start, to: d0).day ?? 0
        let mod = ((days % 7) + 7) % 7 // safe mod for past dates
        return mod + 1
    }

    // MARK: - Optional: realign stored weekIndex so other screens match

    private func realignStoredWeekIndexesIfNeeded() {
        guard !sessions.isEmpty else { return }

        // If ANY session's stored weekIndex disagrees with computed weekIndex, we realign all.
        let needsRealign = sessions.contains { s in
            s.weekIndex != weekIndex(for: s.date)
        }

        guard needsRealign else { return }

        for s in sessions {
            s.weekIndex = weekIndex(for: s.date)
        }

        do {
            try modelContext.save()
            print("✅ Realigned stored Session.weekIndex using meso anchor (W\(effectiveAnchorWeek)D\(effectiveAnchorDay)).")
        } catch {
            print("⚠️ Failed to realign weekIndex: \(error)")
        }
    }

    // MARK: - Add Session (date-targeted)

    private func addSession(for date: Date) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)

        // Block duplicates with an explicit alert (no silent failure).
        let alreadyExists = sessions.contains { calendar.isDate($0.date, inSameDayAs: day) }
        if alreadyExists {
            addSessionErrorMessage = "A session already exists on \(day.formatted(date: .abbreviated, time: .omitted))."
            showAddSessionError = true
            return
        }

        let computedWeek = weekIndex(for: day)

        let newSession = Session(
            date: day,
            status: .planned,
            readinessStars: 0,
            sessionNotes: nil,
            weekIndex: computedWeek,
            items: [],
            completedAt: nil
        )

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

        let computedWeek = weekIndex(for: candidate)

        let newSession = Session(
            date: candidate,
            status: .planned,
            readinessStars: 0,
            sessionNotes: nil,
            weekIndex: computedWeek,
            items: [],
            completedAt: nil
        )

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
        let grouped = Dictionary(grouping: sessions) { weekIndex(for: $0.date) }

        return grouped.keys.sorted().map { week in
            let daySessions = (grouped[week] ?? [])
                .sorted { $0.date < $1.date }

            let start = Calendar.current.date(byAdding: .day, value: (week - 1) * 7, to: week1Day1) ?? week1Day1
            let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start

            return WeekGroup(
                weekIndex: week,
                startDate: start,
                endDate: end,
                sessions: daySessions
            )
        }
    }

    private struct WeekGroup: Identifiable {
        let weekIndex: Int
        let startDate: Date
        let endDate: Date
        let sessions: [Session]

        var id: Int { weekIndex }

        var rangeText: String {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return "\(df.string(from: startDate)) – \(df.string(from: endDate))"
        }
    }

    // MARK: - Row view

    @ViewBuilder
    private func programRow(for session: Session, computedWeek: Int, computedDay: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("W\(computedWeek)D\(computedDay) · \(dayName(for: session.date))")
                    .font(.headline)

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
