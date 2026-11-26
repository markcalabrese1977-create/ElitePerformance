import SwiftUI
import SwiftData

// MARK: - Model (no SwiftUI; the preview and the write both come from SessionItemEditService)

struct RestTodayModel {

    typealias Service = SessionItemEditService

    static let title = "Rest today"
    static let footer = "Only dates change: loads, weeks, exercises and logged work stay as they are. The rest of the block is untouched."

    let meso: MesoBlock
    let context: ModelContext
    var now: Date = Date()

    func plan() -> Service.RestTodayPlan {
        Service.planRestToday(meso: meso, context: context, now: now)
    }

    private static func day(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Legs B  Tue Oct 20 -> Wed Oct 21"
    static func moveLines(_ plan: Service.RestTodayPlan) -> [String] {
        plan.moves.map { "\($0.session.dayLabel ?? "Session")  \(day($0.oldDate)) -> \(day($0.newDate))" }
    }

    static func warningLines(_ plan: Service.RestTodayPlan) -> [String] {
        plan.warnings.map {
            switch $0 {
            case .reachesNextWeek(let date, let label):
                return "\(label ?? "A session") lands on \(day(date)), when next week's training starts."
            case .pastNextMesoStart(let date, let next):
                return "A session lands on \(day(date)), on or after the next block's scheduled start (\(day(next)))."
            }
        }
    }

    static func collisionLines(_ plan: Service.RestTodayPlan) -> [String] {
        plan.collisions.map {
            "\($0.moved.dayLabel ?? "Session") would land on \(day($0.date)), already taken by \($0.occupant.dayLabel ?? "another session")."
        }
    }

    static func refusalText(_ refusal: Service.RestTodayRefusal) -> String {
        switch refusal {
        case .sessionInProgress: return "A session in this block is in progress. Finish it, then try again."
        case .nothingToMove: return "There's no planned session today to move."
        case .unsafeSession: return "A session that would move already has logged work."
        case .dateCollision: return "Moving the week's sessions a day later would double up a day that's already taken."
        }
    }

    struct ApplyFailure: Error, Equatable {
        let error: Service.RestTodayError
        var needsRefresh: Bool { error == .planStale }
        var message: String {
            switch error {
            case .refused(let reason): return RestTodayModel.refusalText(reason) + " Nothing was changed."
            case .planStale: return "The schedule changed since the preview. Nothing was changed — review the updated preview."
            case .verificationFailed: return "The change couldn't be verified, so nothing was written."
            case .saveFailed: return "The change couldn't be saved, so nothing was written."
            }
        }
    }

    func apply(_ plan: Service.RestTodayPlan) -> Result<Service.RestTodayResult, ApplyFailure> {
        do {
            return .success(try Service.restToday(plan, in: context))
        } catch let error as Service.RestTodayError {
            return .failure(.init(error: error))
        } catch {
            return .failure(.init(error: .saveFailed("\(error)")))
        }
    }
}

// MARK: - View

struct RestTodayFlow: View {
    @Environment(\.modelContext) private var modelContext

    let meso: MesoBlock
    let onFinish: () -> Void

    @State private var errorMessage: String?
    @State private var refreshToken = 0

    var body: some View {
        let model = RestTodayModel(meso: meso, context: modelContext)
        let plan = model.plan()
        NavigationStack {
            Form {
                if let refusal = plan.refusal {
                    Section { Text(RestTodayModel.refusalText(refusal)).foregroundStyle(.secondary) }
                    let lines = RestTodayModel.collisionLines(plan)
                    if !lines.isEmpty {
                        Section("Days already taken") {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(l).font(.callout) }
                        }
                    }
                } else {
                    Section {
                        ForEach(Array(RestTodayModel.moveLines(plan).enumerated()), id: \.offset) { _, l in Text(l) }
                    } header: {
                        Text("Today becomes a rest day")
                    } footer: {
                        Text(RestTodayModel.footer)
                    }
                    let warnings = RestTodayModel.warningLines(plan)
                    if !warnings.isEmpty {
                        Section("Heads up") {
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                                Text(w).font(.callout).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
                }
            }
            .id(refreshToken)
            .navigationTitle(RestTodayModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) } }
            .safeAreaInset(edge: .bottom) {
                Button {
                    switch model.apply(plan) {
                    case .success: onFinish()
                    case .failure(let failure):
                        errorMessage = failure.message
                        if failure.needsRefresh { refreshToken += 1 }
                    }
                } label: {
                    Text("Move \(plan.moves.count) session\(plan.moves.count == 1 ? "" : "s")").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!plan.isApplicable)
                .padding()
                .background(.bar)
            }
        }
    }
}

