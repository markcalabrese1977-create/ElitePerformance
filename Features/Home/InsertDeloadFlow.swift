import SwiftUI
import SwiftData

// MARK: - Model (no SwiftUI; the preview and the write both come from SessionItemEditService)

struct InsertDeloadModel {

    typealias Service = SessionItemEditService

    static let title = "Insert deload week"
    /// "A deload week goes in as week 7. Half the sets, the same rep range, 3–4 reps in reserve." in the effort mode's words.
    static func introText(week: Int, mode: EffortMode = EffortTracking.mode) -> String {
        let tail: String
        switch mode {
        case .detailed: tail = ", 3–4 reps in reserve."
        case .simple: tail = ", and it feels easy."
        case .off: tail = "."
        }
        return "A deload week goes in as week \(week). Half the sets, the same rep range\(tail)"
    }

    static let unchangedFooter = "Unchanged: logged and completed sessions, every exercise, wave and day. Later planned sessions keep their loads and move one week later."

    let meso: MesoBlock
    let context: ModelContext
    var now: Date = Date()
    /// nil = the first eligible week.
    var week: Int? = nil

    /// Every week a deload can go in front of.
    var eligibleWeeks: [Int] { Service.eligibleDeloadWeeks(meso: meso, now: now) }

    /// The week the plan targets: the choice when it is still eligible, else the first eligible one.
    var effectiveWeek: Int? {
        if let week, eligibleWeeks.contains(week) { return week }
        return eligibleWeeks.first
    }

    func plan() -> Service.InsertDeloadPlan {
        Service.planInsertDeloadWeek(meso: meso, context: context, now: now, week: effectiveWeek)
    }

    /// "Week 5 · Fri, Oct 23" for the picker.
    func weekLabel(_ w: Int) -> String {
        let first = meso.sessions.filter { $0.weekIndex == w }.map(\.date).min()
        let date = first.map { " · " + $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? ""
        return "Week \(w)\(date)"
    }

    // MARK: Copy

    static func moveText(count: Int) -> String {
        count == 1 ? "1 session moves one week later" : "\(count) sessions move one week later"
    }

    static func endDateText(_ plan: Service.InsertDeloadPlan) -> String? {
        guard let before = plan.blockEndBefore, let after = plan.blockEndAfter else { return nil }
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return "Block ends \(after.formatted(f)) (was \(before.formatted(f)))"
    }

    static func refusalText(_ refusal: Service.InsertDeloadRefusal) -> String {
        switch refusal {
        case .inactiveMeso: return "This block isn't the active one."
        case .sessionInProgress: return "A session in this block is in progress. Finish it, then try again."
        case .weekNotEligible: return "That week has started, has logged work, is in the past, or is already a deload."
        case .noEligibleWeek: return "Every remaining week has already started, has logged work, or is already a deload, so there's no clean week to insert before."
        case .laterSessionCompleted: return "A later week already has a completed session, so the weeks can't shift cleanly."
        case .dateCollision: return "Moving the schedule a week would put sessions on days that are already taken."
        }
    }

    struct CollisionRow: Equatable {
        let date: Date
        let moved: String
        let occupant: String
    }

    static func collisionRows(_ plan: Service.InsertDeloadPlan) -> [CollisionRow] {
        plan.collisions.map {
            CollisionRow(date: $0.date, moved: $0.moved.dayLabel ?? "Session", occupant: $0.occupant.dayLabel ?? "Session")
        }
    }

    struct ItemRow: Equatable {
        let name: String
        let prescription: String
        let load: String
    }

    struct SessionRow: Equatable {
        let date: Date
        let dayLabel: String
        let items: [ItemRow]
    }

    static func loadText(_ item: Service.DeloadItemPlan, unit: LoadUnit = .lb) -> String {
        if ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId) { return "BW" }
        return item.load > 0 ? LoadFormatter(unit: unit).text(item.load) : "enter on the day"
    }

    static func rows(_ plan: Service.InsertDeloadPlan, unit: LoadUnit = .lb) -> [SessionRow] {
        plan.deloadSessions.map { s in
            SessionRow(
                date: s.date, dayLabel: s.dayLabel ?? "Session",
                items: s.items.map {
                    ItemRow(name: ExerciseCatalog.displayName(for: $0.exerciseId), prescription: $0.prescription, load: loadText($0, unit: unit))
                }
            )
        }
    }

