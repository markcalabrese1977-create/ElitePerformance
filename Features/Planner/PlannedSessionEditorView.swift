import SwiftUI
import SwiftData

struct PlannedSessionEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: Session

    @State private var showingAddExercise = false
    @State private var startNow = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Button {
                        showingAddExercise = true
                    } label: {
                        Label("Add Exercise", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        session.status = .inProgress
                        startNow = true
                    } label: {
                        Label("Start Workout", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("Exercises") {
                if session.items.isEmpty {
                    Text("No exercises yet. Tap “Add Exercise”.")
                        .foregroundStyle(.secondary)
                }

                ForEach(session.items.sorted(by: { $0.order < $1.order })) { item in
                    PlannedExerciseRow(item: item)
                }
                .onDelete(perform: deleteItems)
                .onMove(perform: moveItems)
            }

            Section {
                Button(role: .destructive) {
                    context.delete(session)
                    try? context.save()
                    dismiss()
                } label: {
                    Label("Delete Workout", systemImage: "trash")
                }
            }
        }
        .navigationTitle(session.date.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        .sheet(isPresented: $showingAddExercise) {
            AddExerciseSheet { ex in
                addExercise(ex)
                showingAddExercise = false
            } onCancel: {
                showingAddExercise = false
            }
        }
        .background {
            NavigationLink(isActive: $startNow) {
                // IMPORTANT: adjust if your SessionView init differs
                SessionView(viewModel: SessionScreenViewModel(session: session))
            } label: { EmptyView() }
            .hidden()
        }
    }

    private func addExercise(_ ex: CatalogExercise) {
        let nextOrder = (session.items.map(\.order).max() ?? 0) + 1

        // Default Angela plan values (simple)
        let targetSets = 3
        let targetReps = 10
        let targetRIR = 2
        let suggestedLoad: Double = 0

        // IMPORTANT: adjust SessionItem initializer if needed (Step 6.4)
        let item = SessionItem(
            order: nextOrder,
            exerciseId: ex.id,
            targetReps: targetReps,
            targetSets: targetSets,
            targetRIR: targetRIR,
            suggestedLoad: suggestedLoad,
            plannedRepsBySet: Array(repeating: targetReps, count: targetSets),
            plannedLoadsBySet: Array(repeating: suggestedLoad, count: targetSets)
        )

        session.items.append(item)
    }

    private func deleteItems(at offsets: IndexSet) {
        let sorted = session.items.sorted(by: { $0.order < $1.order })
        for idx in offsets {
            let item = sorted[idx]
            if let i = session.items.firstIndex(where: { $0.id == item.id }) {
                session.items.remove(at: i)
            }
        }
        resequenceOrders()
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        var sorted = session.items.sorted(by: { $0.order < $1.order })
        sorted.move(fromOffsets: source, toOffset: destination)
        for (i, item) in sorted.enumerated() { item.order = i + 1 }
    }

    private func resequenceOrders() {
        let sorted = session.items.sorted(by: { $0.order < $1.order })
        for (i, item) in sorted.enumerated() { item.order = i + 1 }
    }
}

private struct PlannedExerciseRow: View {
    @Bindable var item: SessionItem

    private var name: String {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })?.name ?? item.exerciseId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline)

            Stepper("Sets: \(item.targetSets)", value: $item.targetSets, in: 1...8)
                .onChange(of: item.targetSets) { _ in syncPlanArrays() }

            Stepper("Reps: \(item.targetReps)", value: $item.targetReps, in: 3...30)
                .onChange(of: item.targetReps) { _ in syncPlanArrays() }

            Stepper("RIR: \(item.targetRIR)", value: $item.targetRIR, in: 0...5)
                .onChange(of: item.targetRIR) { _ in syncPlanArrays() }
        }
        .padding(.vertical, 4)
    }

    private func syncPlanArrays() {
        let sets = max(1, item.targetSets)
        item.plannedRepsBySet = Array(repeating: item.targetReps, count: sets)
        item.plannedLoadsBySet = Array(repeating: item.suggestedLoad, count: sets)
    }
}
