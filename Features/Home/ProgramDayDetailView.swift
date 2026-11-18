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
    @State private var swapTarget: SwapTarget?
    @State private var changeTarget: ChangeTarget?
    @State private var propagateAddToFutureSessions: Bool = true
    @State private var showDayLabelEditor: Bool = false
    @State private var dayLabelDraft: String = ""
    /// Items waiting for the lifter to confirm their removal from this session's plan.
    @State private var pendingDelete: PendingDelete?
    @State private var pendingPropagation: ProgramPlanPropagationService.Preview?
    @State private var pendingBlockApply: ProgramPlanPropagationService.Preview?
    @State private var pendingRename: DayLabelRename.Plan?
    /// The last removal, restorable for a few seconds.
    @State private var undoDelete: UndoDelete?
    /// The last multi-session prescription change, restorable for 10 seconds.
    @State private var undoChange: UndoChange?

    // MARK: - Derived ordered items

    /// Session items sorted by their `order` field.
    /// This is the canonical order we want everywhere.
    private var orderedItems: [SessionItem] {
        session.items.sorted { $0.order < $1.order }
    }

    /// True when this session's block undulates by wave (DUP A/B/C).
    ///
    /// Meso-wide propagation copies the whole prescription across sessions of the
    /// same day type, which on a wave-based block overwrites the B and C weeks
    /// with the A week's numbers. On such a block propagation is forced off.
    private var isWaveBasedBlock: Bool {
        WavePrescriptionGuard.isWaveBasedBlock(session)
    }

    /// Whether a structural edit here is offered to the later sessions of this day type (always asked first, with the count).
    /// Never on a wave-based block: copying the prescription would flatten its B and C weeks into this week's.
    private var propagatesToFutureSessions: Bool { !isWaveBasedBlock }

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
                            onDelete:  { requestDelete([item], propagate: true) },
                            onSwapTapped: { swapTarget = SwapTarget(item: item) },
                            onChangePrescriptionTapped: { scope in changeTarget = ChangeTarget(item: item, scope: scope) },
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
                    .onDelete { offsets in requestDelete(offsets.map { orderedItems[$0] }, propagate: false) }
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
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }   // drag to reorder
        .confirmationDialog(
            "Remove exercise?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { p in
            Button("Remove", role: .destructive) { performDelete(p) }
            Button("Cancel", role: .cancel) { }
        } message: { p in
            Text(deleteMessage(p))
        }
        .overlay(alignment: .bottom) {
            if let u = undoDelete {
                HStack {
                    Text(u.label).font(.subheadline)
                    Spacer()
                    Button("Undo") { restore(u) }.fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: u.id) {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if undoDelete?.id == u.id { undoDelete = nil }
                }
            }
        }
        .animation(.default, value: undoDelete?.id)
        .overlay(alignment: .bottom) {
            if let u = undoChange {
                HStack {
                    Text(u.label).font(.subheadline)
                    Spacer()
                    Button("Undo") { undoPrescriptionChange(u) }.fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: u.id) {
                    try? await Task.sleep(nanoseconds: UndoChange.visibleNanoseconds)
                    if undoChange?.id == u.id { undoChange = nil }
                }
            }
        }
        .animation(.default, value: undoChange?.id)
        
        
        .alert("Apply to this block?", isPresented: Binding(get: { pendingBlockApply != nil }, set: { if !$0 { pendingBlockApply = nil } })) {
            Button("Apply") { confirmBlockApply() }
            Button("Not now", role: .cancel) { pendingBlockApply = nil }
        } message: {
            Text(Self.propagationMessage(pendingBlockApply))
        }
        .alert("Rename this day?", isPresented: Binding(get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } })) {
            Button("Rename") { confirmRename() }
            Button("Cancel", role: .cancel) { pendingRename = nil }
        } message: {
            Text(pendingRename.map(Self.renameMessage) ?? "")
        }
        .alert("Apply to future sessions?", isPresented: Binding(get: { pendingPropagation != nil }, set: { if !$0 { pendingPropagation = nil } })) {
            Button("Apply") { confirmPropagation() }
            Button("Not now", role: .cancel) { pendingPropagation = nil }
        } message: {
            Text(Self.propagationMessage(pendingPropagation))
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
            Text("This name is used by every session of this day in this block, past and future. You will see the count before it is applied.")
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
        .sheet(item: $changeTarget) { target in
            ChangePrescriptionFlow(
                session: session,
                item: target.item,
                onApplied: { undo, summary in undoChange = UndoChange(undo: undo, label: summary) },
                onFinish: { changeTarget = nil }
            )
        }
        .sheet(item: $swapTarget) { target in
            ReplaceExerciseFlow(
                session: session,
                item: target.item,
                surface: .programTab,
                onFinish: { swapTarget = nil }
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

                                if isWaveBasedBlock {
                                    Text("Changes apply to this session only for wave-based programs.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
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

    // MARK: - CRUD helpers

    /// Asks first: the rename covers every planned, in-progress and completed session of this day type in this block.
    private func renameDayLabel(to newLabel: String) {
        switch DayLabelRename.plan(renaming: session, to: newLabel) {
        case .success(let plan): pendingRename = plan
        case .failure(.emptyLabel), .failure(.unchanged): return
        case .failure(.collidesWithAnotherDay(let name)):
            presentFeedback("Another day in this block is already called \"\(name)\". Pick a different name.")
        }
    }

    static func renameMessage(_ p: DayLabelRename.Plan) -> String {
        let n = p.sessionCount
        var parts: [String] = []
        if p.planned > 0 { parts.append("\(p.planned) planned") }
        if p.other > 0 { parts.append("\(p.other) in progress") }
        if p.completed > 0 { parts.append("\(p.completed) completed") }
        return "\"\(p.oldLabel)\" becomes \"\(p.newLabel)\" on \(n) session\(n == 1 ? "" : "s") in this block (\(parts.joined(separator: ", "))). Other blocks are not changed."
    }

    private func confirmRename() {
        guard let plan = pendingRename else { return }
        pendingRename = nil
        do {
            try DayLabelRename.apply(renaming: session, to: plan.newLabel, in: modelContext)
            presentFeedback("Day renamed to \"\(plan.newLabel)\" on \(plan.sessionCount) sessions.")
        } catch {
            print("⚠️ Failed to rename day: \(error)")
            presentFeedback("Couldn’t rename the day. Nothing was changed.")
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
        newItem.actualRIRs             = RIREntry.unsetArray(count: setCount)
        newItem.usedRestPauseFlags     = Array(repeating: false,             count: setCount)
        newItem.restPausePatternsBySet = Array(repeating: "",                count: setCount)

        session.items.append(newItem)

        if propagatesToFutureSessions {
                    requestPropagation()
                }

        do {
            try modelContext.save()
        } catch {
            print("⚠️ Failed to add exercise: \(error)")
        }
    }


    // MARK: - Propagation (always confirmed)

    static func propagationMessage(_ p: ProgramPlanPropagationService.Preview?) -> String {
        guard let p else { return "" }
        var text = "\(p.sessionsToChange) future planned session\(p.sessionsToChange == 1 ? "" : "s") of this day type in this block will change."
        if p.editedItemsSkipped > 0 {
            text += " \(p.editedItemsSkipped) exercise\(p.editedItemsSkipped == 1 ? "" : "s") you edited by hand on \(p.sessionsWithSkippedItems) of them will be left as they are."
        }
        return text
    }

    /// Asks before copying this session's plan forward; does nothing when no session would change.
    private func requestPropagation() {
        let preview = ProgramPlanPropagationService.preview(from: session, in: modelContext)
        guard preview.sessionsToChange > 0 else { return }
        pendingPropagation = preview
    }

    private func confirmPropagation() {
        pendingPropagation = nil
        ProgramPlanPropagationService.applyPlanEditsForward(from: session, in: modelContext)
        do { try modelContext.save() } catch { print("⚠️ Failed to apply plan to future sessions: \(error)") }
    }

    // MARK: - Removing items (confirmed, with undo)

    struct PendingDelete: Identifiable {
        let id = UUID()
        let items: [SessionItem]
        let propagate: Bool
    }

    struct UndoChange: Identifiable {
        let id = UUID()
        let undo: SessionItemEditService.PrescriptionUndo
        let label: String
        static let visibleNanoseconds: UInt64 = 10_000_000_000
    }

    /// Puts back exactly the fields the change wrote, on exactly the items it changed.
    private func undoPrescriptionChange(_ u: UndoChange) {
        undoChange = nil
        switch Result(catching: { try SessionItemEditService.undoPrescriptionChange(u.undo, in: modelContext) }) {
        case .success(let n): presentFeedback("Undone: \(n) session\(n == 1 ? "" : "s") back as they were.")
        case .failure: presentFeedback("The change couldn't be undone, so nothing was written.")
        }
    }

    struct UndoDelete: Identifiable {
        let id = UUID()
        let entries: [(item: SessionItem, order: Int)]
        let label: String
        let propagate: Bool
    }

    private func itemName(_ item: SessionItem) -> String {
        ExerciseCatalog.displayName(for: ExerciseCatalog.canonicalExerciseId(for: item.exerciseId))
    }

    private var sessionTitle: String {
        let day = session.dayLabel?.trimmingCharacters(in: .whitespaces).nonEmpty
        let date = session.date.formatted(date: .abbreviated, time: .omitted)
        return day.map { "\($0), \(date)" } ?? date
    }

    private func requestDelete(_ items: [SessionItem], propagate: Bool) {
        guard !items.isEmpty else { return }
        pendingDelete = PendingDelete(items: items, propagate: propagate)
    }

    private func deleteMessage(_ p: PendingDelete) -> String {
        let names = p.items.map(itemName).joined(separator: ", ")
        var text = "Remove \(names) from \(sessionTitle)? Its plan for this session is lost. Logged history is not affected."
        if p.propagate && propagatesToFutureSessions { text += " It is also removed from future planned sessions." }
        return text
    }

    private func performDelete(_ p: PendingDelete) {
        var entries: [(item: SessionItem, order: Int)] = []
        for item in p.items {
            guard let index = session.items.firstIndex(where: { $0.id == item.id }) else { continue }
            let removedOrder = session.items[index].order
            entries.append((item, removedOrder))
            session.items.remove(at: index)
            // Re-normalize order so it stays contiguous
            for sessionItem in session.items where sessionItem.order > removedOrder { sessionItem.order -= 1 }
        }
        guard !entries.isEmpty else { return }
        if p.propagate && propagatesToFutureSessions {
            requestPropagation()
        }
        do { try modelContext.save() } catch { print("⚠️ Failed to delete exercise: \(error)") }
        let label = entries.count == 1 ? "Removed \(itemName(entries[0].item))" : "Removed \(entries.count) exercises"
        undoDelete = UndoDelete(entries: entries, label: label, propagate: p.propagate)
    }

    /// Puts the removed items back with their slot (order, prescription, wave letter, edited loads: the objects are intact).
    private func restore(_ u: UndoDelete) {
        for entry in u.entries.sorted(by: { $0.order < $1.order }) {
            for other in session.items where other.order >= entry.order { other.order += 1 }
            entry.item.order = entry.order
            session.items.append(entry.item)
        }
        if u.propagate && propagatesToFutureSessions {
            requestPropagation()
        }
        do { try modelContext.save() } catch { print("⚠️ Failed to restore exercise: \(error)") }
        undoDelete = nil
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

    // MARK: - Apply to Block

    /// Copies this day's plan onto the other future planned sessions of the same day type IN THIS BLOCK, after a confirmation
    /// that shows the count and how many hand-edited exercises are left alone. (No button calls this yet.)
    private func applyPlanChangesToBlock() {
        guard !isWaveBasedBlock else {
            presentFeedback("Changes apply to this session only for wave-based programs.")
            return
        }
        let preview = ProgramPlanPropagationService.blockPreview(from: session, in: modelContext)
        guard preview.sessionsToChange > 0 else {
            presentFeedback("No future planned sessions of this day in this block.")
            return
        }
        pendingBlockApply = preview
    }

    private func confirmBlockApply() {
        pendingBlockApply = nil
        let result = ProgramPlanPropagationService.applyToBlock(from: session, in: modelContext)
        do {
            try modelContext.save()
            var text = "Applied plan changes to \(result.sessionsToChange) future session\(result.sessionsToChange == 1 ? "" : "s")."
            if result.editedItemsSkipped > 0 { text += " \(result.editedItemsSkipped) exercise\(result.editedItemsSkipped == 1 ? "" : "s") you edited by hand were left as they are." }
            presentFeedback(text)
        } catch {
            modelContext.rollback()
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
private struct ChangeTarget: Identifiable {
    let id = UUID()
    let item: SessionItem
    let scope: ReplaceScopeChoice
}
private struct SwapTarget: Identifiable {
    let id = UUID()
    let item: SessionItem
}

// MARK: - Swap Sheet

/// Sheet to pick a replacement exercise from the catalog for a plan slot.
/// Shows "recommended" (same primary muscle group) first, then all others.
/// Intentionally separate from SessionView's ExerciseSwapSheet, which is
/// private and typed to that screen's UISessionExercise view-model.
struct ProgramExerciseSwapSheet: View {
    let currentExerciseId: String
    let currentExerciseName: String
    let onSelect: (CatalogExercise) -> Void
    let onCancel: () -> Void

    @State private var showingCreateCustom = false

    private var options: [CatalogExercise] {
        let all = ExerciseCatalog.all
        let canonicalId = ExerciseCatalog.canonicalExerciseId(for: currentExerciseId)

        guard let currentCatalog = all.first(where: { $0.id == canonicalId }) else {
            return all
        }

        let same = all.filter { $0.primaryMuscle == currentCatalog.primaryMuscle }
        let others = all.filter {
            $0.id != currentCatalog.id && $0.primaryMuscle != currentCatalog.primaryMuscle
        }

        return same + others
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingCreateCustom = true
                    } label: {
                        Label("Create Custom Exercise", systemImage: "plus.circle.fill")
                    }
                }

                Section {
                    ForEach(options) { exercise in
                        Button {
                            onSelect(exercise)
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
                } header: {
                    Text("Choose a replacement for \(currentExerciseName)")
                }
            }
            .navigationTitle("Swap Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
            .sheet(isPresented: $showingCreateCustom) {
                CreateCustomExerciseSheet(
                    onDone: { newExercise in
                        showingCreateCustom = false
                        onSelect(newExercise)
                    },
                    onCancel: { showingCreateCustom = false }
                )
            }
        }
    }
}

// MARK: - Per-exercise plan row

private struct ProgramExercisePlanRow: View {
    @Environment(\.loadUnit) private var unit
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: SessionItem

    let onDelete: () -> Void
    let onSwapTapped: () -> Void
    let onChangePrescriptionTapped: (_ scope: ReplaceScopeChoice) -> Void
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
            Button {
                onChangePrescriptionTapped(.allRemaining)
            } label: {
                Label("Change for remaining sessions", systemImage: "slider.horizontal.3")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            perSetPlanEditor
        }
        .padding(.vertical, 8)
        .onAppear {
            normalizeArraySizes()
            syncLoadTextsFromItem()
        }
        .onChange(of: unit) { _ in
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

                                if let note = CoachNoteHygiene.visibleNote(of: item, unit: unit), note.hasPrefix("⚠️") {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else if let note = CoachNoteHygiene.visibleNote(of: item, unit: unit), note.hasPrefix("ℹ️") {
                                    Image(systemName: "info.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }

                            Text(detailLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let note = CoachNoteHygiene.visibleNote(of: item, unit: unit) {
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
                
                Button(action: onSwapTapped) {
                    Image(systemName: "arrow.triangle.2.circlepath")
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
                return min == max ? "\(min) reps" : "\(min)–\(max) · goal \(max) reps"
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
    
    private var repsRangeText: String {
        let v = SessionItemEditService.PrescriptionValues(item)
        return v.repMin == v.repMax ? "\(v.repMin)" : "\(v.repMin)–\(v.repMax)"
    }

    private var planRow: some View {
        HStack(alignment: .top, spacing: 12) {

            // Sets
            VStack(alignment: .leading, spacing: 4) {
                Text("Work sets")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(value: Binding(get: { item.targetSets }, set: { PlanStepperEdits.setSets(item, to: $0) }), in: 1...6) {
                    Text("\(item.targetSets)")
                        .font(.body)
                        .monospacedDigit()
                        .frame(minWidth: 22, alignment: .leading)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Reps: the rep range is what coaching reads, so it is edited through the change flow
            // (scoped to this session), not a stepper on the flattened default.
            VStack(alignment: .leading, spacing: 4) {
                Text("Reps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    onChangePrescriptionTapped(.thisSession)
                } label: {
                    HStack(spacing: 4) {
                        Text(repsRangeText)
                            .font(.body)
                            .monospacedDigit()
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // RIR
            VStack(alignment: .leading, spacing: 4) {
                Text("Default RIR")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(value: Binding(get: { item.targetRIR }, set: { PlanStepperEdits.setRIR(item, to: $0) }), in: 0...5) {
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

            // Exactly the planned work sets (+ top rows). The spare fourth row Today offers as an optional extra set is not
            // a planned set and is not shown here.
            let setRows = item.targetSets + item.topCount
            // Top rows first (storage keeps them at the tail), then the back-offs.
            let rowOrder = item.topRowIndices.filter { $0 < setRows } + (0..<setRows).filter { !item.isTopRow($0) }

                        ForEach(rowOrder, id: \.self) { idx in
                HStack(spacing: 8) {
                    Text(item.isTopRow(idx) ? "Top" : "Set \(idx + 1)")
                        .font(.caption2)
                        .fontWeight(item.isTopRow(idx) ? .semibold : .regular)
                        .foregroundStyle(item.isTopRow(idx) ? Color.orange : Color.primary)
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
                for idx in workingSetCount..<item.plannedRepsBySet.count where !item.isTopRow(idx) {
                    item.plannedRepsBySet[idx] = 0
                }
            }

            save()
        }
        .onChange(of: item.targetRIR) { newValue in
            normalizeArraySizes()

            let setRows = max(4, item.targetSets)
            let limit = min(setRows, item.plannedRIRsBySet.count)

            for idx in 0..<limit where !item.isTopRow(idx) {
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
        // The reps shown are the per-set plan's (what the per-set editor below and Today use), not the flattened default.
        let repsText = ProgramDayDetailView.planRepsText(for: item)
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
        if var roles = item.setRolesBySet, roles.count < setCount {
            roles.append(contentsOf: repeatElement("", count: setCount - roles.count))
            item.setRolesBySet = roles
        }
        ensureIntArray(&item.actualReps)
        ensureDoubleArray(&item.actualLoads)
        RIREntry.resize(item, to: setCount)

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
            } else {
                loadTexts[idx] = LoadFormatter(unit: unit).compact(value)
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
                let current: Double? = index < item.plannedLoadsBySet.count ? item.plannedLoadsBySet[index] : nil
                // nil = the text a stored load already shows (a kg lifter's 102.5 lb reads "46.49"): nothing to
                // write, so the load keeps its exact value and planEdited stays as it was.
                guard let doubleValue = LoadInput.plannedLoadWrite(trimmed, unit: unit, current: current) else { return }

                // The one plan edit that sets planEdited: a hand-set load must not be overwritten.
                PlanStepperEdits.setPlannedLoad(item, at: index, to: doubleValue)
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
                PlanStepperEdits.setPlannedReps(item, at: index, to: newValue)
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
                PlanStepperEdits.setPlannedRIR(item, at: index, to: newValue)
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


extension ProgramDayDetailView {
    /// "8 reps" when every work set plans the same reps, "6–8 reps" when they differ; the flattened default only when the
    /// per-set plan is empty.
    static func planRepsText(for item: SessionItem) -> String {
        let planned = item.backOffValues(item.plannedRepsBySet).prefix(max(1, item.targetSets)).filter { $0 > 0 }
        guard let lo = planned.min(), let hi = planned.max() else { return "\(item.targetReps) reps" }
        return lo == hi ? "\(lo) reps" : "\(lo)–\(hi) reps"
    }
}
