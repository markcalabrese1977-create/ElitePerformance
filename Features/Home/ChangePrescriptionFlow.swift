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

/// How far a prescription change reaches. "This session only" is the default; the other two touch several sessions
/// and are confirmed, backed up and undoable.
enum PrescriptionScope: Hashable {
    case thisSession
    /// The same wave letter, every remaining session of this day in the block (waved blocks only).
    case weekType
    /// Every wave letter (or a block without waves), every remaining session of this day.
    case everyRemaining

    var title: String {
        switch self {
        case .thisSession: return "This session only"
        case .weekType: return "This week type, rest of block"
        case .everyRemaining: return "Every remaining session"
        }
    }
}

/// The words a multi-session confirmation uses: which wave letters and which weeks.
enum MultiSessionCopy {

    /// "C weeks, weeks 9 and 12" on a waved block, "weeks 2-6" without waves.
    static func scopeSummary(waves: [String?], weeks: [Int]) -> String {
        let letters = Set(waves.compactMap { raw -> String? in
            let w = raw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return w.isEmpty ? nil : w
        }).sorted().map { $0 == "deload" ? "Deload" : $0.uppercased() }
        let weekText = weeksText(Array(Set(weeks)).sorted())
        guard !letters.isEmpty else { return weekText }
        return "\(joined(letters)) weeks, \(weekText)"
    }

    static func joined(_ words: [String]) -> String {
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        default: return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }
    }

    /// "week 9", "weeks 9 and 12", "weeks 4–12" (three or more in a row).
    static func weeksText(_ sorted: [Int]) -> String {
        guard let first = sorted.first, let last = sorted.last else { return "no weeks" }
        if sorted.count == 1 { return "week \(first)" }
        if sorted.count >= 3, last - first == sorted.count - 1 { return "weeks \(first)–\(last)" }
        return "weeks " + joined(sorted.map(String.init))
    }

    static func range(_ lo: Int, _ hi: Int) -> String { lo == hi ? "\(lo)" : "\(lo)–\(hi)" }
}

struct ChangePrescriptionModel {

    static let unchangedFooter = "Unchanged: loads, planned values, logged data, completed sessions, other exercises."

    let session: Session
    let item: SessionItem
    let context: ModelContext
    var now: Date = Date()

    var scope: PrescriptionScope
    /// The wave letter for "This week type": starts as the session's own letter and is never "all".
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

    init(session: Session, item: SessionItem, context: ModelContext, scope: PrescriptionScope = .thisSession, now: Date = Date()) {
        self.session = session; self.item = item; self.context = context; self.scope = scope; self.now = now
        let current = SessionItemEditService.PrescriptionValues(item)
        repLow = current.repMin; repHigh = current.repMax
        rirLow = current.rirMin; rirHigh = current.rirMax
        if let top = current.top { topLow = top.repMin; topHigh = top.repMax; topRIR = top.rir }
        let own = item.waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        letter = availableLetters.contains(own) ? own : nil
    }

    /// "This week type" only exists on blocks with waves.
    var availableScopes: [PrescriptionScope] {
        showsLetters ? [.thisSession, .weekType, .everyRemaining] : [.thisSession, .everyRemaining]
    }

    var itemHasTopSet: Bool { item.hasTopSet }

    /// "Add top set: 1 x 4-6 @ 2" / "Update top set: …"
    var topSetTitle: String {
        let reps = topLow == max(topLow, topHigh) ? "\(topLow)" : "\(topLow)-\(max(topLow, topHigh))"
        // Detailed "@ 2" (as before), Simple "@ Solid", Off no effort part.
        let effort: String
        switch EffortTracking.mode {
        case .detailed: effort = " @ \(topRIR)"
        case .simple: effort = " @ \(EffortTracking.plannedWord(topRIR))"
        case .off: effort = ""
        }
        return "\(itemHasTopSet ? "Update" : "Add") top set: 1 x \(reps)\(effort)"
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

    func plan(scope override: PrescriptionScope? = nil) -> SessionItemEditService.ChangePlan? {
        guard let meso = session.meso else { return nil }
        let chosen = override ?? scope
        let serviceScope: SessionItemEditService.ReplaceScope = chosen == .thisSession ? .thisSession(session) : .allRemaining
        // A letter scope with no letter picked changes nothing: the empty set matches no item.
        let letters: Set<String>? = (showsLetters && chosen == .weekType) ? Set(letter.map { [$0] } ?? []) : nil
        return SessionItemEditService.planChangePrescription(
            meso: meso, dayLabel: session.dayLabel, exerciseId: item.exerciseId, letters: letters,
            includeDeload: false, scope: serviceScope, change: change, now: now
        )
    }

    // MARK: Copy

    func title(for choice: PrescriptionScope) -> String {
        guard choice != .thisSession else { return choice.title }
        return "\(choice.title) (\(sessionsInScope(choice)))"
    }

    /// How many sessions the scope reaches, whether or not a value has been changed yet. (The confirmation alert counts
    /// the sessions that would actually change; this is the row's own number.)
    func sessionsInScope(_ choice: PrescriptionScope) -> Int {
        guard let meso = session.meso else { return 0 }
        if choice == .thisSession { return 1 }
        let letters: Set<String>? = (showsLetters && choice == .weekType) ? Set(letter.map { [$0] } ?? []) : nil
        return SessionItemEditService.sessionsInScope(
            meso: meso, dayLabel: session.dayLabel, exerciseId: item.exerciseId, letters: letters,
            includeDeload: false, scope: .allRemaining, now: now
        )
    }

    // MARK: Confirmation (more than one session)

    var exerciseName: String { ExerciseCatalog.displayName(for: ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)) }

