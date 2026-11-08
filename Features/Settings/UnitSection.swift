import SwiftUI
import SwiftData

/// Settings > Units. Switching changes how every load is shown and typed, right away: stored loads are always lb, so
/// history is never rewritten. The smallest increment (stored in the lifter's unit) resets to the new unit's default
/// after a confirm, and the planned loads can then be rounded to the new unit's steps (inline preview, like the max
/// clamp). Cancel writes nothing.
struct UnitSection: View {
    @Bindable var profile: UserProfile
    @Environment(\.modelContext) private var modelContext

    @State private var pendingUnit: LoadUnit?
    @State private var roundPlan: SessionItemEditService.RoundPlan?
    @State private var roundError: String?

    private var confirmTitle: String { "Switch to \(pendingUnit?.label ?? "")?" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Units")
                Spacer()
                Picker("Units", selection: Binding(
                    get: { profile.loadUnit },
                    set: { newUnit in if newUnit != profile.loadUnit { pendingUnit = newUnit } }
                )) {
                    ForEach(LoadUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            if let plan = roundPlan {
                VStack(alignment: .leading, spacing: 6) {
                    Text(SessionItemEditService.roundPreviewTitle(plan))
                        .font(.subheadline.weight(.semibold))
                    Text(SessionItemEditService.roundPreviewDetail(plan))
                        .font(.footnote)
                    if let roundError {
                        Text(roundError).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Keep as is") { roundPlan = nil; roundError = nil }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Round") { applyRound(plan) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
            }
        }
        .alert(confirmTitle, isPresented: Binding(get: { pendingUnit != nil }, set: { if !$0 { pendingUnit = nil } })) {
            Button("Switch") { if let unit = pendingUnit { switchTo(unit) } }
            Button("Cancel", role: .cancel) { pendingUnit = nil }
        } message: {
            if let unit = pendingUnit {
                Text("Loads are shown and typed in \(unit.label) from now on. Logged history is not changed. "
                     + "Your smallest increment resets to \(LoadFormatter(unit: unit).textInUnit(defaultIncrement(for: unit))).")
            }
        }
    }

    private func defaultIncrement(for unit: LoadUnit) -> Double {
        UnitAwareRounding.defaultIncrement(unit: unit, coarse: profile.equipmentProfile == .dumbbellsOnly)
    }

    private func switchTo(_ unit: LoadUnit) {
        pendingUnit = nil
        roundError = nil
        profile.loadUnit = unit
        profile.minLoadIncrement = defaultIncrement(for: unit)
        try? modelContext.save()
        let custom = (try? modelContext.fetch(FetchDescriptor<CustomExercise>())) ?? []
        let plan = SessionItemEditService.planRoundToUnit(
            meso: SessionItemEditService.activeMeso(in: modelContext), unit: unit,
            increment: profile.minLoadIncrement, profile: profile, customExercises: custom
        )
        roundPlan = plan.isApplicable ? plan : nil
    }

    private func applyRound(_ plan: SessionItemEditService.RoundPlan) {
        let custom = (try? modelContext.fetch(FetchDescriptor<CustomExercise>())) ?? []
        do {
            try SessionItemEditService.applyRoundToUnit(plan, profile: profile, customExercises: custom, in: modelContext)
            roundPlan = nil
            roundError = nil
        } catch {
            roundError = "Nothing was changed: \(error)"
        }
    }
}
