import SwiftUI
import SwiftData

// MARK: - Plan steppers

/// What the Program tab's plan editors write. ANY lifter edit to a planned LOAD, REPS or RIR marks the item
/// `planEdited`, which freezes carry-forward's earned-load write into it (carry-forward itself only ever writes
/// loads, never reps or RIR, but a hand-set target of any kind is the lifter's, not the engine's). So does the set
/// COUNT stepper: a lifter-chosen number of sets is a hand-set target too.
enum PlanStepperEdits {


    /// Work-set stepper: this session's set count. The wave's set band (`setMin`/`setMax`) widens to
    /// include it and never narrows, so the "3–4 sets" label cannot exclude the real count.
    static func setSets(_ item: SessionItem, to value: Int) {
        item.planEdited = true
        if item.hasTopSet {
            item.resizeBackOffs(to: value)   // the top tail and the roles move with the back-off count
        } else {
            item.setPrescribedSets(value)
        }
        widenSetBand(item, toInclude: value)
    }

    /// RIR stepper: the lifter picked one number, so the displayed range collapses to it as well. A hand-set RIR.
    static func setRIR(_ item: SessionItem, to value: Int) {
        item.targetRIR = value
        item.targetRIRMin = value
        item.targetRIRMax = value
        item.planEdited = true
    }

    /// `setMin = min(setMin, sets)`, `setMax = max(setMax, sets)`; untouched when the item has no band.
    static func widenSetBand(_ item: SessionItem, toInclude sets: Int) {
        if let lo = item.setMin { item.setMin = min(lo, sets) }
        if let hi = item.setMax { item.setMax = max(hi, sets) }
    }

    /// Per-set load field: marks the plan as hand-set.
    static func setPlannedLoad(_ item: SessionItem, at index: Int, to value: Double) {
        if index >= item.plannedLoadsBySet.count {
            item.plannedLoadsBySet.append(contentsOf: repeatElement(0.0, count: index + 1 - item.plannedLoadsBySet.count))
        }
        item.plannedLoadsBySet[index] = value
        item.planEdited = true
    }

    /// Per-set reps field: marks the plan as hand-set.
    static func setPlannedReps(_ item: SessionItem, at index: Int, to value: Int) {
        if index >= item.plannedRepsBySet.count {
            item.plannedRepsBySet.append(contentsOf: repeatElement(0, count: index + 1 - item.plannedRepsBySet.count))
        }
        item.plannedRepsBySet[index] = value
        item.planEdited = true
    }

    /// Per-set RIR field: marks the plan as hand-set.
    static func setPlannedRIR(_ item: SessionItem, at index: Int, to value: Int) {
        if index >= item.plannedRIRsBySet.count {
            item.plannedRIRsBySet.append(contentsOf: repeatElement(0, count: index + 1 - item.plannedRIRsBySet.count))
        }
        item.plannedRIRsBySet[index] = value
        item.planEdited = true
    }
}

// MARK: - Model (no SwiftUI; the preview and the write both come from SessionItemEditService)

struct ChangePrescriptionModel {

    static let unchangedFooter = "Unchanged: loads, planned values, logged data, completed sessions, other exercises."

    let session: Session
    let item: SessionItem
    let context: ModelContext
    var now: Date = Date()

    var scope: ReplaceScopeChoice
    /// nil = every wave letter.
    var letter: String?
    var setDelta = 0                  // -1, 0, +1
    var changeReps = false
    var repLow: Int, repHigh: Int
    var changeRIR = false
    var rirLow: Int, rirHigh: Int
    /// The note under the exercise: text replaces it, "Clear note" removes it, both empty leaves it alone.
    var noteText = ""
    var clearNote = false

    enum TopSetMode: Hashable { case noChange, set, remove }
    /// Add (or update) a top set, or remove it. The back-off rows are never touched by it.
    var topMode: TopSetMode = .noChange
    var topLow = 4, topHigh = 6, topRIR = 2

    init(session: Session, item: SessionItem, context: ModelContext, scope: ReplaceScopeChoice, now: Date = Date()) {
        self.session = session; self.item = item; self.context = context; self.scope = scope; self.now = now
        let current = SessionItemEditService.PrescriptionValues(item)
        repLow = current.repMin; repHigh = current.repMax
        rirLow = current.rirMin; rirHigh = current.rirMax
        if let top = current.top { topLow = top.repMin; topHigh = top.repMax; topRIR = top.rir }
    }

    var itemHasTopSet: Bool { item.hasTopSet }

    /// "Add top set: 1 x 4-6 @ 2" / "Update top set: …"
    var topSetTitle: String {
        let reps = topLow == max(topLow, topHigh) ? "\(topLow)" : "\(topLow)-\(max(topLow, topHigh))"
        return "\(itemHasTopSet ? "Update" : "Add") top set: 1 x \(reps) @ \(topRIR)"
    }

