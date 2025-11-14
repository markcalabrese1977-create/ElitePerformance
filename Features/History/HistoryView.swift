import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \Session.date, order: .reverse) private var sessions: [Session]

    var body: some View {
        List {
            ForEach(sessions) { s in
                VStack(alignment: .leading) {
                    Text(s.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    Text("\(s.items.count) exercises").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("History")
    }
}
