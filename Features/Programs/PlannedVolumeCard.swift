// Features/Programs/PlannedVolumeCard.swift
import SwiftUI
import SwiftData

/// "Weekly volume": the planned weekly hard sets per muscle of a block that is about to be created, next to the previous
/// block's actual average and the lifter's ranges. Advisory only: it never blocks anything. Collapsed it is one summary line;
/// expanded, below and above rows come first. It recomputes whenever the preview's template, overrides or plan change.
struct PlannedVolumeCard: View {

    /// What the preview holds.
    enum Input {
        /// Onboarding / Change program / New program from template: the fitted template and the preview's overrides.
        case template(ProgramTemplate, PreviewOverrides)
        /// Start next meso: the plan's sessions, compared with the block being copied.
        case nextMeso(SessionItemEditService.NextMesoPlan)
    }

    let input: Input

    @Environment(\.modelContext) private var context
    @Query private var customs: [CustomExercise]
    @Query private var profiles: [UserProfile]
    @State private var last: LastBlockComparison.Source?
    @State private var expanded = false

    private var planned: PlannedVolume.Result {
        switch input {
        case .template(let template, let overrides):
            return PlannedVolume.weeklyHardSets(template: template, overrides: overrides, customs: customs, profile: profiles.first)
        case .nextMeso(let plan):
            return PlannedVolume.weeklyHardSets(plan: plan, customs: customs, profile: profiles.first)
        }
    }

    var body: some View {
        let result = planned
        let model = PlannedVolumeCardModel(planned: result, last: last)
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weekly volume").font(.subheadline.bold()).foregroundStyle(.primary)
                        Text(result.isEmpty ? "No training weeks to plan" : model.summaryLine)
                            .font(.caption).foregroundStyle(model.below.isEmpty && model.above.isEmpty ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("plannedVolumeSummary")
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plannedVolumeToggle")

            if expanded && !result.isEmpty {
                VStack(spacing: 4) {
                    HStack {
                        Text("Muscle").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Planned").frame(width: 54, alignment: .trailing)
                        if model.hasComparison { Text("Last block").frame(width: 62, alignment: .trailing) }
                        Text("Range").frame(width: 48, alignment: .trailing)
                        Text("").frame(width: 50)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    ForEach(model.rows) { row in
                        HStack {
                            Text(row.muscle.displayName).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "%.1f", row.planned)).font(.caption.bold()).frame(width: 54, alignment: .trailing)
                            if model.hasComparison {
                                Text(row.lastBlock.map { String(format: "%.1f", $0) } ?? "–")
                                    .font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
                            }
                            Text("\(Int(row.range.min))–\(Int(row.range.max))").font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                            Text(row.status.rawValue).font(.caption2).foregroundStyle(color(row.status)).frame(width: 50, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if model.unmappedSets > 0 {
                        HStack {
                            Text("Unmapped custom sets: \(LoadFormatter.grouped(model.unmappedSets))").font(.caption)
                            Spacer()
                        }
                        .padding(.top, 4)
                        .accessibilityIdentifier("plannedVolumeUnmapped")
                    }
                    Text(footer(model)).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .task(id: loadKey) { loadLastBlock() }
    }

    private func footer(_ model: PlannedVolumeCardModel) -> String {
        var text = PlannedVolumeCardModel.footer
        if model.hasComparison, let name = model.lastBlockName {
            text += " Last block: \(name)\(model.lastBlockIsActive ? " (current)" : "")."
        }
        return text
    }

    private func color(_ s: MuscleVolume.Status) -> Color {
        switch s { case .below: return .orange; case .within: return .green; case .above: return .red }
    }

    /// Reload the comparison when the block it compares with could have changed (the copied block for Start next meso).
    private var loadKey: String {
        if case .nextMeso(let plan) = input { return LastBlockComparison.key(for: plan.oldMeso) }
        return "rule"
    }

    private func loadLastBlock() {
        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let engine = AnalyticsEngine(sessions: sessions, customExercises: customs, bodyWeight: profiles.first?.bodyWeight)
        let now = Date()
        switch input {
        case .nextMeso(let plan):
            // The block being copied is the previous block.
            last = LastBlockComparison.source(snapshot: engine.snapshot, customs: customs, profile: profiles.first, asOf: now,
                                              explicitMesoKey: LastBlockComparison.key(for: plan.oldMeso))
        case .template:
            let blocks = (try? context.fetch(FetchDescriptor<MesoBlock>())) ?? []
            let activeKey = blocks.first { $0.status == .active && !$0.isMaintenance }.map(LastBlockComparison.key(for:))
            last = LastBlockComparison.source(snapshot: engine.snapshot, customs: customs, profile: profiles.first, asOf: now, activeMesoKey: activeKey)
        }
    }
}
