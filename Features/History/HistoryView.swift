import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \SessionHistory.date, order: .reverse) private var items: [SessionHistory]
    @State private var refreshID = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(groupedByDay) { day in
                            Section {
                                ForEach(day.sessions) { history in
                                    HistoryRow(history: history)
                                }
                            } header: {
                                Text(day.date, style: .date)
                            }
                        }
                    }
                    .id(refreshID)
                    .refreshable { refreshID = UUID() }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
        }
    }

    // MARK: - Grouping

    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { (history: SessionHistory) -> Date in
            calendar.startOfDay(for: history.date)
        }

        return grouped.keys
            .sorted(by: >)
            .map { day in
                DayGroup(
                    date: day,
                    sessions: (grouped[day] ?? []).sorted { $0.date > $1.date }
                )
            }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .medium))

            Text("No history yet")
                .font(.headline)

            Text("Once you complete a session, it will show up here with sets, volume, and a quick recap.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helper types

struct DayGroup: Identifiable {
    let date: Date
    let sessions: [SessionHistory]
    var id: Date { date }
}

struct HistoryRow: View {
    let history: SessionHistory

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: history.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(history.title)
                    .font(.headline)

                Spacer()

                Text(dateString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !history.subtitle.isEmpty {
                Text(history.subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Label("\(history.totalExercises) lifts", systemImage: "dumbbell")
                Label("\(history.totalSets) sets", systemImage: "square.grid.3x3")
                Label("\(Int(history.totalVolume)) lb", systemImage: "scalemass")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
