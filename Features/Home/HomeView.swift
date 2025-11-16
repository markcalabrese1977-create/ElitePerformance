import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    Text("No sessions yet. Complete onboarding to create your first block.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(sessions) { session in
                        NavigationLink {
                            SessionView(session: session)
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !sessions.isEmpty {
                        NavigationLink {
                            ProgramPlanView()
                        } label: {
                            Text("Plan Loads")
                        }
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: Session

    private var firstExerciseName: String {
        if let firstItem = session.items.sorted(by: { $0.order < $1.order }).first,
           let ex = ExerciseCatalog.all.first(where: { $0.id == firstItem.exerciseId }) {
            return ex.name
        }
        return "No exercises yet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.date, style: .date)
                .font(.headline)

            HStack(spacing: 8) {
                Text(session.status.displayTitle)
                if session.weekIndex > 0 {
                    Text("Week \(session.weekIndex)")
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)

            Text(firstExerciseName)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    HomeView()
        .modelContainer(previewContainer)
}

// Simple preview container to keep Xcode happy.
private var previewContainer: ModelContainer = {
    let schema = Schema([
        User.self,
        Session.self,
        SessionItem.self,
        SetLog.self,
        PRIndex.self
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try! ModelContainer(for: schema, configurations: [config])
}()
