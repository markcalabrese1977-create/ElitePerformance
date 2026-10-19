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

    func plan() -> Service.InsertDeloadPlan {
        Service.planInsertDeloadWeek(meso: meso, context: context, now: now)
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

    var body: some View {
        let model = InsertDeloadModel(meso: meso, context: modelContext)
        let plan = model.plan()
        NavigationStack {
            Form {
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