    var dayLabel: String? { session.dayLabel }

    /// Letters only mean something on a wave-based block; non-wave programs have none to pick.
    var showsLetters: Bool { WavePrescriptionGuard.isWaveBasedBlock(session) }

    /// The wave letters this exercise has across the block's day type (deload is not offered).
    var availableLetters: [String] {
        guard let meso = session.meso else { return [] }
        let exercise = ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)
        var seen = Set<String>()
        for s in meso.sessions where SessionDayLabelMatcher.matches(s.dayLabel, session.dayLabel) {
            for i in s.items where ExerciseCatalog.canonicalExerciseId(for: i.exerciseId) == exercise {
                let key = i.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                if !key.isEmpty && key != "deload" { seen.insert(key) }
            }
        }
        return seen.sorted()
    }

    var change: PrescriptionChange {
        PrescriptionChange(
            setDelta: setDelta == 0 ? nil : setDelta,
            repRange: changeReps ? repLow...max(repLow, repHigh) : nil,
            rirRange: changeRIR ? rirLow...max(rirLow, rirHigh) : nil,
            note: clearNote ? "" : (noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : noteText),
            topSet: {
                switch topMode {
                case .noChange: return nil
                case .remove: return .remove
                case .set: return .set(TopSetSpec(count: 1, repMin: topLow, repMax: max(topLow, topHigh), rir: topRIR))
                }
            }()
        )
    }

    func plan(scope override: ReplaceScopeChoice? = nil) -> SessionItemEditService.ChangePlan? {
        guard let meso = session.meso else { return nil }
        let chosen = override ?? scope
        let serviceScope: SessionItemEditService.ReplaceScope = chosen == .thisSession ? .thisSession(session) : .allRemaining
        let letters: Set<String>? = (showsLetters && chosen == .allRemaining) ? letter.map { [$0] } : nil
        return SessionItemEditService.planChangePrescription(
            meso: meso, dayLabel: session.dayLabel, exerciseId: item.exerciseId, letters: letters,
            includeDeload: false, scope: serviceScope, change: change, now: now
        )
    }

    // MARK: Copy

    func title(for choice: ReplaceScopeChoice) -> String {
        switch choice {
        case .thisSession: return "This session only"
        case .allRemaining:
            let n = plan(scope: .allRemaining)?.targets.count ?? 0
            return "All remaining \(dayLabel ?? "") sessions (\(n))"
        }
    }

    static func confirmTitle(count: Int) -> String { "Apply to \(count)" }

    struct Row: Equatable {
        let date: Date
        let wave: String
        let before: String
        let after: String
        /// "Note: "old" -> "new"" when the change carries a note.
        var note: String? = nil
    }

    /// A note shortened for the preview; empty reads "none".
    static func shortNote(_ text: String?, limit: Int = 36) -> String {
        guard let text, !text.isEmpty else { return "none" }
        return text.count <= limit ? "\"\(text)\"" : "\"\(text.prefix(limit))…\""
    }

    static func rows(_ plan: SessionItemEditService.ChangePlan) -> [Row] {
        plan.targets.map {
            Row(date: $0.date, wave: ReplaceExerciseModel.letter($0.waveRaw), before: $0.before.text, after: $0.after.text,
                note: !$0.changesNote ? nil : "Note: \(shortNote($0.beforeNote)) -> \(shortNote($0.afterNote))")
        }
    }

    func apply(_ plan: SessionItemEditService.ChangePlan) -> Result<SessionItemEditService.ApplyResult, ReplaceExerciseModel.ApplyFailure> {
        do {
            return .success(try SessionItemEditService.applyChange(plan, in: context))
        } catch let error as SessionItemEditService.ReplaceError {
            return .failure(.init(error: error))
        } catch {
            return .failure(.init(error: .saveFailed("\(error)")))
        }
    }
}

// MARK: - Views

/// "Change for remaining sessions": letters, sets, rep range, RIR range, a preview from the plan, then apply.
struct ChangePrescriptionFlow: View {
    @Environment(\.modelContext) private var modelContext

    let session: Session
    let item: SessionItem
    let initialScope: ReplaceScopeChoice
    let onFinish: () -> Void

    @State private var model: ChangePrescriptionModel?

    var body: some View {
        Group {
            if let binding = Binding($model) {
                ChangePrescriptionForm(model: binding, onFinish: onFinish)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil {
                model = ChangePrescriptionModel(session: session, item: item, context: modelContext, scope: initialScope)
            }
        }
    }
}

private struct ChangePrescriptionForm: View {
    @Binding var model: ChangePrescriptionModel
    let onFinish: () -> Void
    @State private var errorMessage: String?

