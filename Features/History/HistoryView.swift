import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \Session.date, order: .reverse)
    private var sessions: [Session]

    var body: some View {
        NavigationStack {
            if sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("No sessions logged yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .navigationTitle("History")
            } else {
                List {
                    ForEach(sessions) { session in
                        HistoryRow(session: session)
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("History")
            }
        }
    }
}

private struct HistoryRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.date, format: .dateTime.weekday(.wide).month().day())
                .font(.subheadline.weight(.semibold))

            Text("Week \(session.weekIndex)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let exerciseCount = session.items.count
        if exerciseCount == 1 {
            return "1 exercise"
        } else {
            return "\(exerciseCount) exercises"
        }
    }
}
