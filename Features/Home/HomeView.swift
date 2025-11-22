import SwiftUI
import SwiftData

/// Sessions tab = Program hub.
/// Shows the current block by default, with a toolbar button for session history.
struct HomeView: View {
    var body: some View {
        NavigationStack {
            ProgramPlanView()
                .navigationTitle("Program")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SessionsHistoryView()
                        } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
        }
    }
}

// MARK: - Session history (raw list of sessions)

struct SessionsHistoryView: View {
    @Query(sort: \Session.date, order: .reverse) private var sessions: [Session]

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        List {
            if sessions.isEmpty {
                Section {
                    Text("No sessions logged yet.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(sessions) { session in
                    NavigationLink {
                        // If the session is completed, recap it; otherwise, open the live view.
                        if session.status == .completed {
                            SessionRecapView(session: session)
                        } else {
                            SessionView(session: session)
                        }
                    } label: {
                        historyRow(for: session)
                    }
                }
            }
        }
        .navigationTitle("Session History")
    }

    @ViewBuilder
    private func historyRow(for session: Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.date, style: .date)
                .font(.headline)

            Text(session.status.displayTitle)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("\(session.items.count) exercise\(session.items.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
