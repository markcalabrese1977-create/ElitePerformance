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
struct TodayView: View {
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    private var todaySession: Session? {
        let calendar = Calendar.current
        return sessions.first(where: { calendar.isDateInToday($0.date) })
    }

    private var upcomingSessions: [Session] {
        let calendar = Calendar.current
        return sessions.filter { $0.date > Date() && !calendar.isDateInToday($0.date) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let session = todaySession {
                    Section(header: Text("Today")) {
                        SessionSummaryCard(session: session)

                        NavigationLink {
                            SessionView(session: session)
                        } label: {
                            Text("Start Session")
                                .font(.headline)
                        }
                    }
                } else {
                    Section(header: Text("Today")) {
                        Text("No training session scheduled for today.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

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
