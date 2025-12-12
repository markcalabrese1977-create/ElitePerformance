    import SwiftUI
    import SwiftData

    /// Plan editor for a single training day.
    /// - Lives under the Program tab.
    /// - Edits PLAN only (load / reps / RIR / sets).
    /// - No Actual logging here.
    struct ProgramDayDetailView: View {
        @Environment(\.modelContext) private var modelContext
        @Bindable var session: Session   // SwiftData-friendly

        @State private var showingAddExerciseSheet = false
        @State private var showingApplyScopeDialog = false

        // MARK: - Derived ordered items

        /// Session items sorted by their `order` field.
        /// This is the canonical order we want everywhere.
        private var orderedItems: [SessionItem] {
            session.items.sorted { $0.order < $1.order }
        }

        // MARK: - Body

        var body: some View {
            List {
                headerSection

                Section("Exercises") {
                    if orderedItems.isEmpty {
                        Text("No exercises yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        // Show rows in `order` order.
                        ForEach(orderedItems) { item in
                            ProgramExercisePlanRow(
                                item: item,
                                onMoveUp: { move(item, direction: -1) },
                                onMoveDown: { move(item, direction: 1) },
                                onDelete: { delete(item) }
                            )
                        }
                        .onMove(perform: moveItems)
                        .onDelete(perform: deleteItems)
                    }

                    Button {
                        showingAddExerciseSheet = true
                    } label: {
                        Label("Add exercise", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle(session.date.formatted(date: .abbreviated, time: .omitted))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply to block") {
                        showingApplyScopeDialog = true
                    }
                }
            }
            .sheet(isPresented: $showingAddExerciseSheet) {
                ExercisePickerView { catalogExercise in
                    addExercise(from: catalogExercise)
                }
            }
            .confirmationDialog(
                "Apply these plan changes to which days?",
                isPresented: $showingApplyScopeDialog,
                titleVisibility: .visible
            ) {
                Button("This weekday in this block") {
                    applyPlanChangesToBlock()
                }
                Button("Cancel", role: .cancel) { }
            }
        }

        // MARK: - Header / Summary

        private var headerSection: some View {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sessionLabel)
                        .font(.headline)

                    Text(summaryLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Adjust PLAN loads, reps, and RIR here. Logging happens on the Today tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }

        /// e.g. "Week 1 · Dec 9, 2025"
        private var sessionLabel: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none

            let dateString = formatter.string(from: session.date)
            return "\(dateString) · Week \(session.weekIndex)"
        }

        /// e.g. "5 exercises · 16 working sets"
        private var summaryLine: String {
            let exerciseCount = orderedItems.count
            let totalSets = orderedItems.map { $0.targetSets }.reduce(0, +)
            return "\(exerciseCount) exercises · \(totalSets) working sets"
        }

        // MARK: - CRUD helpers

        private func addExercise(from catalog: CatalogExercise) {
            let nextOrder = (session.items.map { $0.order }.max() ?? 0) + 1

            // Create new SessionItem with sensible defaults
            let newItem = SessionItem(
                order: nextOrder,
                exerciseId: catalog.id,
                targetReps: 10,
                targetSets: 3,
                targetRIR: 2,
                suggestedLoad: 0
            )

            let setCount = 4
            newItem.plannedRepsBySet = Array(repeating: newItem.targetReps, count: setCount)
            newItem.plannedLoadsBySet = Array(repeating: 0.0, count: setCount)
            newItem.actualReps = Array(repeating: 0, count: setCount)
            newItem.actualLoads = Array(repeating: 0.0, count: setCount)
            newItem.actualRIRs = Array(repeating: 0, count: setCount)
            newItem.usedRestPauseFlags = Array(repeating: false, count: setCount)
            newItem.restPausePatternsBySet = Array(repeating: "", count: setCount)

            session.items.append(newItem)

            do {
                try modelContext.save()
            } catch {
                print("⚠️ Failed to add exercise: \(error)")
            }
        }

        private func delete(_ item: SessionItem) {
            guard let index = session.items.firstIndex(where: { $0.id == item.id }) else { return }
            let removedOrder = session.items[index].order

            session.items.remove(at: index)

            // Re-normalize order so it stays contiguous
            for sessionItem in session.items where sessionItem.order > removedOrder {
                sessionItem.order -= 1
            }

            do {
                try modelContext.save()
            } catch {
                print("⚠️ Failed to delete exercise: \(error)")
            }
        }

        private func move(_ item: SessionItem, direction: Int) {
            // direction: -1 = up, +1 = down
            guard let currentIndex = session.items.firstIndex(where: { $0.id == item.id }) else { return }
            let newIndex = currentIndex + direction
            guard session.items.indices.contains(newIndex) else { return }

            session.items.swapAt(currentIndex, newIndex)

            // Re-write orders to be 1...N based on current array position
            for (idx, sessionItem) in session.items.enumerated() {
                sessionItem.order = idx + 1
            }

            do {
                try modelContext.save()
            } catch {
                print("⚠️ Failed to move exercise: \(error)")
            }
        }

        private func moveItems(from offsets: IndexSet, to destination: Int) {
            var items = orderedItems
            items.move(fromOffsets: offsets, toOffset: destination)

            // Re-apply the new ordering to session.items
            for (idx, item) in items.enumerated() {
                if let sessionItem = session.items.first(where: { $0.id == item.id }) {
                    sessionItem.order = idx + 1
                }
            }

            do {
                try modelContext.save()
            } catch {
                print("⚠️ Failed to re-order items: \(error)")
            }
        }

        private func deleteItems(at offsets: IndexSet) {
            let itemsToDelete = offsets.map { orderedItems[$0] }
            for item in itemsToDelete {
                if let idx = session.items.firstIndex(where: { $0.id == item.id }) {
                    session.items.remove(at: idx)
                }
            }

            // Re-normalize order after deletions
            let sorted = session.items.sorted { $0.order < $1.order }
            for (idx, item) in sorted.enumerated() {
                item.order = idx + 1
            }

            do {
                try modelContext.save()
            } catch {
                print("⚠️ Failed to delete via swipe: \(error)")
            }
        }

        // MARK: - Apply to Block

        /// Apply the current day's PLAN to other sessions in the same block that share the same weekday.
        ///
        /// Copies PLAN fields only (sets / reps / RIR / suggested load / per-set plan) and
        /// does NOT touch logged Actuals.
        private func applyPlanChangesToBlock() {
            let calendar = Calendar.current
            let weekday = calendar.component(.weekday, from: session.date)  // 1=Sun...7=Sat

            // Fetch all sessions; we'll filter in Swift instead of inside the #Predicate
            let descriptor = FetchDescriptor<Session>()

            do {
                let allSessions = try modelContext.fetch(descriptor)

                let otherSessions = allSessions.filter { other in
                    other.id != session.id &&
                    other.status != .completed &&
                    calendar.component(.weekday, from: other.date) == weekday
                }

                guard !otherSessions.isEmpty else {
                    print("ℹ️ No other sessions in this block matched for applyPlanChangesToBlock.")
                    return
                }

                // Use the current session's items (ordered) as the source of truth.
                let sourceItems = orderedItems

                for other in otherSessions {
                    let targetItems = other.items

                    for sourceItem in sourceItems {
                        guard let target = targetItems.first(where: { $0.exerciseId == sourceItem.exerciseId }) else {
                            continue
                        }

                        // Copy PLAN-related fields
                        target.targetReps        = sourceItem.targetReps
                        target.targetSets        = sourceItem.targetSets
                        target.targetRIR         = sourceItem.targetRIR
                        target.suggestedLoad     = sourceItem.suggestedLoad
                        target.plannedRepsBySet  = sourceItem.plannedRepsBySet
                        target.plannedLoadsBySet = sourceItem.plannedLoadsBySet
                    }

                    // We intentionally do NOT change `order` or add/remove exercises here.
                }

                try modelContext.save()
                print("✅ Applied plan changes from \(session.date) to \(otherSessions.count) other sessions.")
            } catch {
                print("⚠️ Failed to apply plan changes to block: \(error)")
            }
        }
    }

    // MARK: - Per-exercise plan row

private struct ProgramExercisePlanRow: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var item: SessionItem

    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            planRow
            perSetPlanEditor
        }
        .padding(.vertical, 8)
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)

                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var planRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sets")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Stepper(value: $item.targetSets, in: 1...6) {
                    Text("\(item.targetSets)")
                        .font(.body)
                }
                .frame(maxWidth: 120, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Reps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Stepper(value: $item.targetReps, in: 4...30, step: 1) {
                    Text("\(item.targetReps)")
                        .font(.body)
                }
                .frame(maxWidth: 140, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("RIR")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Stepper(value: $item.targetRIR, in: 0...5) {
                    Text("\(item.targetRIR)")
                        .font(.body)
                }
                .frame(maxWidth: 120, alignment: .leading)
            }
        }
    }

    private var perSetPlanEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Per-set plan (load × reps @ RIR)")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(0..<4, id: \.self) { idx in
                HStack(spacing: 8) {
                    Text("Set \(idx + 1)")
                        .font(.caption2)
                        .frame(width: 40, alignment: .leading)

                    TextField("Load", value: bindingForLoad(at: idx), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .frame(width: 70)

                    TextField("Reps", value: bindingForReps(at: idx), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(width: 60)

                    TextField("RIR", value: bindingForRIR(at: idx), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(width: 50)
                }
            }
        }
        // 📌 Normalize once when the row appears
        .onAppear {
            normalizeArraySizes()
        }
        // And whenever the high-level plan changes
        .onChange(of: item.targetReps) { newValue in
            normalizeArraySizes()
            for idx in 0..<min(item.targetSets, item.plannedRepsBySet.count) {
                if item.plannedRepsBySet[idx] == 0 {
                    item.plannedRepsBySet[idx] = newValue
                }
            }
            save()
        }
        .onChange(of: item.targetSets) { _ in
            normalizeArraySizes()
            save()
        }
        .onChange(of: item.targetRIR) { newValue in
            normalizeArraySizes()
            for idx in 0..<min(item.targetSets, item.actualRIRs.count) {
                if item.actualRIRs[idx] == 0 {
                    item.actualRIRs[idx] = newValue
                }
            }
            save()
        }
    }

    // MARK: - Display helpers

    private var displayName: String {
        if let catalog = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId }) {
            return catalog.name
        } else {
            return "Exercise"
        }
    }

    private var detailLine: String {
        let muscle: String
        if let catalog = ExerciseCatalog.all.first(where: { $0.id == item.exerciseId }) {
            muscle = catalog.primaryMuscle.rawValue.capitalized
        } else {
            muscle = "—"
        }

        return "\(muscle) · \(item.targetReps) reps @ \(item.targetRIR) RIR"
    }

    // MARK: - Array + Binding helpers

    private func normalizeArraySizes() {
        let setCount = max(4, item.targetSets)

        func ensureIntArray(_ array: inout [Int]) {
            if array.count < setCount {
                array.append(contentsOf: repeatElement(0, count: setCount - array.count))
            } else if array.count > setCount {
                array = Array(array.prefix(setCount))
            }
        }

        func ensureDoubleArray(_ array: inout [Double]) {
            if array.count < setCount {
                array.append(contentsOf: repeatElement(0.0, count: setCount - array.count))
            } else if array.count > setCount {
                array = Array(array.prefix(setCount))
            }
        }

        ensureIntArray(&item.plannedRepsBySet)
        ensureDoubleArray(&item.plannedLoadsBySet)
        ensureIntArray(&item.actualReps)
        ensureDoubleArray(&item.actualLoads)
        ensureIntArray(&item.actualRIRs)

        if item.usedRestPauseFlags.count < setCount {
            item.usedRestPauseFlags.append(
                contentsOf: repeatElement(false, count: setCount - item.usedRestPauseFlags.count)
            )
        } else if item.usedRestPauseFlags.count > setCount {
            item.usedRestPauseFlags = Array(item.usedRestPauseFlags.prefix(setCount))
        }

        if item.restPausePatternsBySet.count < setCount {
            item.restPausePatternsBySet.append(
                contentsOf: repeatElement("", count: setCount - item.restPausePatternsBySet.count)
            )
        } else if item.restPausePatternsBySet.count > setCount {
            item.restPausePatternsBySet = Array(item.restPausePatternsBySet.prefix(setCount))
        }
    }

    private func bindingForLoad(at index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard index < item.plannedLoadsBySet.count else { return 0 }
                return item.plannedLoadsBySet[index]
            },
            set: { newValue in
                if index >= item.plannedLoadsBySet.count {
                    normalizeArraySizes()
                }
                if index < item.plannedLoadsBySet.count {
                    item.plannedLoadsBySet[index] = newValue
                    save()
                }
            }
        )
    }

    private func bindingForReps(at index: Int) -> Binding<Int> {
        Binding(
            get: {
                guard index < item.plannedRepsBySet.count else { return 0 }
                return item.plannedRepsBySet[index]
            },
            set: { newValue in
                if index >= item.plannedRepsBySet.count {
                    normalizeArraySizes()
                }
                if index < item.plannedRepsBySet.count {
                    item.plannedRepsBySet[index] = newValue
                    save()
                }
            }
        )
    }

    private func bindingForRIR(at index: Int) -> Binding<Int> {
        Binding(
            get: {
                guard index < item.actualRIRs.count else { return item.targetRIR }
                let stored = item.actualRIRs[index]
                return stored == 0 ? item.targetRIR : stored
            },
            set: { newValue in
                if index >= item.actualRIRs.count {
                    normalizeArraySizes()
                }
                if index < item.actualRIRs.count {
                    item.actualRIRs[index] = newValue
                    save()
                }
            }
        )
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            print("⚠️ Failed to save per-set plan changes: \(error)")
        }
    }
}

    // MARK: - Exercise Picker used by "Add exercise"

    private struct ExercisePickerView: View {
        @Environment(\.dismiss) private var dismiss

        let onSelect: (CatalogExercise) -> Void

        private var exercises: [CatalogExercise] {
            ExerciseCatalog.all
        }

        var body: some View {
            NavigationStack {
                List(exercises) { exercise in
                    Button {
                        onSelect(exercise)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exercise.name)
                                .font(.body)

                            Text(exercise.primaryMuscle.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Add Exercise")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
