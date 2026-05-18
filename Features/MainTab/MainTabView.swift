import SwiftUI
import SwiftData

// MARK: - Main Tab View

struct MainTabView: View {
    var body: some View {
        TabView {
            TodayTabView()
                .tabItem { Label("Today", systemImage: "bolt.circle") }

            HomeView()
                .tabItem { Label("Program", systemImage: "list.bullet.rectangle") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            AnalyticsView()
                .tabItem { Label("Analytics", systemImage: "chart.bar") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

// MARK: - Today Tab

struct TodayTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    @State private var showRestDayConfirm = false

    private var activeBlockSessions: [Session] {
        sessions.filter { $0.meso?.status == .active }
    }

    private var visibleSessions: [Session] {
        if !activeBlockSessions.isEmpty {
            return activeBlockSessions
        }
        return sessions
    }

    private var upcomingSessions: [Session] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let tomorrowStart = cal.date(byAdding: .day, value: 1, to: todayStart)!

        return visibleSessions.filter { session in
            session.date >= tomorrowStart
        }
    }

    private var todaySession: Session? {
        let todayStart = Calendar.current.startOfDay(for: Date())
        let todayEnd = Calendar.current.date(byAdding: .day, value: 1, to: todayStart)!

        return visibleSessions.first(where: { session in
            session.date >= todayStart && session.date < todayEnd
        })
    }

    /// True when today has a planned (not started) session that can be pushed.
    private var canRestToday: Bool {
        guard let session = todaySession else { return false }
        return session.status == .planned
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    headerCard
                }

                if !upcomingSessions.isEmpty {
                    Section(header: Text("Upcoming")) {
                        ForEach(upcomingSessions) { session in
                            NavigationLink {
                                SessionView(
                                    viewModel: SessionScreenViewModel(session: session)
                                )
                            } label: {
                                SessionSummaryRow(session: session)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Today")
            .confirmationDialog(
                "Rest today?",
                isPresented: $showRestDayConfirm,
                titleVisibility: .visible
            ) {
                Button("Push this week's remaining sessions one day") {
                    pushRemainingSessionsOneDay()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Today becomes a rest day. All planned sessions remaining this week shift forward one day, and the rest day absorbs the change. Next week is unaffected.")
            }
        }
    }

    // MARK: - Header / Up Next Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Elite Performance")
                    .font(.headline)

                if let session = todaySession {
                    if let dayLabel = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !dayLabel.isEmpty {
                        Text(dayLabel)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    Text(session.weekDayLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No session planned for today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let session = todaySession {
                TodaySessionCard(session: session)
            } else {
                Text("Tap on a future session to start planning your week.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if canRestToday {
                Button {
                    showRestDayConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "bed.double")
                        Text("Rest today")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 4, y: 2)
        )
    }

    // MARK: - Rest Today Action

    /// Push all planned sessions in the current week forward one day.
    /// Bounded to the current week's weekIndex — next week is never affected.
    /// The rest day absorbs the shift.
    private func pushRemainingSessionsOneDay() {
        guard let todaySession = todaySession else { return }

        let currentWeekIndex = todaySession.weekIndex
        let todayStart = Calendar.current.startOfDay(for: Date())

        // Find all planned sessions in the same week from today forward
        let sessionsToShift = visibleSessions.filter {
            $0.status == .planned &&
            $0.weekIndex == currentWeekIndex &&
            Calendar.current.startOfDay(for: $0.date) >= todayStart
        }

        // Sort ascending and shift each by one day
        for session in sessionsToShift.sorted(by: { $0.date < $1.date }) {
            session.date = Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: session.date
            ) ?? session.date
        }

        try? context.save()
    }
}

// MARK: - Today Session Card

struct TodaySessionCard: View {
    let session: Session

    private var exercisesText: String {
        let count = session.items.count
        if count == 0 {
            return "No exercises yet"
        } else if count == 1 {
            return "1 exercise"
        } else {
            return "\(count) exercises"
        }
    }

    private enum Mode {
        case start
        case recap
    }

    private var mode: Mode {
        switch session.status {
        case .planned, .inProgress: return .start
        case .completed: return .recap
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's Session")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            if let dayLabel = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !dayLabel.isEmpty {
                Text(dayLabel)
                    .font(.headline)
            }

            Text(session.date, style: .date)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(exercisesText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                if mode == .start {
                    NavigationLink {
                        SessionView(
                            viewModel: SessionScreenViewModel(session: session)
                        )
                    } label: {
                        Text("Start Session")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    NavigationLink {
                        SessionView(
                            viewModel: SessionScreenViewModel(session: session)
                        )
                    } label: {
                        Text("View Session")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Session Summary Row (Upcoming list)

struct SessionSummaryRow: View {
    let session: Session

    private var exercisesText: String {
        let count = session.items.count
        if count == 0 {
            return "No exercises yet"
        } else if count == 1 {
            return "1 exercise"
        } else {
            return "\(count) exercises"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let dayLabel = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !dayLabel.isEmpty {
                    Text(dayLabel)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(exercisesText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(session.status.displayTitle)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.15))
                .foregroundColor(statusColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch session.status {
        case .planned:    return .secondary
        case .inProgress: return .blue
        case .completed:  return .green
        }
    }
}
