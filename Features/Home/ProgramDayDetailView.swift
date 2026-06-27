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
    @State private var feedbackMessage: String = ""
    @State private var showFeedbackAlert = false
    @State private var historyTarget: HistoryTarget?
    @State private var noteTarget: NoteTarget?
    @State private var propagateAddToFutureSessions: Bool = true
    @State private var propagateChangesToFutureSessions: Bool = true
    @State private var showDayLabelEditor: Bool = false
    @State private var dayLabelDraft: String = ""

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
                    ForEach(orderedItems) { item in
                        ProgramExercisePlanRow(
                            item: item,
                            onMoveUp:  { move(item, direction: -1) },
                            onMoveDown:{ move(item, direction: 1) },
                            onDelete:  { delete(item) },
                            onHistoryTapped: { exerciseId, exerciseName in
                                                            let canonicalId = ExerciseCatalog.canonicalExerciseId(for: exerciseId)
                                                            historyTarget = HistoryTarget(
                                                                exerciseId: canonicalId,
                                                                exerciseName: exerciseName
                                                            )
                                                        },
                            onNoteTapped: {
                                                            let canonicalId = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
                                                            let name = ExerciseCatalog.displayName(for: canonicalId)
                                                            noteTarget = NoteTarget(exerciseId: canonicalId, exerciseName: name)
                                                        },
                                                        isMaintenance: session.meso?.name.lowercased().contains("maintenance") == true
                                                    )
                    }
                    .onMove(perform: moveItems)
                    .onDelete(perform: deleteItems)
                }

                Button {
                    print("✅ Add exercise tapped")
                    showingAddExerciseSheet = true
                } label: {
                    Label("Add exercise", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle(session.date.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Auto+") {
                    autoGenerateSuggestedLoadsFromHistoryForThisDay()
                }

                Button("Auto") {
                    autoGeneratePerSetPlanForThisDay()
                }

                
            }
        }
        
        
        .alert("Plan Update", isPresented: $showFeedbackAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(feedbackMessage)
        }
        .alert("Rename Day", isPresented: $showDayLabelEditor) {
            TextField("Day label", text: $dayLabelDraft)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                renameDayLabel(to: dayLabelDraft)
            }
        } message: {
            Text("This name also updates future sessions on the same day of the week.")
        }
        
        // ✅ ADD THIS
        .sheet(isPresented: $showingAddExerciseSheet) {
            AddExerciseSheet(
                onSelect: { catalogExercise in
                    addExercise(from: catalogExercise)
                    showingAddExerciseSheet = false
                },
                onCancel: {
                    showingAddExerciseSheet = false
                }
            )
        }
        .sheet(item: $historyTarget) { target in
            ExerciseHistorySheet(
                            exerciseId: target.exerciseId,
                            exerciseName: target.exerciseName,
                            currentWave: nil,
                            onClose: { historyTarget = nil }
                        )
                        .presentationDetents([.large])
                        .presentationDragIndicator(.hidden)
        }
        .sheet(item: $noteTarget) { target in
            ExerciseNoteSheet(
                exerciseId: target.exerciseId,
                exerciseName: target.exerciseName,
                onClose: { noteTarget = nil }
            )
        }
    }
    private func presentFeedback(_ message: String) {
        feedbackMessage = message
        showFeedbackAlert = true
    }
    // MARK: - Header / Summary

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                if let sessionDayLabel {
                    HStack(spacing: 6) {
                        Text(sessionDayLabel)
                            .font(.headline)
                        Button {
                            dayLabelDraft = sessionDayLabel
                            showDayLabelEditor = true
                        } label: {
                            Image(systemName: "pencil.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(sessionLabel)
                    .font(sessionDayLabel == nil ? .headline : .subheadline)
                    .foregroundStyle(sessionDayLabel == nil ? .primary : .secondary)

                Text(summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Adjust plan defaults here. Logging happens on the Today tab.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Toggle(isOn: $propagateChangesToFutureSessions) {
                                    Text("Apply changes to future sessions")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .toggleStyle(.switch)
                                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }

    private var sessionDayLabel: String? {
        let trimmed = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
    
    /// e.g. "Dec 9, 2025 · Week 1"
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

    // MARK: - Auto-generate (no model changes)

    // MARK: - Auto+ (From History): update suggestedLoad from last logged performance
 
        private func autoGenerateSuggestedLoadsFromHistoryForThisDay() {
            let sessions = fetchRecentSessions(limit: 60)
            var foundHistory = false

            let activeMesoIDs = LoadProjectionService.activeMesoSessionIDs(from: modelContext)

            let profileDescriptor = FetchDescriptor<UserProfile>()
            let profile = try? modelContext.fetch(profileDescriptor).first
            let loadIncrement: Double = profile?.minLoadIncrement ?? 2.5
            let bodyWeight = profile?.bodyWeight
            let customExercises = (try? modelContext.fetch(FetchDescriptor<CustomExercise>())) ?? []

            // Maintenance sessions use deload wave but must not have loads reduced by projection.
                        // Detect via meso name — hold current suggested load and skip projection entirely.
                        let isMaintenanceSession = session.meso?.name.lowercased().contains("maintenance") == true

            for item in orderedItems {
                                        if isMaintenanceSession {
                                            // Hold current load and reps — maintenance goal is retention, not progression.
                                            // Sync per-set loads from suggestedLoad, trimmed strictly to targetSets.
                                            if item.suggestedLoad <= 0 {
                                                seedSuggestedLoadIfNeeded(item)
                                            }
                                            let load = item.suggestedLoad
                                            let setCount = item.targetSets
                                            item.plannedLoadsBySet = Array(repeating: load, count: setCount)
                                            item.plannedRepsBySet = Array(repeating: item.targetReps, count: setCount)
                                            item.plannedRIRsBySet = Array(repeating: item.targetRIR, count: setCount)
                                            continue
                                        }

                                        // Use repMin as the effective target when set — targetReps may be
                                        // stale from a prior wave's carry-forward. repMin/repMax are always
                                        // wave-correct since they come from the prescription, not carry-forward.
                                        let effectiveReps = item.repMin ?? item.targetReps
                                        let projection = LoadProjectionService.project(
                                            exerciseId: item.exerciseId,
                                            targetReps: effectiveReps,
                                            targetRIR: item.targetRIR,
                                            repMin: item.repMin ?? item.targetReps,
                                            repMax: item.repMax ?? item.targetReps,
                                            currentWaveRaw: item.waveRaw,
                                            allSessions: sessions,
                                            activeMesoSessionIDs: activeMesoIDs,
                                            loadIncrement: loadIncrement,
                                            bodyWeight: bodyWeight,
                                            customExercises: customExercises
                                        )

                                        if let projection = projection, projection.suggestedLoad > 0 {
                                            foundHistory = true
                                            item.suggestedLoad = projection.suggestedLoad
                                        } else {
                                            seedSuggestedLoadIfNeeded(item)
                                        }

                                        autoGeneratePerSetPlan(for: item, overwriteLoadsFromSuggested: true)
                                    }

            do {
                try modelContext.save()
                print("✅ Auto+ applied via LoadProjectionService")

                if foundHistory {
                    presentFeedback("Updated suggested loads from history and refreshed per-set defaults.")
                } else {
                    presentFeedback("No exercise history found. Kept current defaults and refreshed the plan structure.")
                }
            } catch {
                print("⚠️ Auto+ save failed: \(error)")
                presentFeedback("Couldn't update Auto+ plan: \(error.localizedDescription)")
            }
        }
    
    private func seedSuggestedLoadIfNeeded(_ item: SessionItem) {
        if item.suggestedLoad > 0 { return }
        if let first = item.plannedLoadsBySet.first(where: { $0 > 0 }) {
            item.suggestedLoad = first
        }
    }
    
    private func autoGeneratePerSetPlanForThisDay() {
            let isMaintenanceSession = session.meso?.name.lowercased().contains("maintenance") == true
            for item in orderedItems {
                if isMaintenanceSession {
                    let load = item.suggestedLoad
                    let setCount = item.targetSets
                    item.plannedLoadsBySet = Array(repeating: load, count: setCount)
                    item.plannedRepsBySet = Array(repeating: item.targetReps, count: setCount)
                    item.plannedRIRsBySet = Array(repeating: item.targetRIR, count: setCount)
                    continue
                }
                autoGeneratePerSetPlan(for: item, overwriteLoadsFromSuggested: false)
            }

        do {
            try modelContext.save()
            print("✅ Auto-generated per-set plan for this day")
            presentFeedback("Reset plan defaults to the stored prescription structure.")
        } catch {
            print("⚠️ Auto-generate save failed: \(error)")
            presentFeedback("Couldn’t reset plan defaults: \(error.localizedDescription)")
        }
    }

    private func autoGeneratePerSetPlan(for item: SessionItem, overwriteLoadsFromSuggested: Bool) {
        let isMaintenance = item.waveRaw?.lowercased() == "deload" &&
                    (item.prescriptionNotes?.lowercased().contains("maintenance") == true)
                let setCount = isMaintenance ? item.targetSets : max(4, item.targetSets)

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
        ensureIntArray(&item.plannedRIRsBySet)

        let firstPlannedNonZero = item.plannedLoadsBySet.first(where: { $0 > 0 }) ?? 0

        let baseLoad: Double
        if overwriteLoadsFromSuggested {
            baseLoad = item.suggestedLoad
        } else {
            baseLoad = item.suggestedLoad > 0 ? item.suggestedLoad : firstPlannedNonZero
        }

        let defaultRepTarget: Int = {
            if let repMin = item.repMin, repMin > 0 { return repMin }
            return item.targetReps
        }()

        let defaultRIRTarget = item.targetRIR

        let workingSetCount = min(item.targetSets, setCount)

        guard workingSetCount > 0 else { return }

        for idx in 0..<workingSetCount {
            item.plannedRepsBySet[idx] = defaultRepTarget

            if overwriteLoadsFromSuggested {
                item.plannedLoadsBySet[idx] = baseLoad
            } else if item.plannedLoadsBySet[idx] == 0, baseLoad > 0 {
                item.plannedLoadsBySet[idx] = baseLoad
            }

            item.plannedRIRsBySet[idx] = defaultRIRTarget
        }

        // Clear non-working extra rows in the editable 4-set UI tail
        if workingSetCount < setCount {
            for idx in workingSetCount..<setCount {
                if idx < item.plannedRepsBySet.count {
                    item.plannedRepsBySet[idx] = 0
                }
                if overwriteLoadsFromSuggested, idx < item.plannedLoadsBySet.count {
                    item.plannedLoadsBySet[idx] = 0
                }
                if idx < item.plannedRIRsBySet.count {
                    item.plannedRIRsBySet[idx] = defaultRIRTarget
                }
            }
        }
    }
    
    private func fillBlankPlannedLoadsFromSuggestedLoad(for item: SessionItem) {
        normalizePlanArrays(for: item)

        let baseLoad = item.suggestedLoad
        guard baseLoad > 0 else { return }

        let n = min(item.targetSets, item.plannedLoadsBySet.count)
        guard n > 0 else { return }

        for idx in 0..<n {
            if item.plannedLoadsBySet[idx] == 0 {
                item.plannedLoadsBySet[idx] = baseLoad
            }
        }
    }

    /// Ensures the plan arrays can safely be edited up to max(4, targetSets)
    private func normalizePlanArrays(for item: SessionItem) {
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
        ensureIntArray(&item.plannedRIRsBySet)
    }
    
    private func fetchRecentSessions(limit: Int) -> [Session] {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )

        do {
            let all = try modelContext.fetch(descriptor)

            // ✅ Source of truth: past sessions only.
            // A session might still be `.planned` even if you logged it.
            let now = Date()
            let past = all.filter { $0.date <= now && $0.status == .completed }

            return Array(past.prefix(limit))
        } catch {
            print("⚠️ Failed to fetch sessions: \(error)")
            return []
        }
    }



    // MARK: - Rep range + rule helpers





    // MARK: - Core load decision (history → next suggestedLoad)
 






    

    
    // MARK: - CRUD helpers

    private func renameDayLabel(to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        session.dayLabel = trimmed

        if propagateChangesToFutureSessions {
            let today = Calendar.current.startOfDay(for: Date())
            let targetWeekday = Calendar.current.component(.weekday, from: session.date)

            let descriptor = FetchDescriptor<Session>(
                predicate: #Predicate { s in s.date > today }
            )

            if let futureSessions = try? modelContext.fetch(descriptor) {
                let sameDay = futureSessions.filter {
                    $0.id != session.id &&
                    $0.status == .planned &&
                    Calendar.current.component(.weekday, from: $0.date) == targetWeekday
                }
                for future in sameDay {
                    future.dayLabel = trimmed
                }
            }
        }

        do {
            try modelContext.save()
            presentFeedback("Day renamed to \"\(trimmed)\".")
        } catch {
            print("⚠️ Failed to rename day: \(error)")
        }
    }

    private func addExercise(from catalog: CatalogExercise) {
        let nextOrder = (session.items.map { $0.order }.max() ?? 0) + 1

        // Maintenance sessions need the deload-style prescription so the coaching
        // engine recognizes the new item as a maintenance exercise (it gates on
        // waveRaw == "deload"). Without this, exercises added mid-block fall
        // through to normal progression coaching instead of the retention message.
        let isMaintenanceSession = session.meso?.name.lowercased().contains("maintenance") == true
        print("🔍 addExercise debug — session.meso name: \(session.meso?.name ?? "nil"), isMaintenanceSession: \(isMaintenanceSession)")

        let newItem: SessionItem
        let setCount: Int

        if isMaintenanceSession {
            setCount = 2
            newItem = SessionItem(
                order: nextOrder,
                exerciseId: catalog.id,
                exerciseNameSnapshot: catalog.name,
                targetReps: 10,
                targetSets: setCount,
                targetRIR: 3,
                suggestedLoad: 0,
                waveRaw: WaveType.deload.rawValue,
                priorityRaw: ExercisePriority.standard.rawValue,
                setMin: 2,
                setMax: 3,
                repMin: 8,
                repMax: 12,
                targetRIRMin: 3,
                targetRIRMax: 4,
                intensifierRaw: IntensifierType.none.rawValue,
                intensifierNotes: nil,
                prescriptionNotes: "Maintenance — hold loads, manage fatigue."
            )
        } else {
            setCount = 4
            newItem = SessionItem(
                order: nextOrder,
                exerciseId: catalog.id,
                exerciseNameSnapshot: catalog.name,
                targetReps: 10,
                targetSets: 3,
                targetRIR: 2,
                suggestedLoad: 0
            )
        }

        newItem.plannedRepsBySet       = Array(repeating: newItem.targetReps, count: setCount)
        newItem.plannedLoadsBySet      = Array(repeating: 0.0,               count: setCount)
        newItem.plannedRIRsBySet       = Array(repeating: newItem.targetRIR, count: setCount)
        newItem.actualReps             = Array(repeating: 0,                 count: setCount)
        newItem.actualLoads            = Array(repeating: 0.0,               count: setCount)
        newItem.actualRIRs             = Array(repeating: 0,                 count: setCount)
        newItem.usedRestPauseFlags     = Array(repeating: false,             count: setCount)
        newItem.restPausePatternsBySet = Array(repeating: "",                count: setCount)

        session.items.append(newItem)

        if propagateChangesToFutureSessions {
                    ProgramPlanPropagationService.applyPlanEditsForward(from: session, in: modelContext)
                }

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

        // ✅ NEW: propagate program edits forward into future planned sessions
        if propagateChangesToFutureSessions {
                    ProgramPlanPropagationService.applyPlanEditsForward(from: session, in: modelContext)
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

        // ✅ NEW: propagate program edits forward into future planned sessions
        ProgramPlanPropagationService.applyPlanEditsForward(from: session, in: modelContext)

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
    /// Copies PLAN fields only (sets / reps / RIR / suggested load / per-set plan / DUP prescription metadata)
    /// and does NOT touch logged Actuals.
    private func applyPlanChangesToBlock() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: session.date) // 1=Sun...7=Sat

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { s in
                s.date > today
            },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        do {
            let futureSessions = try modelContext.fetch(descriptor)

            let targets = futureSessions.filter { other in
                other.id != session.id &&
                other.status == .planned &&
                calendar.component(.weekday, from: other.date) == weekday
            }

            guard !targets.isEmpty else {
                print("ℹ️ No future planned sessions matched for applyPlanChangesToBlock.")
                presentFeedback("No future planned sessions matched this weekday.")
                return
            }

            let sourceItems = orderedItems

            for other in targets {
                let targetItemsSorted = other.items.sorted { $0.order < $1.order }

                // 1) Delete extras
                if targetItemsSorted.count > sourceItems.count {
                    for extra in targetItemsSorted[sourceItems.count...] {
                        modelContext.delete(extra)
                    }
                }

                // 2) Add missing
                if targetItemsSorted.count < sourceItems.count {
                    for idx in targetItemsSorted.count..<sourceItems.count {
                        let src = sourceItems[idx]

                        let newItem = SessionItem(
                            order: idx + 1,
                            exerciseId: src.exerciseId,
                            exerciseNameSnapshot: src.exerciseNameSnapshot,
                            targetReps: src.targetReps,
                            targetSets: src.targetSets,
                            targetRIR: src.targetRIR,
                            suggestedLoad: src.suggestedLoad,

                            waveRaw: src.waveRaw,
                            priorityRaw: src.priorityRaw,
                            setMin: src.setMin,
                            setMax: src.setMax,
                            repMin: src.repMin,
                            repMax: src.repMax,
                            targetRIRMin: src.targetRIRMin,
                            targetRIRMax: src.targetRIRMax,
                            intensifierRaw: src.intensifierRaw,
                            intensifierNotes: src.intensifierNotes,
                            prescriptionNotes: src.prescriptionNotes,

                            plannedRepsBySet: src.plannedRepsBySet,
                            plannedLoadsBySet: src.plannedLoadsBySet
                        )

                        other.items.append(newItem)
                    }
                }

                // 3) Align & copy by order
                let aligned = other.items.sorted { $0.order < $1.order }

                for (idx, src) in sourceItems.enumerated() {
                    guard idx < aligned.count else { continue }
                    let dst = aligned[idx]

                    dst.order = idx + 1
                    dst.exerciseId = src.exerciseId
                    dst.exerciseNameSnapshot = src.exerciseNameSnapshot

                    // Flattened execution defaults
                    dst.targetReps = src.targetReps
                    dst.targetSets = src.targetSets
                    dst.targetRIR = src.targetRIR
                    dst.suggestedLoad = src.suggestedLoad

                    // Rich DUP prescription metadata
                    dst.waveRaw = src.waveRaw
                    dst.priorityRaw = src.priorityRaw
                    dst.setMin = src.setMin
                    dst.setMax = src.setMax
                    dst.repMin = src.repMin
                    dst.repMax = src.repMax
                    dst.targetRIRMin = src.targetRIRMin
                    dst.targetRIRMax = src.targetRIRMax
                    dst.intensifierRaw = src.intensifierRaw
                    dst.intensifierNotes = src.intensifierNotes
                    dst.prescriptionNotes = src.prescriptionNotes

                    // Planned per-set editor state
                    dst.plannedRepsBySet = src.plannedRepsBySet
                    dst.plannedLoadsBySet = src.plannedLoadsBySet
                }
            }

            try modelContext.save()
            print("✅ Applied plan changes from \(session.date) to \(targets.count) future planned sessions.")
            presentFeedback("Applied plan changes to \(targets.count) future session\(targets.count == 1 ? "" : "s").")
        } catch {
            print("⚠️ Failed to apply plan changes to block: \(error)")
            presentFeedback("Couldn’t apply changes: \(error.localizedDescription)")
        }
    }
}
private struct HistoryTarget: Identifiable {
    let id = UUID()
    let exerciseId: String
    let exerciseName: String
}
private struct NoteTarget: Identifiable {
    let id = UUID()
    let exerciseId: String
    let exerciseName: String
}
// MARK: - Per-exercise plan row

private struct ProgramExercisePlanRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: SessionItem

    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    let onHistoryTapped: (_ exerciseId: String, _ exerciseName: String) -> Void
    let onNoteTapped: () -> Void
        var isMaintenance: Bool = false

    /// Local text versions of loads so 0.5 / 2.5 / 47.5 all work consistently.
    @State private var loadTexts: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            prescriptionSummaryRow
            planRow
            perSetPlanEditor
        }
        .padding(.vertical, 8)
        .onAppear {
            normalizeArraySizes()
            syncLoadTextsFromItem()
        }
        .onChange(of: item.targetSets) { _ in
            normalizeArraySizes()
            syncLoadTextsFromItem()
            save()
        }
        .onChange(of: item.plannedLoadsBySet) { _ in
            syncLoadTextsFromItem()
        }
        .onChange(of: item.plannedLoadsBySet) { _ in
            syncLoadTextsFromItem()
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(displayName)
                                    .font(.headline)

                                if let note = item.coachNote, note.hasPrefix("⚠️") {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else if let note = item.coachNote, note.hasPrefix("ℹ️") {
                                    Image(systemName: "info.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }

                            Text(detailLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let note = item.coachNote, !note.isEmpty {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(note.hasPrefix("⚠️") ? Color.red : Color.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let intensifierLine {
                                Text(intensifierLine)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    onHistoryTapped(item.exerciseId, displayName)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .padding(6)
                .background(Color.black.opacity(0.05))
                .clipShape(Circle())

                Button {
                    onNoteTapped()
                } label: {
                    Image(systemName: noteIconName)
                }
                .buttonStyle(.borderless)
                .padding(6)
                .background(Color.black.opacity(0.05))
                .clipShape(Circle())
                .accessibilityLabel("Exercise note")
                
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

    private var noteIconName: String {
        ExerciseNoteLookup.hasNote(exerciseId: item.exerciseId, in: modelContext) ? "note.text" : "note"
    }
    
    private var prescriptionSummaryRow: some View {
        HStack(spacing: 6) {
            Text("Range:")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(prescriptionSummaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var prescriptionSummaryText: String {
        let setsText: String = {
            if let min = item.setMin, let max = item.setMax {
                return min == max ? "\(min) sets" : "\(min)–\(max) sets"
            } else {
                return "\(item.targetSets) sets"
            }
        }()

        let repsText: String = {
            if let min = item.repMin, let max = item.repMax {
                return min == max ? "\(min) reps" : "\(min)–\(max) reps"
            } else {
                return "\(item.targetReps) reps"
            }
        }()

        let rirText: String = {
            if let min = item.targetRIRMin, let max = item.targetRIRMax {
                return min == max ? "\(min) RIR" : "\(min)–\(max) RIR"
            } else {
                return "\(item.targetRIR) RIR"
            }
        }()

        return "\(setsText) · \(repsText) · \(rirText)"
    }
    
    private var planRow: some View {
        HStack(alignment: .top, spacing: 12) {

            // Sets
            VStack(alignment: .leading, spacing: 4) {
                Text("Work sets")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(value: $item.targetSets, in: 1...6) {
                    Text("\(item.targetSets)")
                        .font(.body)
                        .monospacedDigit()
                        .frame(minWidth: 22, alignment: .leading)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Reps (clean option: show ONLY the editable number here)
            VStack(alignment: .leading, spacing: 4) {
                Text("Default reps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(value: $item.targetReps, in: 4...30, step: 1) {
                    Text("\(item.targetReps)")
                        .font(.body)
                        .monospacedDigit()
                        .frame(minWidth: 34, alignment: .leading) // prevents "1" of "12"
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // RIR
            VStack(alignment: .leading, spacing: 4) {
                Text("Default RIR")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(value: $item.targetRIR, in: 0...5) {
                    Text("\(item.targetRIR)")
                        .font(.body)
                        .monospacedDigit()
                        .frame(minWidth: 22, alignment: .leading)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    private var perSetPlanEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Per-set plan (load × reps @ RIR)")
                .font(.caption)
                .foregroundStyle(.secondary)

            let setRows = isMaintenance ? item.targetSets : max(4, item.targetSets)

                        ForEach(0..<setRows, id: \.self) { idx in
                HStack(spacing: 8) {
                    Text("Set \(idx + 1)")
                        .font(.caption2)
                        .frame(width: 40, alignment: .leading)

                    // LOAD – string-based so 0.5, 1.5, 47.5 all work
                    TextField("Load", text: loadTextBinding(at: idx))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .frame(width: 70)

                    // REPS
                    TextField("Reps", value: bindingForReps(at: idx), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(width: 60)

                    // RIR (per set override; blank = use targetRIR)
                    TextField("RIR", value: bindingForRIR(at: idx), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(width: 50)
                }
            }
        }
        // When base reps change, fill blanks for planned reps (include Set 4)
        .onChange(of: item.targetReps) { newValue in
            normalizeArraySizes()

            let workingSetCount = min(item.targetSets, item.plannedRepsBySet.count)

            for idx in 0..<workingSetCount {
                item.plannedRepsBySet[idx] = newValue
            }

            if workingSetCount < item.plannedRepsBySet.count {
                for idx in workingSetCount..<item.plannedRepsBySet.count {
                    item.plannedRepsBySet[idx] = 0
                }
            }

            save()
        }
        .onChange(of: item.targetRIR) { newValue in
            normalizeArraySizes()

            let setRows = max(4, item.targetSets)
            let limit = min(setRows, item.plannedRIRsBySet.count)

            for idx in 0..<limit {
                item.plannedRIRsBySet[idx] = newValue
            }

            save()
        }
    }

    // MARK: - Display helpers

    private var displayName: String {
        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)

        if let snapshot = item.exerciseNameSnapshot?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !snapshot.isEmpty {
            return snapshot
        }

        if let catalog = ExerciseCatalog.all.first(where: { $0.id == canonicalId }) {
            return catalog.name
        }

        return ExerciseCatalog.displayName(for: canonicalId)
    }

    private var detailLine: String {
        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)

        let muscle: String
        if let catalog = ExerciseCatalog.all.first(where: { $0.id == canonicalId }) {
            muscle = catalog.primaryMuscle.rawValue.capitalized
        } else {
            muscle = "—"
        }

        let setsText = "\(item.targetSets) sets"
        let repsText = "\(item.targetReps) reps"
        let rirText = "\(item.targetRIR) RIR"

        return "\(muscle) · \(setsText) · \(repsText) · \(rirText)"
    }

    private var intensifierLine: String? {
        guard
            let raw = item.intensifierRaw,
            let intensifier = IntensifierType(rawValue: raw),
            intensifier != .none
        else {
            return nil
        }

        if let notes = item.intensifierNotes,
           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return notes
        }

        switch intensifier {
        case .dropSetLast:
            return "Drop set on final set only."
        case .restPauseLast:
            return "Rest-pause on final set only."
        case .squeezePauseLast:
            return "Pause/squeeze on final set only."
        case .customNoteOnly:
            return "Special instruction applies."
        case .none:
            return nil
        }
    }
    
    // MARK: - Array helpers

    private func normalizeArraySizes() {
        // Ensure we always support at least 4 sets and whatever targetSets requires
        let minSets = 4
        let maxExisting = max(
            item.plannedRepsBySet.count,
            item.plannedLoadsBySet.count,
            item.actualReps.count,
            item.actualLoads.count,
            item.plannedRIRsBySet.count,
            item.actualRIRs.count,
            item.usedRestPauseFlags.count,
            item.restPausePatternsBySet.count,
            item.targetSets
        )

        let setCount = max(minSets, maxExisting)

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
        ensureIntArray(&item.plannedRIRsBySet)
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

    // MARK: - Load text state + bindings

    private func syncLoadTextsFromItem() {
        let setRows = isMaintenance ? item.targetSets : max(4, max(item.targetSets, item.plannedLoadsBySet.count))

        // Ensure local cache is the right size
        if loadTexts.count != setRows {
            loadTexts = Array(repeating: "", count: setRows)
        }

        // Always resync values (not just when count changes)
        for idx in 0..<setRows {
            let value = (idx < item.plannedLoadsBySet.count) ? item.plannedLoadsBySet[idx] : 0.0

            if value == 0 {
                loadTexts[idx] = ""
            } else if value.truncatingRemainder(dividingBy: 1) == 0 {
                loadTexts[idx] = String(format: "%.0f", value)
            } else {
                loadTexts[idx] = String(format: "%.1f", value)
            }
        }
    }

    private func loadTextBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                if index < loadTexts.count {
                    return loadTexts[index]
                } else {
                    return ""
                }
            },
            set: { newValue in
                // Ensure local array is big enough
                if index >= loadTexts.count {
                    let extra = index + 1 - loadTexts.count
                    loadTexts.append(contentsOf: repeatElement("", count: extra))
                }
                loadTexts[index] = newValue

                // Push into model
                normalizeArraySizes()

                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                let doubleValue = Double(trimmed) ?? 0

                if index >= item.plannedLoadsBySet.count {
                    let extra = index + 1 - item.plannedLoadsBySet.count
                    item.plannedLoadsBySet.append(contentsOf: repeatElement(0.0, count: extra))
                }

                item.plannedLoadsBySet[index] = doubleValue
                save()
            }
        )
    }

    // MARK: - Reps / RIR bindings

    private func bindingForReps(at index: Int) -> Binding<Int> {
        Binding(
            get: {
                guard index < item.plannedRepsBySet.count else { return 0 }
                return item.plannedRepsBySet[index]
            },
            set: { newValue in
                if index >= item.plannedRepsBySet.count {
                    let extra = index + 1 - item.plannedRepsBySet.count
                    item.plannedRepsBySet.append(contentsOf: repeatElement(0, count: extra))
                }

                item.plannedRepsBySet[index] = newValue
                save()
            }
        )
    }

    private func bindingForRIR(at index: Int) -> Binding<Int> {
        Binding(
            get: {
                guard index < item.plannedRIRsBySet.count else {
                    return item.targetRIR
                }

                let stored = item.plannedRIRsBySet[index]
                return stored == 0 ? item.targetRIR : stored
            },
            set: { newValue in
                if index >= item.plannedRIRsBySet.count {
                    let extra = index + 1 - item.plannedRIRsBySet.count
                    item.plannedRIRsBySet.append(contentsOf: repeatElement(0, count: extra))
                }

                item.plannedRIRsBySet[index] = newValue
                save()
            }
        )
    }

    // MARK: - Save

    private func save() {
        do {
            try modelContext.save()
        } catch {
            print("⚠️ Failed to save per-set plan changes: \(error)")
        }
    }
}

