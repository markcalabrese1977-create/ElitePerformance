import SwiftUI
import SwiftData

// MARK: - Start next meso from this one

struct StartNextMesoModel {

    typealias Service = SessionItemEditService

    static let title = "Start next meso"
    static var unchangedFooter: String { unchangedFooter(mode: EffortTracking.mode) }
    static func unchangedFooter(mode: EffortMode) -> String {
        let targets: String
        switch mode {
        case .detailed: targets = "rep and RIR targets"
        case .simple: targets = "rep and effort targets"
        case .off: targets = "rep targets"
        }
        return "Kept: every exercise and its order, the sets for each week, \(targets), the wave pattern and your session cues. Finished sessions and your history don't change."
    }

    let meso: MesoBlock
    let context: ModelContext
    var now: Date = Date()
    var name: String
    var startDate: Date
    /// The toggle as the lifter set it; it only counts while the meso has sessions left to remove (`needsEndNow`).
    var endOldMesoNow: Bool = false
    /// "Keep weeks the same": no A/B/C weeks in the next meso (offered only when this one has them).
    var keepWeeksTheSame: Bool = false

    init(meso: MesoBlock, context: ModelContext, now: Date = Date(), name: String? = nil, startDate: Date? = nil, endOldMesoNow: Bool = false,
         keepWeeksTheSame: Bool = false) {
        self.meso = meso
        self.context = context
        self.now = now
        self.name = name ?? Self.defaultName(for: meso)
        self.startDate = startDate ?? Self.defaultStart(for: meso, now: now)
        self.endOldMesoNow = endOldMesoNow
        self.keepWeeksTheSame = keepWeeksTheSame
    }

    /// True when this meso has week types (A/B/C), so "Keep weeks the same" means something.
    var offersKeepWeeksTheSame: Bool { !Service.sameWeekTypes(in: meso).isEmpty }
    var keptWeekType: String? { Service.defaultKeptWeekType(in: meso) }

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
                             startDate: startDate, endOldMesoNow: effectiveEndNow,
                             keepWeeksTheSame: keepWeeksTheSame && offersKeepWeeksTheSame, context: context, now: now)
    }

    var canCreate: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Copy

    static func refusalText(_ refusal: Service.NextMesoRefusal, remaining: Int = 0, mesoName: String = "This meso", lastRemaining: Date? = nil) -> String {
        switch refusal {
        case .nothingToCopy: return "This meso has no sessions to copy."
        case .sessionInProgress: return "A session in this meso is in progress. Finish it, then try again."
        case .startInPast: return "The start date has passed. Pick today or a later day."
        case .oldMesoHasRemainingSessions:
            let count = remaining > 0 ? "\(remaining) planned session\(remaining == 1 ? "" : "s")" : "planned sessions left"
            let last = lastRemaining.map { " (last: \($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())))" } ?? ""
            return "\(mesoName) still has \(count)\(last). Finish them first, or turn on \"End this meso now\" to remove them."
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

    static func loadText(_ item: Service.NextMesoItem, unit: LoadUnit = .lb) -> String {
        if item.isBodyweight { return "BW" }
        return item.seed > 0 ? LoadFormatter(unit: unit).text(item.seed) : "enter on the day"
    }

    static func sourceText(_ item: Service.NextMesoItem, factor: Double) -> String {
        switch item.seedSource {
        case .peak: return item.seedReason ?? "\(Int(((item.seedFactor ?? factor) * 100).rounded()))% of your best"
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
                            load: loadText($0, unit: plan.unit), source: sourceText($0, factor: plan.peakFactor))
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
    @StateObject private var seedGuard = SeedBackupGuard()

    let meso: MesoBlock
    let onFinish: () -> Void

    @State private var name: String
    @State private var startDate: Date
    @State private var endOldMesoNow = false
    @State private var keepWeeksTheSame = false
    @State private var errorMessage: String?
    @State private var refreshToken = 0

    init(meso: MesoBlock, onFinish: @escaping () -> Void) {
        self.meso = meso
        self.onFinish = onFinish
        _name = State(initialValue: StartNextMesoModel.defaultName(for: meso))
        _startDate = State(initialValue: StartNextMesoModel.defaultStart(for: meso))
    }

    var body: some View {
        let model = StartNextMesoModel(meso: meso, context: modelContext, name: name, startDate: startDate, endOldMesoNow: endOldMesoNow,
                                       keepWeeksTheSame: keepWeeksTheSame)
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

                if model.offersKeepWeeksTheSame {
                    Section {
                        Toggle("Keep weeks the same", isOn: $keepWeeksTheSame)
                    } footer: {
                        Text("Every week uses one prescription per exercise, the \(model.keptWeekType?.uppercased() ?? "latest") week's, with no A/B/C weeks. The next meso after this one stays that way.")
                    }
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
                            Text(StartNextMesoModel.refusalText(r, remaining: remaining.count, mesoName: meso.name,
                                                                lastRemaining: remaining.map(\.date).max())).foregroundStyle(.secondary)
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

                    // Planned weekly hard sets per muscle against the block being copied. Advisory; a maintenance copy has no hard sets.
                    if !plan.isMaintenance {
                        Section {
                            PlannedVolumeCard(input: .nextMeso(plan))
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }

                    ForEach(Array(StartNextMesoModel.firstWeekRows(plan).enumerated()), id: \.offset) { _, row in
                        Section {
                            ForEach(Array(row.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text([EffortTracking.localize(item.prescription), item.load, item.source].filter { !$0.isEmpty }.joined(separator: " · "))
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
            .seedBackupGuard(seedGuard)
            .navigationTitle(StartNextMesoModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onFinish) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    // A verified backup first; if it fails the meso is not created (see SeedBackupGuard).
                    seedGuard.run(container: modelContext.container) {
                        switch model.apply(plan) {
                        case .success:
                            Haptics.success()
                            onFinish()
                        case .failure(let failure):
                            errorMessage = failure.message
                            if failure.needsRefresh { refreshToken += 1 }
                        }
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
