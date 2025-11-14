import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Session.date, order: .forward, animation: .default) private var sessions: [Session]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let today = sessions.first(where: { Calendar.current.isDateInToday($0.date) }) {
                    SessionCard(session: today)
                } else if let first = sessions.first {
                    SessionCard(session: first)
                } else {
                    Text("No session yet — pull down to refresh or add via Onboarding.")
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Do This Today")
        }
    }
}

struct SessionCard: View {
    @Environment(\.modelContext) private var context
    @State var session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's Session").font(.title2).bold()
            if let first = session.items.sorted(by: { $0.order < $1.order }).first, let ex = first.exercise {
                Text("\(ex.name)").font(.headline)
                Text("Target: \(first.targetSets) × \(first.targetReps) @ RIR \(first.targetRIR)")
                    .foregroundStyle(.secondary)
            }
            NavigationLink("Start / Resume") {
                SessionView(session: session)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
