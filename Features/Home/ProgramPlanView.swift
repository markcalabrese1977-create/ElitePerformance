import SwiftUI
import SwiftData

/// "Program Plan" screen to seed starting loads for each exercise
/// across the current block. This lets you plan before you ever hit
/// the first session, so in-session logging is execution vs plan.
struct ProgramPlanView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Session.date, order: .forward) private var sessions: [Session]

    /// Text fields keyed by exerciseId
    @State private var loadText: [String: String] = [:]

    /// All SessionItems in the block.
    private var allItems: [SessionItem] {
        sessions.flatMap { $0.items }
    }

    /// Unique exercises present in the block, sorted by name.
    private var exercises: [(id: String, name: String)] {
        let grouped = Dictionary(grouping: allItems, by: { $0.exerciseId })

        return grouped.compactMap { (exerciseId, _) in
            let ex = ExerciseCatalog.all.first { $0.id == exerciseId }
            let name = ex?.name ?? "Exercise \(exerciseId)"
            return (id: exerciseId, name: name)
        }
        .sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            if exercises.isEmpty {
                Text("No sessions found. Complete onboarding to create a block first.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Section(footer: footerNote) {
                    ForEach(exercises, id: \.id) { exercise in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(exercise.name)
                                    .font(.headline)

                                Text(exercise.id)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            TextField("Load", text: binding(for: exercise.id))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Starting Loads")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveLoads()
                }
                .disabled(exercises.isEmpty)
            }
        }
        .onAppear {
            if loadText.isEmpty {
                seedFromExisting()
            }
        }
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("These loads will be used as the planned working weight for every set of this exercise across the block. You can still adjust per set when logging.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.top, 4)
    }

    private func binding(for exerciseId: String) -> Binding<String> {
        Binding(
            get: { loadText[exerciseId] ?? "" },
            set: { loadText[exerciseId] = $0 }
        )
    }

    /// Seed the text fields from any existing planned or suggested loads,
    /// so you can tweak instead of always starting from blank.
    private func seedFromExisting() {
        for exercise in exercises {
            let exerciseId = exercise.id
            guard loadText[exerciseId] == nil else { continue }

            let itemsForExercise = allItems.filter { $0.exerciseId == exerciseId }

            // Prefer plannedLoadsBySet if present
            if let withPlan = itemsForExercise.first(where: { !$0.plannedLoadsBySet.isEmpty && $0.plannedLoadsBySet[0] > 0 }) {
                let value = withPlan.plannedLoadsBySet[0]
                loadText[exerciseId] = value > 0 ? String(format: "%.1f", value) : ""
                continue
            }

            // Fall back to suggestedLoad
            if let withSuggested = itemsForExercise.first(where: { $0.suggestedLoad > 0 }) {
                let value = withSuggested.suggestedLoad
                loadText[exerciseId] = value > 0 ? String(format: "%.1f", value) : ""
                continue
            }
        }
    }

    /// Persist the planned loads back into all matching SessionItems.
    /// For each exerciseId, every SessionItem in the block gets:
    /// - suggestedLoad = value
    /// - plannedLoadsBySet = [value, value, ...] for each target set
    private func saveLoads() {
        guard !sessions.isEmpty else { return }

        for (exerciseId, text) in loadText {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Double(trimmed), value > 0 else { continue }

            for session in sessions {
                for item in session.items where item.exerciseId == exerciseId {
                    item.suggestedLoad = value
                    let setCount = max(item.targetSets, 1)
                    item.plannedLoadsBySet = Array(repeating: value, count: setCount)
                }
            }
        }

        try? context.save()
    }
}//
//  ProgramPlanView.swift
//  ElitePerformance
//
//  Created by Mark Calabrese on 11/16/25.
//

