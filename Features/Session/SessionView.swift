import SwiftUI
import SwiftData

// MARK: - Main Session View

struct SessionView: View {
    @Environment(\.modelContext) private var context
    @Bindable var session: Session

    @State private var selectedItemForLogging: SessionItem?
    @State private var selectedItemForSwap: SessionItem?
    @State private var navigateToRecap: Bool = false

    // DEV PHASE: allow logging any session regardless of date
    private var canLogCurrentSession: Bool {
        true
    }

    private var sortedItems: [SessionItem] {
        session.items.sorted { $0.order < $1.order }
    }

    private var header: some View {
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
        }
    }

    var body: some View {
        NavigationStack {
            VStack {
                List {
                    Section(header: header) {
                        ForEach(sortedItems) { item in
                            SessionItemRow(
                                item: item,
                                canLog: canLogCurrentSession,
                                onLogTapped: { selectedItemForLogging = item },
                                onSwapTapped: { selectedItemForSwap = item }
                            )
                            .swipeActions {
                                Button(role: .destructive) {
                                    deleteItem(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                // Hidden navigation link to recap
                NavigationLink(
                    destination: SessionRecapView(session: session),
                    isActive: $navigateToRecap
                ) {
                    EmptyView()
                }
                .hidden()
            }
            .navigationTitle("Session")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Complete") {
                        // 1) Mark the session completed and persist
                        session.status = .completed
                        try? context.save()

                        // 2) Defer navigation to the next run loop turn
                        //    so SwiftUI builds SessionRecapView off the updated model.
                        DispatchQueue.main.async {
                            navigateToRecap = true
                        }
                    }
                }
            }
            .sheet(item: $selectedItemForLogging) { item in
                ExerciseLogSheet(item: item)
            }
            .sheet(item: $selectedItemForSwap) { item in
                ExerciseSwapSheet(item: item)
            }
        }
    }

    // MARK: - Helpers

    private func deleteItem(_ item: SessionItem) {
        if let index = session.items.firstIndex(where: { $0.id == item.id }) {
            session.items.remove(at: index)
        }
        context.delete(item)
        try? context.save()
    }
}

// MARK: - Row for a single exercise in the session

struct SessionItemRow: View {
    let item: SessionItem
    let canLog: Bool
    let onLogTapped: () -> Void
    let onSwapTapped: () -> Void

    private var exercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    private var loggedSummary: String {
        let count = min(item.actualReps.count, item.actualLoads.count)
        guard count > 0 else { return "Not logged" }

        let nonZero = (0..<count).filter { idx in
            item.actualReps[idx] > 0 && item.actualLoads[idx] > 0
        }.count

        return "\(nonZero) set\(nonZero == 1 ? "" : "s") logged"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(exercise?.name ?? "Unknown exercise")
                    .font(.headline)

                Spacer()

                if item.isPR {
                    Text("PR")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2))
                        .foregroundColor(.purple)
                        .cornerRadius(6)
                }
            }

            HStack {
                Text("Planned: \(item.targetSets)x\(item.targetReps) · RIR \(item.targetRIR)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(loggedSummary)
                    .font(.caption)
            }

            HStack {
                Button {
                    if canLog {
                        onLogTapped()
                    }
                } label: {
                    Text(canLog ? "Log sets" : "Locked")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canLog)

                Button {
                    onSwapTapped()
                } label: {
                    Text("Swap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Log Sheet (Plan vs Actual per set, 0.5 lb loads + RIR + coaching + propagation)

struct ExerciseLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var item: SessionItem

    @State private var actualLoads: [Double]
    @State private var actualReps: [Int]
    @State private var actualRIRs: [Int]

    private let maxSets = 5

    private var exercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    init(item: SessionItem) {
        self._item = Bindable(wrappedValue: item)

        var loads = Array(repeating: 0.0, count: maxSets)
        var reps  = Array(repeating: 0, count: maxSets)
        var rirs  = Array(repeating: item.targetRIR, count: maxSets)

        // Seed from existing actuals first
        for idx in 0..<min(maxSets, item.actualLoads.count) {
            loads[idx] = item.actualLoads[idx]
        }
        for idx in 0..<min(maxSets, item.actualReps.count) {
            reps[idx] = item.actualReps[idx]
        }
        for idx in 0..<min(maxSets, item.actualRIRs.count) {
            rirs[idx] = item.actualRIRs[idx]
        }

        // Where actuals are zero, fall back to planned loads/reps/targetRIR
        for idx in 0..<min(maxSets, item.plannedLoadsBySet.count) {
            if loads[idx] == 0 {
                loads[idx] = item.plannedLoadsBySet[idx]
            }
        }
        for idx in 0..<min(maxSets, item.plannedRepsBySet.count) {
            if reps[idx] == 0 {
                reps[idx] = item.plannedRepsBySet[idx]
            }
        }
        for idx in 0..<maxSets {
            if rirs[idx] <= 0 {
                rirs[idx] = item.targetRIR
            }
        }

        _actualLoads = State(initialValue: loads)
        _actualReps = State(initialValue: reps)
        _actualRIRs = State(initialValue: rirs)
    }

    var body: some View {
        NavigationStack {
            List {
                if let exercise {
                    Section {
                        Text(exercise.name)
                            .font(.headline)
                    }
                }

                Section(header: Text("Log sets")) {
                    ForEach(0..<maxSets, id: \.self) { index in
                        // Planned values with safe fallbacks
                        let plannedLoad: Double = {
                            if index < item.plannedLoadsBySet.count {
                                return item.plannedLoadsBySet[index]
                            } else {
                                return item.suggestedLoad
                            }
                        }()

                        let plannedReps: Int = {
                            if index < item.plannedRepsBySet.count {
                                return item.plannedRepsBySet[index]
                            } else {
                                return item.targetReps
                            }
                        }()

                        let plannedRIR = item.targetRIR

                        SessionSetRowView(
                            index: index,
                            plannedLoad: plannedLoad,
                            plannedReps: plannedReps,
                            plannedRIR: plannedRIR,
                            actualLoad: $actualLoads[index],
                            actualReps: $actualReps[index],
                            actualRIR: $actualRIRs[index]
                        )
                    }

                    // No add/remove buttons in this version.
                    // Use as many of the 5 rows as you actually do.
                }
            }
            .navigationTitle("Log Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveLogs()
                        dismiss()
                    }
                }
            }
        }
    }

    private func saveLogs() {
        // 1) Autopopulate loads:
        // When you log your first non-zero load, use it for later sets
        // that have reps but still zero load.
        var normalizedLoads = actualLoads

        if let baseIndex = normalizedLoads.firstIndex(where: { $0 > 0.0 }) {
            let baseLoad = normalizedLoads[baseIndex]
            for idx in 0..<normalizedLoads.count {
                if normalizedLoads[idx] == 0.0 && actualReps[idx] > 0 {
                    normalizedLoads[idx] = baseLoad
                }
            }
        }

        // 2) Persist back to the SessionItem
        item.actualReps = actualReps
        item.actualLoads = normalizedLoads
        item.actualRIRs = actualRIRs

        // 3) Run the coaching engine on this execution
        if let rec = CoachingEngine.recommend(for: item),
           let nextLoad = rec.nextSuggestedLoad {
            // Store note + next load on this item (for debugging / future use).
            item.coachNote = rec.message
            item.nextSuggestedLoad = nextLoad

            // Push that next load into the next occurrence of this exercise.
            propagateNextLoad(for: item, nextLoad: nextLoad)
        }

        // 4) Save to SwiftData
        try? context.save()
    }

    /// Find the next SessionItem with the same exercise on a later date
    /// and seed its planned loads with the recommended nextLoad.
    private func propagateNextLoad(for currentItem: SessionItem, nextLoad: Double) {
        let descriptor = FetchDescriptor<Session>()

        guard let sessions = try? context.fetch(descriptor),
              !sessions.isEmpty else {
            return
        }

        // Find the session that owns the current item.
        guard let currentSession = sessions.first(where: { session in
            session.items.contains(where: { $0.id == currentItem.id })
        }) else {
            return
        }

        let currentDate = currentSession.date

        // Sort sessions by date so "next" is chronological.
        let sortedSessions = sessions.sorted { $0.date < $1.date }

        // Find the next SessionItem with the same exerciseId on a later date.
        for session in sortedSessions {
            guard session.date > currentDate else { continue }

            if let nextItem = session.items.first(where: { $0.exerciseId == currentItem.exerciseId }) {
                let setCount = max(nextItem.targetSets, 1)

                nextItem.suggestedLoad = nextLoad
                nextItem.plannedLoadsBySet = Array(repeating: nextLoad, count: setCount)

                break // only update the first future occurrence
            }
        }
    }
}

// MARK: - Swap sheet

/// Sheet for swapping an exercise using SwapMap.
struct ExerciseSwapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var item: SessionItem

    private var currentExercise: CatalogExercise? {
        ExerciseCatalog.all.first(where: { $0.id == item.exerciseId })
    }

    private var alternatives: [CatalogExercise] {
        // DEV PHASE: allow swapping to ANY other exercise in the catalog.
        SwapMap.swapOptions(for: item.exerciseId)
    }

    var body: some View {
        NavigationStack {
            List {
                if let current = currentExercise {
                    Section(header: Text("Current")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(current.name)
                                .font(.headline)
                            Text(current.primaryMuscle.rawValue.capitalized)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("Swap options")) {
                    ForEach(alternatives) { alt in
                        Button {
                            item.exerciseId = alt.id
                            try? context.save()
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(alt.name)
                                    Text(alt.primaryMuscle.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if alt.id == item.exerciseId {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Swap Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Per-set row (Plan vs Actual with 0.5 lb increments + RIR)

struct SessionSetRowView: View {
    /// Index of the set (0-based here, but will display as 1-based)
    let index: Int

    /// Planned values
    let plannedLoad: Double
    let plannedReps: Int
    let plannedRIR: Int

    /// Bindings into the actual values stored on SessionItem
    @Binding var actualLoad: Double
    @Binding var actualReps: Int
    @Binding var actualRIR: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set \(index + 1)")
                .font(.caption)
                .fontWeight(.semibold)

            // PLAN row
            HStack(spacing: 4) {
                Text("Planned:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("\(plannedLoad, specifier: "%.1f") lb × \(plannedReps) @ RIR \(plannedRIR)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ACTUAL row
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Actual:")
                        .font(.subheadline)

                    // Load with 0.5 lb increments
                    Stepper(
                        value: $actualLoad,
                        in: 0...1000,
                        step: 2.5
                    ) {
                        Text("\(actualLoad, specifier: "%.1f") lb")
                            .frame(minWidth: 70, alignment: .leading)
                    }

                    // Reps
                    Stepper(
                        value: $actualReps,
                        in: 0...50
                    ) {
                        Text("\(actualReps) reps")
                            .frame(minWidth: 60, alignment: .leading)
                    }
                }

                // RIR
                HStack(spacing: 8) {
                    Text("RIR:")
                        .font(.caption)

                    Stepper(
                        value: $actualRIR,
                        in: 0...5
                    ) {
                        Text("\(actualRIR)")
                            .font(.caption)
                            .frame(minWidth: 24, alignment: .leading)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
