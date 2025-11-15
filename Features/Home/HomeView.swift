import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { session in
                    NavigationLink {
                        SessionView(session: session)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.date, style: .date)
                                .font(.headline)

                            Text(session.status.displayTitle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            if let firstItem = session.items.sorted(by: { $0.order < $1.order }).first {
                                let ex = ExerciseCatalog.all.first { $0.id == firstItem.exerciseId }
                                Text(ex?.name ?? "No exercises yet")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
        }
    }
}

#Preview {
    HomeView()
        .modelContainer(previewContainer)
}

// Simple preview container to keep Xcode happy.
// Adjust or remove if you already have one elsewhere.
private var previewContainer: ModelContainer = {
    let schema = Schema([
        User.self,
        Session.self,
        SessionItem.self,
        SetLog.self,
        PRIndex.self
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    // We’ll swallow the error for preview-only container.
    return try! ModelContainer(for: schema, configurations: [config])
}()