    /// "15–20 → 12–15", or "reps 15–20 → 12–15; RIR 2–3 → 1–2" when several things change.
    static func changeSummary(_ plan: SessionItemEditService.ChangePlan) -> String {
        let change = plan.change
        func olds(_ text: (SessionItemEditService.PrescriptionValues) -> String) -> String? {
            let distinct = Set(plan.targets.map { text($0.before) })
            return distinct.count == 1 ? distinct.first : nil
        }
        var parts: [(label: String, text: String)] = []
        if let d = change.setDelta { parts.append(("sets", d > 0 ? "+\(d)" : "−\(-d)")) }
        if let r = change.repRange {
            let new = MultiSessionCopy.range(r.lowerBound, r.upperBound)
            let old = olds { MultiSessionCopy.range($0.repMin, $0.repMax) }
            parts.append(("reps", old.map { "\($0) → \(new)" } ?? "→ \(new)"))
        }
        if let r = change.rirRange, EffortTracking.mode != .off {
            // Detailed: "RIR 2–3 → 3–4". Simple: "effort Solid–Easy → Easy".
            func shown(_ lo: Int, _ hi: Int) -> String {
                EffortTracking.mode == .simple
                    ? (EffortTracking.plannedRangeText(lo, hi) ?? "")
                    : MultiSessionCopy.range(lo, hi)
            }
            let new = shown(r.lowerBound, r.upperBound)
            let old = olds { shown($0.rirMin, $0.rirMax) }
            parts.append((EffortTracking.mode == .simple ? "effort" : "RIR", old.map { "\($0) → \(new)" } ?? "→ \(new)"))
        }
        switch change.topSet {
        case .set?: parts.append(("top set", "added or updated"))
        case .remove?: parts.append(("top set", "removed"))
        case nil: break
        }
        if change.note != nil { parts.append(("note", "changed")) }
        if parts.count == 1, parts[0].label == "reps" || parts[0].label == "RIR" || parts[0].label == "effort" { return parts[0].text }
        return parts.map { "\($0.label) \($0.text)" }.joined(separator: "; ")
    }

    /// "Rear Delt Fly: 15–20 → 12–15 in 2 sessions (C weeks, weeks 9 and 12). Change?"
    static func confirmationMessage(_ plan: SessionItemEditService.ChangePlan) -> String {
        let name = ExerciseCatalog.displayName(for: plan.exerciseId)
        let n = plan.targets.count
        let scope = MultiSessionCopy.scopeSummary(waves: plan.targets.map(\.waveRaw), weeks: plan.targets.map(\.weekIndex))
        return "\(name): \(changeSummary(plan)) in \(n) sessions (\(scope)). Change?"
    }

    /// True when the apply reaches more than one session: it needs the confirmation, the backup and the undo.
    static func isMultiSession(_ plan: SessionItemEditService.ChangePlan) -> Bool { plan.targets.count > 1 }

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

    /// The fields a multi-session apply will overwrite, captured before it runs (see `SessionItemEditService.PrescriptionUndo`).
    func captureUndo(_ plan: SessionItemEditService.ChangePlan) -> SessionItemEditService.PrescriptionUndo {
        SessionItemEditService.capturePrescriptionUndo(for: plan)
    }

