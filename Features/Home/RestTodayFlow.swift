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
