import SwiftUI
import SwiftData

// MARK: - Model (no SwiftUI; the preview and the write both come from SessionItemEditService)

struct RestTodayModel {

    typealias Service = SessionItemEditService

    static let title = "Rest today"
    static let headline = "Today becomes a rest day."
    static let footer = "Only dates change: loads, weeks, exercises and logged work stay as they are. Sessions after the first free day are untouched."

    let meso: MesoBlock
    let context: ModelContext
    var now: Date = Date()

    func plan() -> Service.SlidePlan {
        Service.planRestToday(meso: meso, context: context, now: now)
    }

    static func day(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "N session(s) move to the next free day:"
    static func moveHeading(_ plan: Service.SlidePlan) -> String {
        plan.moves.count == 1 ? "1 session moves to the next free day:" : "\(plan.moves.count) sessions move to the next free day:"
    }

    /// "Legs B  Tue Oct 20 → Wed Oct 21", the placed session first, then each one it pushes.
    static func moveLines(_ plan: Service.SlidePlan) -> [String] {
        plan.moves.map { "\($0.session.dayLabel ?? "Session")  \(day($0.oldDate)) → \(day($0.newDate))" }
    }

    /// Only when the last session of the block moves: "The block now ends Fri, Jan 29 (was Thu, Jan 28)."
    static func blockEndLine(_ plan: Service.SlidePlan) -> String? {
        guard plan.blockEndMoves, let before = plan.blockEndBefore, let after = plan.blockEndAfter else { return nil }
        return "The block now ends \(day(after)) (was \(day(before)))."
    }

    static func warningLines(_ plan: Service.SlidePlan) -> [String] {
        plan.warnings.map {
            switch $0 {
            case .pastNextMesoStart(let date, let next):
                return "A session lands on \(day(date)), on or after the next block's scheduled start (\(day(next)))."
            }
        }
    }

    static func isRefusal(_ plan: Service.SlidePlan) -> Bool { plan.refusal != nil }

    /// "OK" (dismiss) when the plan refuses, otherwise "Move N session(s)".
    static func primaryTitle(_ plan: Service.SlidePlan) -> String {
        plan.refusal != nil ? "OK" : "Move \(plan.moves.count) session\(plan.moves.count == 1 ? "" : "s")"
    }

    /// Names the day and the session in the way (every refusal reads the same on both entry points).
    static func refusalText(_ refusal: Service.SlideRefusal) -> String {
        switch refusal {
        case .notPlaceable: return "This session is no longer waiting to be done."
        case .nothingToMove: return "There's no planned session today to move."
        case .sessionInProgress: return "A session in this block is in progress. Finish it, then try again."
        case .targetInPast: return "Pick today or a later day."
        case .unsafeSession: return "A session that would move already has logged work."
        case .blocked(let d, let occupant, let kind):
            switch kind {
            case .completed: return "\(day(d)) has \(occupant), which is already done and can't move."
            case .inProgress: return "\(day(d)) has \(occupant), which is in progress."
            case .loggedData: return "\(day(d)) has \(occupant), which already has logged work and can't move."
            case .otherBlock: return "\(day(d)) has \(occupant), which belongs to another block and can't move."
            case .sharedDay: return "Two sessions already share \(day(d)): \(occupant)."
            }
        }
    }

    struct ApplyFailure: Error, Equatable {
        let error: Service.SlideError
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

    func apply(_ plan: Service.SlidePlan) -> Result<Service.SlideResult, ApplyFailure> {
        do {
            return .success(try Service.applySlide(plan, in: context))
        } catch let error as Service.SlideError {
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
                } else {
                    Section {
                        Text(RestTodayModel.moveHeading(plan)).font(.callout).foregroundStyle(.secondary)
                        ForEach(Array(RestTodayModel.moveLines(plan).enumerated()), id: \.offset) { _, l in Text(l) }
                        if let end = RestTodayModel.blockEndLine(plan) { Text(end).font(.callout) }
                    } header: {
                        Text(RestTodayModel.headline)
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
            .toolbar {
                // A refusal has one way out (the OK button below); the toolbar Cancel is only for a plan you can confirm.
                if !RestTodayModel.isRefusal(plan) { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    if RestTodayModel.isRefusal(plan) { onFinish(); return }
                    switch model.apply(plan) {
                    case .success: onFinish()
                    case .failure(let failure):
                        errorMessage = failure.message
                        if failure.needsRefresh { refreshToken += 1 }
                    }
                } label: {
                    Text(RestTodayModel.primaryTitle(plan)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!RestTodayModel.isRefusal(plan) && !plan.isApplicable)
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

    /// The menu item and the confirmation say it in full; the sheet's title is short so it never truncates (iPhone 17e at XXXL did).
    static let title = "Make every week the same"
    static let menuTitle = "Make every week the same"
    static let sheetTitle = "Same every week"
    static let undoTitle = "Undo \"Make every week the same\""
    static let footer = "Every unstarted exercise that has a version in the chosen week takes that week's sets, reps, effort target and notes, and its A/B/C week label goes. Each load becomes your last coach decision for that exercise on that day. Exercises whose plan you edited yourself keep their prescription and load. An exercise that can't be converted (no version in the chosen week, or a different top-set layout) is left exactly as it is, label included, and listed here. From then on each day carries forward to the same day. Deload weeks stay deloads. Finished and started sessions don't change."

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

    /// "Fri Nov 27 · Lower A · Single Leg Press: 4×12–15 · 1 RIR, load 145 (as you edited it)"
    static func keptLine(_ c: Service.SameWeekChange, unit: LoadUnit = .lb) -> String {
        let name = c.item.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: c.item.exerciseId)
        return "\(day(c.session.date)) · \(c.session.dayLabel ?? "Session") · \(name): \(range(c.after)), load \(LoadFormatter(unit: unit).number(c.after.suggestedLoad))"
    }

    /// "Fri Dec 11 · Upper B · W8 · Hammer Curl (B week)"
    static func unmatchedLine(_ u: Service.SameWeekUnmatched) -> String {
        let name = u.item.exerciseNameSnapshot ?? ExerciseCatalog.displayName(for: u.item.exerciseId)
        let wave = u.item.waveRaw.map { " (\($0.uppercased()) week)" } ?? ""
        let why = u.reason == .topSetShapeDiffers ? " · top-set layout differs" : ""
        return "\(day(u.session.date)) · \(u.session.dayLabel ?? "Session") · \(u.session.weekDayLabel) · \(name)\(wave)\(why)"
    }

    static func unmatchedHeading(_ plan: Service.SameWeekPlan) -> String {
        "Can't be changed to the \(plan.keep.uppercased()) week, left as they are (\(plan.unmatched.count))"
    }

    static func sessionHeader(_ s: Session) -> String { "\(day(s.date)) · \(s.dayLabel ?? "Session") · \(s.weekDayLabel)" }

    static func confirmMessage(_ plan: Service.SameWeekPlan) -> String {
        "Change \(plan.sessionsChanged) session\(plan.sessionsChanged == 1 ? "" : "s") (\(plan.itemsChanged) exercises) to the \(plan.keep.uppercased()) week's prescription? \(plan.editedKept > 0 ? "\(plan.editedKept) you edited yourself are kept. " : "")\(plan.unmatched.isEmpty ? "" : "\(plan.unmatched.count) that can't be changed to it stay exactly as they are. ")A backup is made first, finished sessions don't change, and you can undo."
    }

    static func refusalText(_ r: Service.SameWeekRefusal) -> String {
        switch r {
        case .notAWaveBlock: return "This block has no A/B/C weeks: every week is already the same."
        case .sessionInProgress: return "A session in this block is in progress. Finish it, then try again."
        case .noUnstartedSessions: return "There are no unstarted sessions left to change."
        case .unknownWeekType: return "That week type isn't in this block."
        case .wouldTouchHistory: return "This change would have touched a finished session, so nothing was changed."
        case .verificationFailed: return "The change didn't pass its own check, so nothing was changed."
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
                            if plan.editedKept > 0 { Text("\(plan.editedKept) exercises you edited yourself are kept as they are").font(.callout).foregroundStyle(.secondary) }
                            if plan.unmatchedSlots > 0 { Text("\(plan.unmatchedSlots) exercises can't be changed to the \(plan.keep.uppercased()) week and stay exactly as they are, week label included").font(.callout).foregroundStyle(.secondary) }
                        } footer: { Text(SameWeekText.footer) }

                        let grouped = Dictionary(grouping: plan.converted, by: { $0.session.persistentModelID })
                        let sessions = plan.converted.map(\.session).reduce(into: [Session]()) { acc, s in if !acc.contains(where: { $0 === s }) { acc.append(s) } }
                            .sorted { $0.date < $1.date }
                        if !plan.keptAsEdited.isEmpty {
                            Section {
                                DisclosureGroup("Kept as you edited (\(plan.keptAsEdited.count))") {
                                    ForEach(plan.keptAsEdited.sorted { ($0.session.date, $0.item.order) < ($1.session.date, $1.item.order) }, id: \.itemID) { c in
                                        Text(SameWeekText.keptLine(c, unit: unit)).font(.caption)
                                    }
                                }
                            } footer: { Text("Prescription and load stay as you set them. Only the week label is removed.") }
                        }
                        if !plan.unmatched.isEmpty {
                            Section {
                                DisclosureGroup(SameWeekText.unmatchedHeading(plan)) {
                                    ForEach(plan.unmatched.sorted { ($0.session.date, $0.item.order) < ($1.session.date, $1.item.order) }, id: \.itemID) { u in
                                        Text(SameWeekText.unmatchedLine(u)).font(.caption)
                                    }
                                }
                            } footer: { Text("For these there is no \(plan.keep.uppercased())-week version with the same layout for that day, so there is nothing to change them to. Their week label stays.") }
                        }
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
            .navigationTitle(SameWeekText.sheetTitle)
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
