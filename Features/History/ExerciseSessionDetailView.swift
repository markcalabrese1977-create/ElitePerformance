import SwiftUI
import SwiftData

struct ExerciseSessionDetailView: View {
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
        let plannedLoad = (idx < item.plannedLoadsBySet.count) ? item.plannedLoadsBySet[idx] : 0
        let load = actualLoad > 0 ? actualLoad : plannedLoad

        let rir: String = {
            if idx < item.actualRIRs.count, item.actualRIRs[idx] > 0 {
                return "\(item.actualRIRs[idx])"
            }
            return "\(item.targetRIR)"
        }()

        HStack {
            Text("Set \(idx + 1)")
                .font(.subheadline)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(formatLoad(load)) × \(reps)")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("RIR \(rir)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func formatLoad(_ v: Double) -> String {
        if v == 0 { return "BW" }
        if v.rounded(.towardZero) == v { return String(Int(v)) }
        return String(format: "%.1f", v)
    }
}