// MARK: - Make every week the same (wave block -> wave-less)

/// Text for the conversion screens. Pure, so the tests read the same strings the screen shows.
enum SameWeekText {
    typealias Service = SessionItemEditService

    static let title = "Make every week the same"
    static let menuTitle = "Make every week the same"
    static let undoTitle = "Undo \"Make every week the same\""
    static let footer = "Every unstarted session takes the chosen week's sets, reps, effort target and notes, and the A/B/C week labels go. Each load becomes your last coach decision for that exercise on that day. From then on each day carries forward to the same day. Deload weeks stay deloads. Finished and started sessions don't change."

    static func day(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

    static func weekTypeLine(_ w: Service.WeekType) -> String {
        let last = w.lastTrained.map { "last trained \(day($0))" } ?? "not trained yet"
        return "\(w.letter.uppercased()) week · \(last) · \(w.remaining) unstarted"
    }

    static func range(_ s: Service.SameWeekSnapshot) -> String {
        let reps: String
        if let lo = s.repMin, let hi = s.repMax { reps = lo == hi ? "\(lo)" : "\(lo)–\(hi)" } else { reps = "\(s.targetReps)" }
        let rir: String?
        switch EffortTracking.mode {
        case .off: rir = nil
        case .detailed:
            if let lo = s.targetRIRMin, let hi = s.targetRIRMax, lo != hi { rir = "\(lo)–\(hi) RIR" } else { rir = "\(s.targetRIR) RIR" }
        case .simple:
            if let lo = s.targetRIRMin, let hi = s.targetRIRMax, lo != hi { rir = EffortTracking.plannedRangeText(lo, hi) } else { rir = EffortTracking.plannedText(s.targetRIR) }
        }
        return ["\(s.targetSets)×\(reps)", rir].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Single Leg Press: 3×8–12 · 2 RIR → 4×12–15 · 1 RIR; load 145 → 147.5"
    static func line(_ c: Service.SameWeekChange, unit: LoadUnit = .lb) -> String {
        let f = LoadFormatter(unit: unit)
        let name = c.item.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: c.item.exerciseId)
        let r0 = range(c.before), r1 = range(c.after)
        let rangeText = r0 == r1 ? r1 : "\(r0) → \(r1)"
        let l0 = f.number(c.before.suggestedLoad), l1 = f.number(c.after.suggestedLoad)
        let loadText = l0 == l1 ? "load \(l1)" : "load \(l0) → \(l1)"
        return "\(name): \(rangeText); \(loadText)" + (c.notes.isEmpty ? "" : " (\(c.notes.joined(separator: "; ")))")
    }

    static func sessionHeader(_ s: Session) -> String { "\(day(s.date)) · \(s.dayLabel ?? "Session") · \(s.weekDayLabel)" }

    static func confirmMessage(_ plan: Service.SameWeekPlan) -> String {
        "Change \(plan.sessionsChanged) session\(plan.sessionsChanged == 1 ? "" : "s") (\(plan.itemsChanged) exercises) to the \(plan.keep.uppercased()) week's prescription? A backup is made first, finished sessions don't change, and you can undo."
    }

    static func refusalText(_ r: Service.SameWeekRefusal) -> String {
        switch r {
        case .notAWaveBlock: return "This block has no A/B/C weeks: every week is already the same."
        case .sessionInProgress: return "A session in this block is in progress. Finish it, then try again."
        case .noUnstartedSessions: return "There are no unstarted sessions left to change."
        case .unknownWeekType: return "That week type isn't in this block."
        case .wouldTouchHistory: return "This change would have touched a finished session, so nothing was changed."
        }
    }

    static func errorText(_ e: Service.SameWeekError) -> String {
        switch e {
        case .refused(let r): return refusalText(r)
        case .planStale: return "The schedule changed since the preview. Nothing was changed: review the updated preview."
        case .verificationFailed: return "The change couldn't be verified, so nothing was written."
        case .saveFailed: return "The change couldn't be saved, so nothing was written."
        }
    }

    static func undoMessage(_ r: Service.SameWeekUndoRecord) -> String {
        "Puts \(r.items.count) exercises back to how they were on \(day(r.createdAt)), week labels included. Sessions you have started or finished since are left as they are."
    }
}

struct SameEveryWeekFlow: View {
    @Environment(\.modelContext) private var modelContext
    let meso: MesoBlock
    let onFinish: () -> Void

