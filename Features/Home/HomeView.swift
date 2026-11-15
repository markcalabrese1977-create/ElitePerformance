import SwiftUI
import SwiftData

/// Program tab = Program hub.
/// Shows the current block by default, with a toolbar button to re-run onboarding
/// (Change Program). Session history is its own view used in the History tab.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var mesoBlocks: [MesoBlock]
    @Query private var profiles: [UserProfile]

    @State private var showingChangeProgram = false

    // Meso summary (end-of-meso flow)
    @State private var showMesoSummary = false

    // Meso rollover guard (fallback when no active meso or summary dismissed)
    @State private var showMesoRolloverGuard = false
    @State private var guardRescheduleDate = Date()

    // Deferred replace/apply after onboarding dismisses
    @State private var pendingOnboardingResult: OnboardingResult?
    @State private var pendingExerciseOverrides: PreviewOverrides = .empty
    @StateObject private var seedGuard = SeedBackupGuard()

    /// Change Program, after the wizard: what it would delete, shown before anything is deleted.
    struct PendingReplace {
        let result: OnboardingResult
        let overrides: PreviewOverrides
        let plan: DUPProgramReplaceService.Plan
    }
    @State private var pendingReplace: PendingReplace?

    // Start date seeded into the onboarding flow. Set from the meso-summary
    // picker when arriving via "Start new hypertrophy meso"; reset to today
    // when the user opens Change Program directly from the toolbar.
    @State private var pendingMesoStartDate: Date = Date()

    private var activeMeso: MesoBlock? {
        mesoBlocks.first { $0.status == .active }
    }

    var body: some View {
        NavigationStack {
            ProgramPlanView(onViewMesoSummary: activeMeso != nil ? {
                            showMesoSummary = true
                        } : nil)
                .navigationTitle("Program")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            pendingMesoStartDate = Date()
                            showingChangeProgram = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                Text("Change Program")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                        }
                    }
                }
                .sheet(isPresented: $showingChangeProgram, onDismiss: handleOnboardingDismiss) {
                    NavigationStack {
                        OnboardingFlowView(initialStartDate: pendingMesoStartDate, profile: profiles.first) { result, overrides in
                            pendingOnboardingResult = result
                            pendingExerciseOverrides = overrides
                        }
                        .navigationTitle("Change Program")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    pendingOnboardingResult = nil
                                    pendingExerciseOverrides = .empty
                                    showingChangeProgram = false
                                }
                            }
                        }
                    }
                }
        }
        .onAppear {
            if MesoLifecycle.isRolloverDue() {
                guardRescheduleDate = MesoLifecycle.scheduledStartDate ?? Date()
                if activeMeso != nil {
                    showMesoSummary = true
                } else {
                    showMesoRolloverGuard = true
                }
            }
        }
        .alert(pendingReplace?.plan.isAllowed == false ? "Can't change the program yet" : "Replace your upcoming sessions?",
               isPresented: Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } })) {
            if pendingReplace?.plan.isAllowed == true {
                Button("Replace", role: .destructive) { confirmReplace() }
                Button("Cancel", role: .cancel) { pendingReplace = nil }
            } else {
                Button("OK", role: .cancel) { pendingReplace = nil }
            }
        } message: {
            Text(pendingReplace?.plan.message ?? "")
        }
        .sheet(isPresented: $showMesoSummary) {
            if let meso = activeMeso {
                MesoSummaryView(meso: meso) { choice in
                    handleNextBlockChoice(choice)
                }
            }
        }
        .sheet(isPresented: $showMesoRolloverGuard) {
            MesoRolloverGuardSheet(
                isPresented: $showMesoRolloverGuard,
                rescheduleDate: $guardRescheduleDate
            )
        }
    }

    // MARK: - Next block handler

    private func handleNextBlockChoice(_ choice: NextBlockChoice) {
        switch choice {
        case .newHypertrophyMeso(let startDate):
            // Re-run the existing onboarding → program apply flow, carrying the
            // start date the user picked on the meso summary so the onboarding
            // picker opens on it instead of silently resetting to today.
            pendingMesoStartDate = startDate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showingChangeProgram = true
            }

        case .maintenanceBlock:
                    // Seeding already completed in MesoSummaryView.seedMaintenanceBlock()
                    break

        case .custom:
                    break
        }
    }

    // MARK: - Onboarding dismiss handler

    private func handleOnboardingDismiss() {
        guard let result = pendingOnboardingResult else { return }
        pendingOnboardingResult = nil
        let overrides = pendingExerciseOverrides
        pendingExerciseOverrides = .empty
        // Same guards as Start next meso: list what would be deleted, refuse while logged work is in the way (see
        // DUPProgramReplaceService.plan), and only then take the backup and replace.
        let plan = DUPProgramReplaceService.plan(startDate: result.startDate, context: modelContext)
        pendingReplace = PendingReplace(result: result, overrides: overrides, plan: plan)
    }

    private func confirmReplace() {
        guard let pending = pendingReplace, pending.plan.isAllowed else { pendingReplace = nil; return }
        pendingReplace = nil
        let result = pending.result, overrides = pending.overrides
        DispatchQueue.main.async {
            // A verified backup first; if it fails the program is not seeded (see SeedBackupGuard).
            seedGuard.run(container: modelContext.container) {
                MesoSeedingCoordinator.applyOnboardingResult(
                    result,
                    context: modelContext,
                    overrides: overrides
                )
            }
        }
    }
}
