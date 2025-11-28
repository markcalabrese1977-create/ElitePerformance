import SwiftUI
import SwiftData

/// Shows your current block grouped by week.
/// Change-program actions are owned by `HomeView`.
struct ProgramPlanView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    var body: some View {
        List {
            if sessions.isEmpty {
                emptyStateSection
            } else {
                ForEach(weekGroups) { weekGroup in
                    Section(
                        header: Text("Week \(weekGroup.weekIndex)")
                            .font(.headline)
                    ) {
                        ForEach(weekGroup.sessions) { session in
                            NavigationLink {
                                // Real session-driven view model
                                ProgramDayDetailView(session: session)
                            } label: {
                                programRow(for: session)
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addExtraSession()
                } label: {
                    Label("Add Session", systemImage: "plus")
                }
            }
        }
    }

    // MARK: - Extra Session

    /// Adds an extra planned session for "today" in the current week.
    private func addExtraSession() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Sort existing sessions so we can reason about the block.
        let sorted = sessions.sorted { $0.date < $1.date }

        // If there is already a session today, reuse its weekIndex.
        let todaysWeekIndex = sorted.first {
            calendar.isDate($0.date, inSameDayAs: today)
        }?.weekIndex

        // Otherwise, fall back to the last known weekIndex, or 1.
        let weekIndex = todaysWeekIndex ?? sorted.last?.weekIndex ?? 1

        let newSession = Session(
            date: today,
            status: .planned,
            readinessStars: 0,
            sessionNotes: nil,
            weekIndex: weekIndex,
            items: [],
            completedAt: nil
        )

        modelContext.insert(newSession)

        do {
            try modelContext.save()
            print("✅ Added extra session on \(today) (week \(weekIndex))")
        } catch {
            print("⚠️ Failed to save extra session: \(error)")
        }
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

    // MARK: - Grouping

    /// Sessions grouped by `weekIndex`, sorted by week then by date.
    private var weekGroups: [WeekGroup] {
        let grouped = Dictionary(grouping: sessions) { $0.weekIndex }

        return grouped.keys.sorted().map { week in
            let daySessions = (grouped[week] ?? [])
                .sorted { $0.date < $1.date }

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
    private func programRow(for session: Session) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                // Day name (Saturday, Sunday, etc.)
                Text(dayName(for: session.date))
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