    static func confirmTitle(_ plan: Service.InsertDeloadPlan) -> String { "Insert deload week" }

    struct ApplyFailure: Error, Equatable {
        let error: Service.InsertDeloadError

        var needsRefresh: Bool { error == .planStale }

        var message: String {
            switch error {
            case .refused(let reason): return InsertDeloadModel.refusalText(reason) + " Nothing was changed."
            case .planStale: return "The schedule changed since the preview. Nothing was changed — review the updated preview."
            case .verificationFailed: return "The change couldn't be verified, so nothing was written."
            case .saveFailed: return "The change couldn't be saved, so nothing was written."
            }
        }
    }

    func apply(_ plan: Service.InsertDeloadPlan) -> Result<Service.InsertDeloadResult, ApplyFailure> {
        do {
            return .success(try Service.insertDeloadWeek(plan, in: context))
        } catch let error as Service.InsertDeloadError {
            return .failure(.init(error: error))
        } catch {
            return .failure(.init(error: .saveFailed("\(error)")))
        }
    }
}

// MARK: - View

/// "Insert deload week": a preview of the deload sessions and the schedule shift, then apply.
struct InsertDeloadFlow: View {
    @StateObject private var seedGuard = SeedBackupGuard()
    @Environment(\.loadUnit) private var unit
    @Environment(\.modelContext) private var modelContext

    let meso: MesoBlock
    let onFinish: () -> Void

    @State private var errorMessage: String?
    @State private var refreshToken = 0
    @State private var chosenWeek: Int?