    func undo(_ undo: SessionItemEditService.PrescriptionUndo) -> Result<Int, ReplaceExerciseModel.ApplyFailure> {
        do { return .success(try SessionItemEditService.undoPrescriptionChange(undo, in: context)) } catch let error as SessionItemEditService.ReplaceError {
            return .failure(.init(error: error))
        } catch { return .failure(.init(error: .saveFailed("\(error)"))) }
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

/// "Change prescription…": scope, letters, sets, rep range, RIR range, a preview from the plan, then apply.
struct ChangePrescriptionFlow: View {
    @Environment(\.modelContext) private var modelContext

    let session: Session
    let item: SessionItem
    /// Called after a change that reached more than one session, with what is needed to undo it.
    var onApplied: (SessionItemEditService.PrescriptionUndo, _ summary: String) -> Void = { _, _ in }
    let onFinish: () -> Void

    @State private var model: ChangePrescriptionModel?

    var body: some View {
        Group {
            if let binding = Binding($model) {
                ChangePrescriptionForm(model: binding, onApplied: onApplied, onFinish: onFinish)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil {
                model = ChangePrescriptionModel(session: session, item: item, context: modelContext)
            }
        }
    }
}

private struct ChangePrescriptionForm: View {
    @AppStorage(EffortTracking.mirrorKey) private var effortRaw: String = ""
    private var effortMode: EffortMode { EffortMode(rawValue: effortRaw) ?? .detailed }

    /// Simple mode: the four effort words instead of a number. A stored RIR above 3 shows as Easy (3+ left).
    private func effortPicker(_ title: String, value: Binding<Int>) -> some View {
        Picker(title, selection: Binding(get: { min(max(value.wrappedValue, 0), 3) }, set: { value.wrappedValue = $0 })) {
            ForEach(EffortTracking.simpleChoices, id: \.rir) { Text($0.label).tag($0.rir) }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Binding var model: ChangePrescriptionModel
    let onApplied: (SessionItemEditService.PrescriptionUndo, String) -> Void
    let onFinish: () -> Void
    @State private var errorMessage: String?
    /// The multi-session plan waiting for the lifter's "Change".
    @State private var pendingConfirm: SessionItemEditService.ChangePlan?
    @StateObject private var seedGuard = SeedBackupGuard()

    private var plan: SessionItemEditService.ChangePlan? { model.plan() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scope", selection: $model.scope) {
                        ForEach(model.availableScopes, id: \.self) { choice in
                            Text(model.title(for: choice)).tag(choice)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text(model.exerciseName)
                }

                if model.showsLetters && model.scope == .weekType {
                    Section {
                        Picker("Week type", selection: $model.letter) {
                            ForEach(model.availableLetters, id: \.self) { l in
                                Text(l.uppercased()).tag(String?.some(l))
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Week type")
                    } footer: {
                        if model.letter == nil { Text("Choose a week type.") }
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

                if effortMode == .detailed {
                    Section("RIR") {
                        Toggle("Change RIR range", isOn: $model.changeRIR)
                        if model.changeRIR {
                            Stepper("Min \(model.rirLow)", value: $model.rirLow, in: PrescriptionChange.rirBounds)
                            Stepper("Max \(max(model.rirLow, model.rirHigh))", value: $model.rirHigh, in: PrescriptionChange.rirBounds)
                        }
                    }
                } else if effortMode == .simple {
                    Section("Effort") {
                        Toggle("Change planned effort", isOn: $model.changeRIR)
                        if model.changeRIR {
                            effortPicker("Hardest set", value: $model.rirLow)
                            effortPicker("Easiest set", value: $model.rirHigh)
                        }
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
                        if effortMode == .detailed {
                            Stepper("RIR \(model.topRIR)", value: $model.topRIR, in: PrescriptionChange.rirBounds)
                        } else if effortMode == .simple {
                            effortPicker("Effort", value: $model.topRIR)
                        }
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
                                    Text("\(EffortTracking.localize(row.before))  →  \(EffortTracking.localize(row.after))")
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
            .seedBackupGuard(seedGuard)
            .alert("Change \(pendingConfirm?.targets.count ?? 0) sessions?", isPresented: Binding(
                get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } }
            ), presenting: pendingConfirm) { pending in
                Button("Change") { applyMulti(pending) }
                Button("Cancel", role: .cancel) { }
            } message: { pending in
                Text(ChangePrescriptionModel.confirmationMessage(pending))
            }
            .keyboardDismissal()   // the note field is multi-line
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
        errorMessage = nil
        guard ChangePrescriptionModel.isMultiSession(plan) else {
            switch model.apply(plan) {
            case .success: onFinish()
            case .failure(let failure): errorMessage = failure.message
            }
            return
        }
        pendingConfirm = plan
    }

    /// After "Change": a verified backup first (if it fails nothing is applied), then the apply with the undo captured
    /// beforehand.
    private func applyMulti(_ plan: SessionItemEditService.ChangePlan) {
        seedGuard.run(container: modelContext.container) {
            let undo = model.captureUndo(plan)
            let summary = "\(model.exerciseName): changed \(plan.targets.count) sessions"
            switch model.apply(plan) {
            case .success:
                onApplied(undo, summary)
                onFinish()
            case .failure(let failure):
                errorMessage = failure.message
            }
        }
    }
}
