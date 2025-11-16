import SwiftUI
import SwiftData

struct MainTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "bolt.circle")
                }

            HomeView()
                .tabItem {
                    Label("Sessions", systemImage: "list.bullet.rectangle")
                }
        }
    }
}

// MARK: - Today View

/// Shows today's session (if any) and quick access to start it.
import SwiftUI
import SwiftData

struct TodayView: View {
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    private var calendar: Calendar { Calendar.current }

    /// All sessions that fall on *today's* date.
    private var todaysSessions: [Session] {
        sessions.filter { calendar.isDateInToday($0.date) }
            .sorted { $0.date < $1.date }
    }

    /// If there's a non-completed session today, that's the "work to do".
    private var todaysIncompleteSession: Session? {
        todaysSessions.first(where: { $0.status != .completed })
    }

    /// If everything for today is done, show the (first) completed one.
    private var todaysCompletedSession: Session? {
        // If there is any non-completed today, we don't treat today as "done".
        guard todaysIncompleteSession == nil else { return nil }
        return todaysSessions.first(where: { $0.status == .completed })
    }

    /// Sessions strictly after today, **one per calendar day**.
    private var upcomingSessions: [Session] {
        guard !sessions.isEmpty else { return [] }

        let todayStart = calendar.startOfDay(for: Date())
        let sorted = sessions.sorted { $0.date < $1.date }

        var seenDays = Set<Date>()
        var result: [Session] = []

        for session in sorted {
            let day = calendar.startOfDay(for: session.date)
            // Only look at days after today
            guard day > todayStart else { continue }

            // Skip additional sessions on the same calendar day
            if !seenDays.contains(day) {
                seenDays.insert(day)
                result.append(session)
            }
        }

        return result
    }

    /// Convenience: the very next upcoming session (for preview when today is empty).
    private var nextUpcomingSession: Session? {
        upcomingSessions.first
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - TODAY SECTION

                Section(header: Text("Today")) {
                    if let session = todaysIncompleteSession {
                        // 1) There is still work to do today.
                        SessionSummaryCard(session: session)

                        NavigationLink {
                            SessionView(session: session)
                        } label: {
                            Text("Start Session")
                                .font(.headline)
                        }

                    } else if let session = todaysCompletedSession {
                        // 2) Today's work is done.
                        SessionSummaryCard(session: session)

                        NavigationLink {
                            SessionRecapView(session: session)
                        } label: {
                            Text("View Recap")
                                .font(.headline)
                        }

                        Text("Today's session is completed. Nice work.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                    } else {
                        // 3) No session scheduled for today.
                        Text("No training session scheduled for today.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if let next = nextUpcomingSession {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Next session")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                SessionSummaryRow(session: next)
                            }
                            .padding(.top, 4)
                        }
                    }
                }

                // MARK: - UPCOMING SECTION

                if !upcomingSessions.isEmpty {
                    Section(header: Text("Upcoming")) {
                        ForEach(upcomingSessions) { session in
                            NavigationLink {
                                SessionView(session: session)
                            } label: {
                                SessionSummaryRow(session: session)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Today")
        }
    }
}

// MARK: - Summary UI

struct SessionSummaryCard: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.date, style: .date)
                .font(.headline)

            Text(session.status.displayTitle)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("\(session.items.count) exercises")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct SessionSummaryRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.date, style: .date)
                .font(.subheadline)

            Text(session.status.displayTitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