    @State private var keep: String
    @State private var plan: SessionItemEditService.SameWeekPlan?
    @State private var errorMessage: String?
    @State private var confirming = false
    @StateObject private var seedGuard = SeedBackupGuard()

    init(meso: MesoBlock, onFinish: @escaping () -> Void) {
        self.meso = meso
        self.onFinish = onFinish
        _keep = State(initialValue: SessionItemEditService.defaultKeptWeekType(in: meso) ?? "a")
    }

    private var unit: LoadUnit { (try? modelContext.fetch(FetchDescriptor<UserProfile>()).first)?.loadUnit ?? .lb }

    var body: some View {
        let types = SessionItemEditService.sameWeekTypes(in: meso)
        NavigationStack {
            Form {
                Section {
                    Picker("Keep the ranges of", selection: $keep) {
                        ForEach(types, id: \.letter) { Text(SameWeekText.weekTypeLine($0)).tag($0.letter) }
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text("Defaults to the week you trained most recently.")
                }

                if let plan {
                    if let refusal = plan.refusal {
                        Section { Text(SameWeekText.refusalText(refusal)).foregroundStyle(.secondary) }
                    } else {
                        Section {
                            Text("\(plan.sessionsChanged) sessions · \(plan.itemsChanged) exercises")
                            if plan.editedLoadsKept > 0 { Text("\(plan.editedLoadsKept) loads you edited are kept").font(.callout).foregroundStyle(.secondary) }
                            if plan.unmatchedSlots > 0 { Text("\(plan.unmatchedSlots) exercises have no \(plan.keep.uppercased())-week version and keep their own prescription").font(.callout).foregroundStyle(.secondary) }
                        } footer: { Text(SameWeekText.footer) }

                        let grouped = Dictionary(grouping: plan.changes, by: { $0.session.persistentModelID })
                        let sessions = plan.changes.map(\.session).reduce(into: [Session]()) { acc, s in if !acc.contains(where: { $0 === s }) { acc.append(s) } }
                            .sorted { $0.date < $1.date }
                        Section("Every changed session") {
                            ForEach(sessions, id: \.persistentModelID) { s in
                                DisclosureGroup(SameWeekText.sessionHeader(s)) {
                                    ForEach((grouped[s.persistentModelID] ?? []).sorted { $0.item.order < $1.item.order }, id: \.itemID) { c in
                                        Text(SameWeekText.line(c, unit: unit)).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Section { ProgressView("Working out the changes…") }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red).font(.callout) } }
            }
            .task(id: keep) { plan = SessionItemEditService.planSameEveryWeek(meso: meso, keep: keep, context: modelContext) }
            .seedBackupGuard(seedGuard)
            .navigationTitle(SameWeekText.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) } }
            .safeAreaInset(edge: .bottom) {
                Button { confirming = true } label: { Text(SameWeekText.title).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!(plan?.isApplicable ?? false))
                    .padding().background(.bar)
            }
            .alert(SameWeekText.title, isPresented: $confirming) {
                Button("Back up and change") {
                    guard let plan else { return }
                    // A verified backup first; if it fails nothing is changed (see SeedBackupGuard).
                    seedGuard.run(container: modelContext.container) {
                        do {
                            try SessionItemEditService.applySameEveryWeek(plan, backupTaken: true, in: modelContext)
                            Haptics.success()
                            onFinish()
                        } catch let e as SessionItemEditService.SameWeekError {
                            errorMessage = SameWeekText.errorText(e)
                        } catch { errorMessage = "The change couldn't be saved, so nothing was written." }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text(plan.map { SameWeekText.confirmMessage($0) } ?? "") }
        }
    }
}
