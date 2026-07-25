import SwiftUI
import SwiftData

/// Program tab = Program hub.
/// Shows the current block by default, with a toolbar button to re-run onboarding
/// (Change Program). Session history is its own view used in the History tab.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var mesoBlocks: [MesoBlock]

    @State private var showingChangeProgram = false

    // Meso summary (end-of-meso flow)
    @State private var showMesoSummary = false

    // Meso rollover guard (fallback when no active meso or summary dismissed)
    @State private var showMesoRolloverGuard = false
    @State private var guardRescheduleDate = Date()

    // Deferred replace/apply after onboarding dismisses
    @State private var pendingOnboardingResult: OnboardingResult?
    @State private var pendingExerciseOverrides: ExerciseOverrideMap = [:]

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
                        OnboardingFlowView { result, overrides in
                            pendingOnboardingResult = result
                            pendingExerciseOverrides = overrides
                        }
                        .navigationTitle("Change Program")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    pendingOnboardingResult = nil
                                    pendingExerciseOverrides = [:]
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
        case .newHypertrophyMeso:
            // Re-run the existing onboarding → program apply flow
            // For now, show the change program sheet so user can configure
            // In a future iteration this will auto-seed from UserProfile
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
        pendingExerciseOverrides = [:]

        DispatchQueue.main.async {
            ProgramApplicationService.apply(
                result,
                context: modelContext,
                startDate: result.startDate,
                overrides: overrides
            )
        }
    }
}
