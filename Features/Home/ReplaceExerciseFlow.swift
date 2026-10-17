import SwiftUI
import SwiftData

// MARK: - Model (no SwiftUI; everything the screens show comes from SessionItemEditService)

enum ReplaceExerciseSurface {
    case programTab
    case todayInSession
}

enum ReplaceScopeChoice: Hashable {
    case thisSession
    case allRemaining
}

/// The decisions behind the replace-exercise flow, kept out of the views so they can be tested.
/// Every plan shown to the user — and every write — comes from `SessionItemEditService`.
struct ReplaceExerciseModel {

    static let todayInSessionNote = "Finish the session, then replace the rest from the Program tab."
    static let unchangedFooter = "Unchanged: completed sessions, other days, every other exercise."
    static let enterOnTheDay = "enter on the day"

    let session: Session
    let item: SessionItem
    /// Canonical id of the exercise being put in.
    let replacementId: String
    let context: ModelContext
    var now: Date = Date()

    var dayLabel: String? {
        let trimmed = session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : session.dayLabel
    }
    var fromName: String { ExerciseCatalog.displayName(for: item.exerciseId) }
    var toName: String { ExerciseCatalog.displayName(for: replacementId) }

    // MARK: Scopes

    /// Mid-session (Today tab) only the single-session swap exists; the Program tab offers both.
    /// "All remaining" also needs a block and a day type to match on.
    static func availableScopes(surface: ReplaceExerciseSurface, session: Session) -> [ReplaceScopeChoice] {
        switch surface {
        case .todayInSession:
            return [.thisSession]
        case .programTab:
            let hasDay = !(session.dayLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return session.meso != nil && hasDay ? [.thisSession, .allRemaining] : [.thisSession]
        }
    }

    // MARK: Plans

    func plan(for scope: ReplaceScopeChoice) -> SessionItemEditService.ReplacePlan? {
        guard let meso = session.meso else { return nil }
        let serviceScope: SessionItemEditService.ReplaceScope
        switch scope {
        case .thisSession: serviceScope = .thisSession(session)
        case .allRemaining: serviceScope = .allRemaining
        }
        return SessionItemEditService.planReplace(
            meso: meso, dayLabel: session.dayLabel, from: item.exerciseId, to: replacementId,
            scope: serviceScope, context: context, now: now
        )
    }

    // MARK: Copy

    func title(for scope: ReplaceScopeChoice, plan: SessionItemEditService.ReplacePlan?) -> String {
        switch scope {
        case .thisSession:
            return "This session only"
        case .allRemaining:
            return "All remaining \(dayLabel ?? "") sessions (\(plan?.targets.count ?? 0))"
        }
    }

    /// Shown under a single-session preview: the later sessions keep the old exercise.
    func thisSessionNote() -> String {
        "Later \(dayLabel ?? "same-day") sessions keep \(fromName); carry-forward won't connect them."
    }

    static func confirmTitle(count: Int) -> String { "Replace \(count)" }

    static func letter(_ waveRaw: String?) -> String {
        let w = waveRaw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch w {
        case "": return "–"
        case "deload": return "Deload"
        default: return w.uppercased()
        }
    }

    static func loadText(_ seed: Double?) -> String {
        guard let seed else { return enterOnTheDay }
        return seed == seed.rounded() ? "\(Int(seed)) lb" : String(format: "%g lb", seed)
    }

    struct Row: Equatable {
        let date: Date
        let wave: String
        let prescription: String
        let load: String
    }

    static func rows(_ plan: SessionItemEditService.ReplacePlan) -> [Row] {
        plan.targets.map { Row(date: $0.date, wave: letter($0.waveRaw), prescription: $0.prescription, load: loadText($0.seedLoad)) }
    }

    static func reasonText(_ reason: SessionItemEditService.RefusalReason) -> String {
        switch reason {
        case .unsafe: return "already started or logged"
        case .alreadyContainsReplacement: return "already has the new exercise"
        case .inactiveMeso: return "block isn't active"
        case .sameExercise: return "same exercise"
        case .notApplicable: return "doesn't have this exercise"
        }
    }

    // MARK: Apply

    /// Applies exactly the plan that was shown. On failure nothing is written and the message says why.
    func apply(_ plan: SessionItemEditService.ReplacePlan) -> Result<SessionItemEditService.ApplyResult, ApplyFailure> {
        do {
            return .success(try SessionItemEditService.apply(plan, in: context))
        } catch let error as SessionItemEditService.ReplaceError {
            return .failure(ApplyFailure(error: error))
        } catch {
            return .failure(ApplyFailure(error: .saveFailed("\(error)")))
        }
    }

    struct ApplyFailure: Error, Equatable {
        let error: SessionItemEditService.ReplaceError

        /// The plan no longer matches the store; the preview should be rebuilt.
        var needsRefresh: Bool {
            if case .planStale = error { return true }
            return false
        }

        var message: String {
            switch error {
            case .nothingToReplace:
                return "Nothing to replace."
            case .sessionInProgress:
                return "A session in this block is in progress. Finish it, then try again. Nothing was changed."
            case .planStale(let planned, let live):
                return "These sessions changed since the preview (\(planned) planned, \(live) now). Nothing was changed — review the updated preview."
            case .verificationFailed:
                return "The change couldn't be verified, so nothing was written."
            case .saveFailed:
                return "The change couldn't be saved, so nothing was written."
            }
        }
    }
}

// MARK: - Views

/// Pick a replacement (reusing `ProgramExerciseSwapSheet`), then choose the scope and review the preview.
struct ReplaceExerciseFlow: View {
    @Environment(\.modelContext) private var modelContext

