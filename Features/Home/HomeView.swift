import SwiftUI
import SwiftData

/// Program tab = Program hub.
/// Shows the current block by default, with a toolbar button to re-run onboarding
/// (Change Program). Session history is its own view used in the History tab.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showingChangeProgram = false

    // Meso rollover guard
    @State private var showMesoRolloverGuard = false
    @State private var guardRescheduleDate = Date()

    // Deferred replace/apply after onboarding dismisses
    @State private var pendingOnboardingResult: OnboardingResult?

    var body: some View {
        NavigationStack {
            ProgramPlanView()
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
                        OnboardingFlowView { result in
                            pendingOnboardingResult = result
                        }
                        .navigationTitle("Change Program")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    pendingOnboardingResult = nil
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
                showMesoRolloverGuard = true
            }
        }
        .sheet(isPresented: $showMesoRolloverGuard) {
            MesoRolloverGuardSheet(
                isPresented: $showMesoRolloverGuard,
                rescheduleDate: $guardRescheduleDate
            )
        }
    }

    private func handleOnboardingDismiss() {
        guard let result = pendingOnboardingResult else { return }
        pendingOnboardingResult = nil

        DispatchQueue.main.async {
            applyOnboardingResult(result)
        }
    }

    private func applyOnboardingResult(_ result: OnboardingResult) {
        let weekdays = result.trainingDaysOfWeek
            .map { min(max($0, 1), 7) }
            .sorted()

        print("DEBUG HomeView.applyOnboardingResult – goal=\(result.goal), daysPerWeek=\(result.daysPerWeek), weekdays=\(weekdays)")

        if result.goal == .hypertrophy && result.daysPerWeek == 6 {
            do {
                try DUPProgramReplaceService.replacePlannedProgram(
                    startDate: Date(),
                    trainingWeekdays: weekdays,
                    context: modelContext
                )
                print("DEBUG HomeView.applyOnboardingResult – completed DUP replace flow")
            } catch {
                print("ERROR HomeView.applyOnboardingResult – DUP replace failed: \(error)")
            }
        } else {
            ProgramCatalog.applyOnboardingResult(
                result,
                context: modelContext
            )
            print("DEBUG HomeView.applyOnboardingResult – completed applyOnboardingResult")
        }
    }
}
