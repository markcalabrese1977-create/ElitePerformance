import SwiftUI
import SwiftData

/// Legacy shell kept for compatibility. The real root is MainTabView,
/// which hosts Today / Program / History.
struct RootTabView: View {
    var body: some View {
        MainTabView()
    }
}

#Preview {
    RootTabView()
        .modelContainer(for: [
            User.self,
            ProgramState.self,
            Session.self,
            SessionItem.self,
            SetLog.self,
            PRIndex.self,
            SessionHistory.self,
            SessionHistoryExercise.self,
            ExerciseNote.self,
            AppState.self
        ], inMemory: true)
}
