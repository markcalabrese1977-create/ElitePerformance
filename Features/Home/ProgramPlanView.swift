import SwiftUI
import SwiftData

/// Shows your current block grouped by week.
/// Change-program actions are owned by `HomeView`.
struct ProgramPlanView: View {
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    var body: some View {
        List {
            // TEMP: debug display
            Text("DEBUG sessions count: \(sessions.count)")
                .font(.caption)
                .foregroundColor(.secondary)
            if sessions.isEmpty {
                Section {
                    Text("No program scheduled yet.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("Use “Change Program” to create your first training block.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(groupedByWeek, id: \.week) { group in
                    Section(header: Text("Week \(group.week)")
                        .font(.headline)) {

                        ForEach(group.sessions) { session in
                            NavigationLink {
                                SessionView(session: session)
                            } label: {
                                programRow(for: session)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Grouping

    /// Sessions grouped by `weekIndex`, sorted by week then by date.
    private var groupedByWeek: [(week: Int, sessions: [Session])] {
        let grouped = Dictionary(grouping: sessions) { $0.weekIndex }
        return grouped.keys.sorted().map { week in
            let daySessions = (grouped[week] ?? [])
                .sorted { $0.date < $1.date }
            return (week, daySessions)
        }
    }

    // MARK: - Row view

    @ViewBuilder
    private func programRow(for session: Session) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                // Day name (Saturday, Sunday, etc.)
                Text(dayName(for: session.date))
                    .font(.headline)

                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("\(session.items.count) exercise\(session.items.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
