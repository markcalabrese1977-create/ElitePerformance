import SwiftUI
import SwiftData

struct ExerciseSessionDetailView: View {
    @Environment(\.loadUnit) private var unit
    let session: Session
    let exerciseId: String
    let exerciseName: String

    private var canonicalExerciseId: String {
        ExerciseCatalog.resolvedExerciseId(
            rawId: exerciseId,
            snapshotName: exerciseName,
            fallbackName: exerciseName
        )
    }

    private var matchedItem: SessionItem? {
        session.items.first(where: {
            ExerciseCatalog.resolvedExerciseId(
                rawId: $0.exerciseId,
                snapshotName: $0.exerciseNameSnapshot,
                fallbackName: nil
            ) == canonicalExerciseId
        })
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(session.date, format: .dateTime.month().day().year())
                    Spacer()
                    Text("Week \(session.weekIndex)")
                        .foregroundStyle(.secondary)
                }
            }

            if let item = matchedItem {
                Section("Sets") {
                    let setCount = max(
                        item.plannedRepsBySet.count,
                        item.plannedLoadsBySet.count,
                        item.actualReps.count,
                        item.actualLoads.count,
                        item.actualRIRs.count
                    )

                    if setCount == 0 {
                        Text("No set detail found for this session.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(0..<setCount, id: \.self) { idx in
                            let actualLoad = idx < item.actualLoads.count ? item.actualLoads[idx] : 0.0
                            let actualReps = idx < item.actualReps.count ? item.actualReps[idx] : 0
                            if actualLoad > 0 || actualReps > 0 {
                                setRow(item: item, idx: idx)
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("This exercise wasn’t found in this session.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(exerciseName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func setRow(item: SessionItem, idx: Int) -> some View {
        let reps = (idx < item.actualReps.count ? item.actualReps[idx] : 0) > 0
            ? item.actualReps[idx]
            : (idx < item.plannedRepsBySet.count ? item.plannedRepsBySet[idx] : 0)

        let actualLoad = (idx < item.actualLoads.count) ? item.actualLoads[idx] : 0
        // A bodyweight item carries no plan load (an old phantom on a finished one is not shown).
        let plannedLoad = (idx < item.plannedLoadsBySet.count && !ExerciseCatalog.isBodyweight(exerciseId: item.exerciseId)) ? item.plannedLoadsBySet[idx] : 0
        let load = actualLoad > 0 ? actualLoad : plannedLoad

        // Logged RIR as "RIR n" (a word in Simple); a set with none shows the plan, marked "plan RIR n". Off shows no effort line.
        let effortLine: String? = {
            if let recorded = RIREntry.recorded(item, at: idx), (idx < item.actualReps.count && item.actualReps[idx] > 0) {
                let s = EffortTracking.loggedSuffix(recorded)
                if s.isEmpty { return nil }
                return EffortTracking.mode == .simple ? String(s.dropFirst(3)) : "RIR \(recorded)"
            }
            return EffortTracking.aimText(item.targetRIR)
        }()

        HStack {
            Text("Set \(idx + 1)")
                .font(.subheadline)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(formatLoad(load)) × \(reps)")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                if let effortLine {
                    // A planned (aim) line is italic; a logged one is not.
                    Text(effortLine)
                        .font(.caption)
                        .italic(effortLine.hasPrefix("aim:"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatLoad(_ v: Double) -> String {
        if v == 0, ExerciseCatalog.isBodyweight(exerciseId: canonicalExerciseId) { return "BW" }
        return LoadFormatter(unit: unit).compact(v)
    }
}