    private var plan: SessionItemEditService.ChangePlan? { model.plan() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scope", selection: $model.scope) {
                        Text("This session").tag(ReplaceScopeChoice.thisSession)
                        Text("Remaining").tag(ReplaceScopeChoice.allRemaining)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(ExerciseCatalog.displayName(for: ExerciseCatalog.canonicalExerciseId(for: model.item.exerciseId)))
                } footer: {
                    Text(model.title(for: model.scope))
                }

                if model.showsLetters && model.scope == .allRemaining {
                    Section("Waves") {
                        Picker("Waves", selection: $model.letter) {
                            Text("All").tag(String?.none)
                            ForEach(model.availableLetters, id: \.self) { l in
                                Text(l.uppercased()).tag(String?.some(l))
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Sets") {
                    Picker("Sets", selection: $model.setDelta) {
                        Text("−1").tag(-1)
                        Text("No change").tag(0)
                        Text("+1").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Reps") {
                    Toggle("Change rep range", isOn: $model.changeReps)
                    if model.changeReps {
                        Stepper("Min \(model.repLow)", value: $model.repLow, in: PrescriptionChange.repBounds)
                        Stepper("Max \(max(model.repLow, model.repHigh))", value: $model.repHigh, in: PrescriptionChange.repBounds)
                    }
                }

                Section("RIR") {
                    Toggle("Change RIR range", isOn: $model.changeRIR)
                    if model.changeRIR {
                        Stepper("Min \(model.rirLow)", value: $model.rirLow, in: PrescriptionChange.rirBounds)
                        Stepper("Max \(max(model.rirLow, model.rirHigh))", value: $model.rirHigh, in: PrescriptionChange.rirBounds)
                    }
                }

                Section {
                    Picker("Top set", selection: $model.topMode) {
                        Text("No change").tag(ChangePrescriptionModel.TopSetMode.noChange)
                        Text(model.itemHasTopSet ? "Update" : "Add").tag(ChangePrescriptionModel.TopSetMode.set)
                        if model.itemHasTopSet { Text("Remove").tag(ChangePrescriptionModel.TopSetMode.remove) }
                    }
                    .pickerStyle(.segmented)
                    if model.topMode == .set {
                        Stepper("Min \(model.topLow)", value: $model.topLow, in: PrescriptionChange.repBounds)
                        Stepper("Max \(max(model.topLow, model.topHigh))", value: $model.topHigh, in: PrescriptionChange.repBounds)
                        Stepper("RIR \(model.topRIR)", value: $model.topRIR, in: PrescriptionChange.rirBounds)
                    }
                } header: {
                    Text("Top set")
                } footer: {
                    Text(model.topMode == .set
                         ? "\(model.topSetTitle) — one heavy set logged in addition to the back-off sets, shown first. Its load starts from your history."
                         : "A top set is one heavy set in addition to the back-off sets above.")
                }

                Section {
                    TextField("Note shown under the exercise", text: $model.noteText, axis: .vertical)
                        .lineLimit(1...3)
                        .disabled(model.clearNote)
                    Toggle("Clear note", isOn: $model.clearNote)
                } header: {
                    Text("Note")
                } footer: {
                    Text("Replaces the line shown under the exercise name in the sessions above. Leave empty to keep it.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
                }

                if let plan {
                    Section("Preview") {
                        if plan.targets.isEmpty {
                            Text(model.change.isValid ? "Nothing to change in this scope." : "Choose a change above.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(ChangePrescriptionModel.rows(plan).enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    Text(row.wave)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                                if row.before != row.after {
                                    Text("\(row.before)  →  \(row.after)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let note = row.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    let skipped = plan.refusals
                    if !skipped.isEmpty {
                        Section(plan.editedSkipped > 0 ? "Skipped (\(plan.editedSkipped) edited by you)" : "Skipped") {
                            ForEach(Array(skipped.enumerated()), id: \.offset) { _, r in
                                HStack {
                                    Text(r.session.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    Spacer()
                                    Text(ReplaceExerciseModel.reasonText(r.reason)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section { Text("This session isn't part of a block.").foregroundStyle(.secondary) }
                }

                Section { } footer: { Text(ChangePrescriptionModel.unchangedFooter) }
            }
            .navigationTitle("Change Prescription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    confirm()
                } label: {
                    Text(ChangePrescriptionModel.confirmTitle(count: plan?.targets.count ?? 0)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!(plan?.isApplicable ?? false))
                .padding()
                .background(.bar)
            }
        }
    }

    private func confirm() {
        guard let plan else { return }
        switch model.apply(plan) {
        case .success: onFinish()
        case .failure(let failure): errorMessage = failure.message
        }
    }
}
