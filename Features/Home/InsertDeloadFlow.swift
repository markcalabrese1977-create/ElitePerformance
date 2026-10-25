import SwiftUI
import SwiftData

// MARK: - Model (no SwiftUI; the preview and the write both come from SessionItemEditService)

struct InsertDeloadModel {

    typealias Service = SessionItemEditService

    static let title = "Insert deload week"
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

    static func loadText(_ item: Service.DeloadItemPlan) -> String {
        if ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId) { return "BW" }
        return item.load > 0 ? "\(LoadFormatter.number(item.load)) \(LoadFormatter.unitLabel)" : "enter on the day"
    }

    static func rows(_ plan: Service.InsertDeloadPlan) -> [SessionRow] {
        plan.deloadSessions.map { s in
            SessionRow(
                date: s.date, dayLabel: s.dayLabel ?? "Session",
                items: s.items.map {
                    ItemRow(name: ExerciseCatalog.displayName(for: $0.exerciseId), prescription: $0.prescription, load: loadText($0))
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
                            Text("A deload week goes in as week \(week). Half the sets, the same rep range, 3–4 reps in reserve.")
                        }
                        Text(InsertDeloadModel.moveText(count: plan.shifted.count))
                        if let end = InsertDeloadModel.endDateText(plan) { Text(end) }
                    } footer: {
                        Text(InsertDeloadModel.unchangedFooter)
                    }

                    ForEach(Array(InsertDeloadModel.rows(plan).enumerated()), id: \.offset) { _, row in
                        Section {
                            ForEach(Array(row.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text("\(item.prescription) · \(item.load)")
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
            .navigationTitle(InsertDeloadModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    switch model.apply(plan) {
                    case .success: onFinish()
                    case .failure(let failure):
                        errorMessage = failure.message
                        if failure.needsRefresh { refreshToken += 1 }
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


// MARK: - Start next meso from this one

struct StartNextMesoModel {

    typealias Service = SessionItemEditService

    static let title = "Start next meso"
    static let unchangedFooter = "Kept: every exercise and its order, the sets for each week, rep and RIR targets, the wave pattern and your session cues. Finished sessions and your history don't change."

    let meso: MesoBlock
    let context: ModelContext
    var now: Date = Date()
    var name: String
    var startDate: Date
    /// The toggle as the lifter set it; it only counts while the meso has sessions left to remove (`needsEndNow`).
    var endOldMesoNow: Bool = false

    init(meso: MesoBlock, context: ModelContext, now: Date = Date(), name: String? = nil, startDate: Date? = nil, endOldMesoNow: Bool = false) {
        self.meso = meso
        self.context = context
        self.now = now
        self.name = name ?? Self.defaultName(for: meso)
        self.startDate = startDate ?? Self.defaultStart(for: meso, now: now)
        self.endOldMesoNow = endOldMesoNow
    }

    static func defaultName(for meso: MesoBlock) -> String { "\(meso.name) (next)" }

    /// The day after the meso's last session, or today when that has already passed.
    static func defaultStart(for meso: MesoBlock, now: Date = Date()) -> Date {
        let today = Calendar.current.startOfDay(for: now)
        return max(Service.defaultNextMesoStart(for: meso) ?? today, today)
    }

    /// Sessions of this meso dated today or later that are not finished: starting the next meso needs them gone.
    var remainingSessions: [Session] { Service.remainingSessions(of: meso, now: now) }
    var needsEndNow: Bool { !remainingSessions.isEmpty }

    /// The flag the plan actually uses: the toggle is ignored while there is nothing to end.
    var effectiveEndNow: Bool { needsEndNow && endOldMesoNow }

    func plan() -> Service.NextMesoPlan {
        Service.planNextMeso(meso: meso, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                             startDate: startDate, endOldMesoNow: effectiveEndNow, context: context, now: now)
    }

    var canCreate: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Copy

    static func refusalText(_ refusal: Service.NextMesoRefusal, remaining: Int = 0) -> String {
        switch refusal {
        case .nothingToCopy: return "This meso has no sessions to copy."
        case .sessionInProgress: return "A session in this meso is in progress. Finish it, then try again."
        case .startInPast: return "The start date has passed. Pick today or a later day."
        case .oldMesoHasRemainingSessions:
            return "This meso still has \(remaining) planned session\(remaining == 1 ? "" : "s"). Turn on \"End this meso now\" to remove them, or start after the last one."
        case .remainingSessionHasLoggedData: return "A remaining session already has logged work, so it can't be removed. Complete or clear it first."
        case .duplicateDayLabelInWeek: return "A week of this meso has two sessions of the same day type, so the weekly pattern isn't clear."
        case .dateCollision: return "A new session would land on a day that already has a session."
        }
    }

    static func summaryText(_ plan: Service.NextMesoPlan) -> String {
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let range = plan.sessions.first.map { first in
            plan.endDate.map { "\(first.date.formatted(f)) – \($0.formatted(f))" } ?? first.date.formatted(f)
        } ?? ""
        return "\(plan.weeks) week\(plan.weeks == 1 ? "" : "s") · \(plan.sessions.count) sessions · \(range)"
    }

    static func removalText(_ plan: Service.NextMesoPlan) -> String? {
        guard plan.endOldMesoNow, !plan.sessionsToDelete.isEmpty else { return nil }
        let n = plan.sessionsToDelete.count
        return "\(n) planned session\(n == 1 ? "" : "s") removed from \"\(plan.oldMeso.name)\""
    }

    struct CollisionRow: Equatable {
        let date: Date
        let newSession: String
        let occupant: String
    }

    static func collisionRows(_ plan: Service.NextMesoPlan) -> [CollisionRow] {
        plan.collisions.map { CollisionRow(date: $0.date, newSession: $0.dayLabel ?? "Session", occupant: $0.occupant.map { $0.dayLabel ?? "Session" } ?? "another new session") }
    }

    struct ItemRow: Equatable {
        let name: String
        let prescription: String
        let load: String
        let source: String
    }

    struct SessionRow: Equatable {
        let date: Date
        let dayLabel: String
        let letter: String
        let items: [ItemRow]
    }

    static func loadText(_ item: Service.NextMesoItem) -> String {
        if item.isBodyweight { return "BW" }
        return item.seed > 0 ? "\(LoadFormatter.number(item.seed)) \(LoadFormatter.unitLabel)" : "enter on the day"
    }

    static func sourceText(_ item: Service.NextMesoItem, factor: Double) -> String {
        switch item.seedSource {
        case .peak: return "\(Int((factor * 100).rounded()))% of your best"
        case .history: return "from your history"
        case .fixed: return "last lifted"
        case .bodyweight: return ""
        case .none: return "no history yet"
        }
    }

    /// The sessions of the first week, as the preview shows them.
    static func firstWeekRows(_ plan: Service.NextMesoPlan) -> [SessionRow] {
        plan.firstWeek.map { s in
            SessionRow(
                date: s.date, dayLabel: s.dayLabel ?? "Session", letter: s.letter.isEmpty ? "" : s.letter.uppercased(),
                items: s.items.map {
                    ItemRow(name: ExerciseCatalog.displayName(for: $0.exerciseId), prescription: $0.prescription,
                            load: loadText($0), source: sourceText($0, factor: plan.peakFactor))
                }
            )
        }
    }

    struct ApplyFailure: Error, Equatable {
        let error: Service.NextMesoError
        var needsRefresh: Bool { error == .planStale }
        var message: String {
            switch error {
            case .refused(let reasons):
                return (reasons.first.map { StartNextMesoModel.refusalText($0) } ?? "It can't be started.") + " Nothing was changed."
            case .planStale: return "Your plan changed since the preview. Nothing was changed — review the updated preview."
            case .verificationFailed: return "The new meso couldn't be verified, so nothing was written."
            case .saveFailed: return "The new meso couldn't be saved, so nothing was written."
            }
        }
    }

    func apply(_ plan: Service.NextMesoPlan) -> Result<Service.NextMesoResult, ApplyFailure> {
        do {
            return .success(try Service.startNextMeso(plan, in: context))
        } catch let error as Service.NextMesoError {
            return .failure(.init(error: error))
        } catch {
            return .failure(.init(error: .saveFailed("\(error)")))
        }
    }
}

/// "Start next meso from this one": name, start date, whether to end the current meso now, a preview of
/// the first week with its starting loads, then create.
struct StartNextMesoFlow: View {
    @Environment(\.modelContext) private var modelContext

    let meso: MesoBlock
    let onFinish: () -> Void

    @State private var name: String
    @State private var startDate: Date
    @State private var endOldMesoNow = false
    @State private var errorMessage: String?
    @State private var refreshToken = 0

    init(meso: MesoBlock, onFinish: @escaping () -> Void) {
        self.meso = meso
        self.onFinish = onFinish
        _name = State(initialValue: StartNextMesoModel.defaultName(for: meso))
        _startDate = State(initialValue: StartNextMesoModel.defaultStart(for: meso))
    }

    var body: some View {
        let model = StartNextMesoModel(meso: meso, context: modelContext, name: name, startDate: startDate, endOldMesoNow: endOldMesoNow)
        let plan = model.plan()
        let remaining = model.remainingSessions
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    DatePicker("Start date", selection: $startDate,
                               in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                } footer: {
                    Text("Each day type keeps its usual weekday, and weeks start on your first day.")
                }

                if model.needsEndNow {
                    Section {
                        Toggle("End this meso now", isOn: $endOldMesoNow)
                        if endOldMesoNow {
                            DisclosureGroup("Sessions removed (\(plan.sessionsToDelete.count))") {
                                ForEach(plan.sessionsToDelete.sorted { $0.date < $1.date }, id: \.persistentModelID) { s in
                                    HStack {
                                        Text(s.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                        Spacer()
                                        Text(s.dayLabel ?? "Session").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("\"\(meso.name)\" still has \(remaining.count) planned session\(remaining.count == 1 ? "" : "s"). Ending it removes them; finished sessions stay.")
                    }
                }

                if !plan.refusals.isEmpty {
                    Section {
                        ForEach(Array(plan.refusals.enumerated()), id: \.offset) { _, r in
                            Text(StartNextMesoModel.refusalText(r, remaining: remaining.count)).foregroundStyle(.secondary)
                        }
                    }
                    let collisions = StartNextMesoModel.collisionRows(plan)
                    if !collisions.isEmpty {
                        Section("Days already taken") {
                            ForEach(Array(collisions.enumerated()), id: \.offset) { _, c in
                                HStack {
                                    Text(c.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    Spacer()
                                    Text("\(c.newSession) → \(c.occupant)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text(StartNextMesoModel.summaryText(plan))
                        if let removal = StartNextMesoModel.removalText(plan) { Text(removal) }
                    } footer: {
                        Text(StartNextMesoModel.unchangedFooter)
                    }

                    ForEach(Array(StartNextMesoModel.firstWeekRows(plan).enumerated()), id: \.offset) { _, row in
                        Section {
                            ForEach(Array(row.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text([item.prescription, item.load, item.source].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            Text("\(row.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(row.dayLabel)"
                                 + (row.letter.isEmpty ? "" : " · \(row.letter)"))
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
                }
            }
            .id(refreshToken)
            .navigationTitle(StartNextMesoModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    switch model.apply(plan) {
                    case .success:
                        Haptics.success()
                        onFinish()
                    case .failure(let failure):
                        errorMessage = failure.message
                        if failure.needsRefresh { refreshToken += 1 }
                    }
                } label: {
                    Text("Create next meso").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!plan.isApplicable || !model.canCreate)
                .padding()
                .background(.bar)
            }
        }
    }
}