    let session: Session
    let item: SessionItem
    var surface: ReplaceExerciseSurface = .programTab
    let onFinish: () -> Void

    @State private var chosen: CatalogExercise?

    var body: some View {
        if let chosen {
            ReplacePreviewSheet(
                model: ReplaceExerciseModel(
                    session: session, item: item,
                    replacementId: ExerciseCatalog.canonicalExerciseId(for: chosen.id), context: modelContext
                ),
                surface: surface,
                onBack: { self.chosen = nil },
                onFinish: onFinish
            )
        } else {
            ProgramExerciseSwapSheet(
                currentExerciseId: item.exerciseId,
                currentExerciseName: ExerciseCatalog.displayName(for: ExerciseCatalog.canonicalExerciseId(for: item.exerciseId)),
                onSelect: { chosen = $0 },
                onCancel: onFinish
            )
        }
    }
}

private struct ReplacePreviewSheet: View {
    let model: ReplaceExerciseModel
    let surface: ReplaceExerciseSurface
    let onBack: () -> Void
    let onFinish: () -> Void

    @State private var scope: ReplaceScopeChoice = .thisSession
    @State private var plans: [ReplaceScopeChoice: SessionItemEditService.ReplacePlan] = [:]
    @State private var errorMessage: String?

    private var scopes: [ReplaceScopeChoice] {
        ReplaceExerciseModel.availableScopes(surface: surface, session: model.session)
    }
    private var plan: SessionItemEditService.ReplacePlan? { plans[scope] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(scopes, id: \.self) { choice in
                        Button { scope = choice; errorMessage = nil } label: {
                            HStack {
                                Text(model.title(for: choice, plan: plans[choice]))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if scope == choice { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } header: {
                    Text("Replace \(model.fromName) with \(model.toName)")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
                }

                if let plan {
                    Section {
                        if plan.targets.isEmpty {
                            Text("Nothing to replace in this scope.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(ReplaceExerciseModel.rows(plan).enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                        .font(.body)
                                    Text(row.wave)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                    Spacer()
                                    Text(row.prescription).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text("Starts at \(row.load)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Preview")
                    } footer: {
                        if scope == .thisSession, !plan.targets.isEmpty {
                            Text(model.thisSessionNote())
                        }
                    }

                    if !plan.refusals.isEmpty {
                        Section("Skipped") {
                            ForEach(Array(plan.refusals.enumerated()), id: \.offset) { _, refusal in
                                HStack {
                                    Text(refusal.session.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    Spacer()
                                    Text(ReplaceExerciseModel.reasonText(refusal.reason))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section { Text("This session isn't part of a block, so it can't be replaced here.").foregroundStyle(.secondary) }
                }

                Section { } footer: { Text(ReplaceExerciseModel.unchangedFooter) }
            }
            .navigationTitle("Replace Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back", action: onBack) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    confirm()
                } label: {
                    Text(ReplaceExerciseModel.confirmTitle(count: plan?.targets.count ?? 0))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!(plan?.isApplicable ?? false))
                .padding()
                .background(.bar)
            }
            .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        var fresh: [ReplaceScopeChoice: SessionItemEditService.ReplacePlan] = [:]
        for choice in scopes { fresh[choice] = model.plan(for: choice) }
        plans = fresh
        if !scopes.contains(scope) { scope = .thisSession }
    }

    private func confirm() {
        guard let plan else { return }
        switch model.apply(plan) {
        case .success:
            onFinish()
        case .failure(let failure):
            errorMessage = failure.message
            if failure.needsRefresh { refresh() }
        }
    }
}
