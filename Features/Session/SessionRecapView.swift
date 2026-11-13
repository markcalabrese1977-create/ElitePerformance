import SwiftUI
import SwiftData

struct LoadOverridePromptRow: View {
    @Bindable var item: SessionItem

    private var exerciseName: String {
        ExerciseCatalog.displayName(for: item.exerciseId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("\(exerciseName) — you went lighter than planned")
                    .font(.subheadline)
            }

            Text("Want to note why? This helps the engine make better load calls next session.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let reason = item.loadOverrideReason {
                HStack {
                    Text(reason.displayName)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())

                    Button("Clear") {
                        item.loadOverrideReason = nil
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(LoadOverrideReason.allCases, id: \.self) { reason in
                        Button(reason.displayName) {
                            item.loadOverrideReason = reason
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray6))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SessionItem helpers (shared by the live session screens)

extension SessionItem {

    /// Planned set count from the program. If the program didn't specify per-set reps,
    /// fall back to targetSets.
    var plannedSetCount: Int {
        if plannedRepsBySet.count > 0 {
            return plannedRepsBySet.count
        } else {
            return max(targetSets, 1)
        }
    }

    /// Planned top reps from the program or targetReps.
    var plannedTopReps: Int {
        if let maxFromPlan = plannedRepsBySet.max() {
            return maxFromPlan
        } else {
            return targetReps
        }
    }



    /// Total volume = sum(load * reps) across logged sets.
    var totalVolume: Double {
        let count = min(actualReps.count, actualLoads.count)
        guard count > 0 else { return 0 }

        var sum: Double = 0
        for i in 0..<count {
            let reps = actualReps[i]
            let load = actualLoads[i]
            if reps > 0 && load > 0 {
                sum += Double(reps) * load
            }
        }
        return sum
    }

    /// Best reps across logged sets.
    var bestReps: Int {
        actualReps.max() ?? 0
    }

    /// Index of the best (highest reps) set with non-zero load/reps.
    var bestSetIndex: Int? {
        let count = min(actualReps.count, actualLoads.count)
        guard count > 0 else { return nil }

        var bestIdx: Int?
        var bestRepsValue = -1

        for i in 0..<count {
            let reps = actualReps[i]
            let load = actualLoads[i]
            if reps > 0 && load > 0 && reps > bestRepsValue {
                bestRepsValue = reps
                bestIdx = i
            }
        }
        return bestIdx
    }

    /// Human-readable description of the top set, including RP pattern if used.
    var bestSetDescription: String? { bestSetDescription(unit: .lb) }

    func bestSetDescription(unit: LoadUnit) -> String? {
        guard let idx = bestSetIndex else { return nil }
        guard idx < actualLoads.count, idx < actualReps.count else { return nil }

        let load = actualLoads[idx]
        let reps = actualReps[idx]
        guard reps > 0, load > 0 else { return nil }

        let base = "\(LoadFormatter(unit: unit).oneDecimal(load)) x \(reps)"

        let usedRP = idx < usedRestPauseFlags.count ? usedRestPauseFlags[idx] : false
        let pattern = idx < restPausePatternsBySet.count ? restPausePatternsBySet[idx] : ""

        let usedDrop = idx < dropSetPatternsBySet.count ? !dropSetPatternsBySet[idx].isEmpty : false
        let dropPattern = idx < dropSetPatternsBySet.count ? Self.shownDropPattern(dropSetPatternsBySet[idx], unit: unit) : ""

        if usedRP && !pattern.isEmpty && usedDrop {
            return base + " (RP: \(pattern)) + Drop: \(dropPattern)"
        } else if usedRP && !pattern.isEmpty {
            return base + " (RP: \(pattern))"
        } else if usedDrop {
            return base + " + Drop: \(dropPattern)"
        } else {
            return base
        }
    }


    /// A stored drop pattern ("120x12,100x10", lb) shown in `unit`. lb: the pattern as stored.
    static func shownDropPattern(_ pattern: String, unit: LoadUnit) -> String {
        guard unit != .lb else { return pattern }
        return DropSetEntry.parse(from: pattern, unit: unit).map { "\($0.loadText)x\($0.repsText)" }.joined(separator: ",")
    }

    func dropSetDescription(forSetAt index: Int, unit: LoadUnit = .lb) -> String? {
        guard index < dropSetPatternsBySet.count else { return nil }
        let pattern = dropSetPatternsBySet[index]
        guard !pattern.isEmpty else { return nil }
        let entries = DropSetEntry.parse(from: pattern, unit: unit)
        if entries.isEmpty { return "Drop set" }
        return entries.enumerated().map { i, entry in
            "Drop \(i + 1): \(entry.loadText) × \(entry.repsText)"
        }.joined(separator: "\n")
    }
}
