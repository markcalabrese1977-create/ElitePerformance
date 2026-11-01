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

        DispatchQueue.main.async {
            MesoSeedingCoordinator.applyOnboardingResult(
                result,
                context: modelContext,
                overrides: overrides
            )
        }
    }
}
