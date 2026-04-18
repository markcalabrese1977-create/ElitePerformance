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
            ProgramApplicationService.apply(
                result,
                context: modelContext,
                startDate: Date()
            )
        }
    }
}