    var body: some View {
        let model = InsertDeloadModel(meso: meso, context: modelContext, week: chosenWeek)
        let plan = model.plan()
        NavigationStack {
            Form {
                if model.eligibleWeeks.count > 1 {
                    Section {
                        Picker("Insert before", selection: Binding(
                            get: { model.effectiveWeek ?? 0 },
                            set: { chosenWeek = $0 }
                        )) {
                            ForEach(model.eligibleWeeks, id: \.self) { w in Text(model.weekLabel(w)).tag(w) }
                        }
                    } footer: {
                        Text("Weeks that have started, have logged work, or are already deloads aren't offered.")
                    }
                }
                if let refusal = plan.refusal {
                    Section {
                        Text(InsertDeloadModel.refusalText(refusal)).foregroundStyle(.secondary)
                    }
                    let collisions = InsertDeloadModel.collisionRows(plan)
                    if !collisions.isEmpty {
                        Section("Days already taken") {
                            ForEach(Array(collisions.enumerated()), id: \.offset) { _, c in
                                HStack {
                                    Text(c.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    Spacer()
                                    Text("\(c.moved) → \(c.occupant)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        if let week = plan.weekIndex {
                            Text(InsertDeloadModel.introText(week: week))
                        }
                        Text(InsertDeloadModel.moveText(count: plan.shifted.count))
                        if let end = InsertDeloadModel.endDateText(plan) { Text(end) }
                    } footer: {
                        Text(InsertDeloadModel.unchangedFooter)
                    }

                    ForEach(Array(InsertDeloadModel.rows(plan, unit: unit).enumerated()), id: \.offset) { _, row in
                        Section {
                            ForEach(Array(row.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text("\(EffortTracking.localize(item.prescription)) · \(item.load)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            Text("\(row.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(row.dayLabel)")
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
                }
            }
            .id(refreshToken)
            .seedBackupGuard(seedGuard)
            .navigationTitle(InsertDeloadModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    // A verified backup first; if it fails the week is not inserted (see SeedBackupGuard).
                    seedGuard.run(container: modelContext.container) {
                        switch model.apply(plan) {
                        case .success: onFinish()
                        case .failure(let failure):
                            errorMessage = failure.message
                            if failure.needsRefresh { refreshToken += 1 }
                        }
                    }
                } label: {
                    Text(InsertDeloadModel.confirmTitle(plan)).frame(maxWidth: .infinity)
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


// MARK: - Remove an inserted deload week

struct RemoveDeloadModel {

    typealias Service = SessionItemEditService

    static let title = "Remove inserted deload week"
    static let unchangedFooter = "Unchanged: logged and completed sessions, generated deloads. Later planned sessions keep their loads and move one week earlier."

    let meso: MesoBlock
    let context: ModelContext
    var now: Date = Date()
    /// nil = the first inserted week that can go.
    var week: Int? = nil

    func plan() -> Service.RemoveDeloadPlan {
        Service.planRemoveInsertedDeloadWeek(meso: meso, context: context, now: now, week: week)
    }

    static func moveText(count: Int) -> String {
        count == 1 ? "1 session moves one week earlier" : "\(count) sessions move one week earlier"
    }

    static func endDateText(_ plan: Service.RemoveDeloadPlan) -> String? {
        guard let before = plan.blockEndBefore, let after = plan.blockEndAfter else { return nil }
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return "Block ends \(after.formatted(f)) (was \(before.formatted(f)))"
    }

    static func removalText(_ plan: Service.RemoveDeloadPlan) -> String {
        let n = plan.removals.count
        return "\(n) deload session\(n == 1 ? "" : "s") removed"
    }

    static func refusalText(_ refusal: Service.RemoveDeloadRefusal) -> String {
        switch refusal {
        case .inactiveMeso: return "This block isn't the active one."
        case .sessionInProgress: return "A session in this block is in progress. Finish it, then try again."
        case .noInsertedDeload: return "This block has no inserted deload week."
        case .deloadStarted: return "The inserted deload has been started or logged, so it stays."
        case .mixedWeek: return "Another session sits in the deload week, so removing it would merge weeks."
        case .laterSessionCompleted: return "A later week already has a completed session, so the weeks can't shift back cleanly."
        case .dateCollision: return "Moving the schedule a week earlier would put sessions on days that are already taken."
        }
    }

    struct ApplyFailure: Error, Equatable {
        let error: Service.RemoveDeloadError
        var needsRefresh: Bool { error == .planStale }
        var message: String {
            switch error {
            case .refused(let reason): return RemoveDeloadModel.refusalText(reason) + " Nothing was changed."
            case .planStale: return "The schedule changed since the preview. Nothing was changed — review the updated preview."
            case .verificationFailed: return "The change couldn't be verified, so nothing was written."
            case .saveFailed: return "The change couldn't be saved, so nothing was written."
            }
        }
    }

    func apply(_ plan: Service.RemoveDeloadPlan) -> Result<Service.RemoveDeloadResult, ApplyFailure> {
        do {
            return .success(try Service.removeInsertedDeloadWeek(plan, in: context))
        } catch let error as Service.RemoveDeloadError {
            return .failure(.init(error: error))
        } catch {
            return .failure(.init(error: .saveFailed("\(error)")))
        }
    }
}

struct RemoveDeloadFlow: View {
    @Environment(\.modelContext) private var modelContext

    let meso: MesoBlock
    var week: Int? = nil
    let onFinish: () -> Void

    @State private var errorMessage: String?
    @State private var refreshToken = 0

    var body: some View {
        let model = RemoveDeloadModel(meso: meso, context: modelContext, week: week)
        let plan = model.plan()
        NavigationStack {
            Form {
                if let refusal = plan.refusal {
                    Section { Text(RemoveDeloadModel.refusalText(refusal)).foregroundStyle(.secondary) }
                    if !plan.collisions.isEmpty {
                        Section("Days already taken") {
                            ForEach(Array(plan.collisions.enumerated()), id: \.offset) { _, c in
                                HStack {
                                    Text(c.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    Spacer()
                                    Text("\(c.moved.dayLabel ?? "Session") → \(c.occupant.dayLabel ?? "Session")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        if let week = plan.weekIndex { Text("Week \(week) is removed.") }
                        Text(RemoveDeloadModel.removalText(plan))
                        Text(RemoveDeloadModel.moveText(count: plan.shifted.count))
                        if let end = RemoveDeloadModel.endDateText(plan) { Text(end) }
                    } footer: {
                        Text(RemoveDeloadModel.unchangedFooter)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
                }
            }
            .id(refreshToken)
            .navigationTitle(RemoveDeloadModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) } }
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive) {
                    switch model.apply(plan) {
                    case .success: onFinish()
                    case .failure(let failure):
                        errorMessage = failure.message
                        if failure.needsRefresh { refreshToken += 1 }
                    }
                } label: {
                    Text(RemoveDeloadModel.title).frame(maxWidth: .infinity)
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
