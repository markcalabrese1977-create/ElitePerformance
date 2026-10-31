import Foundation
import SwiftData

/// The one list of persisted model types. The app container and the backup schema-completeness test both
/// build their Schema from it, so the test can never drift from what the app stores.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        User.self,
        ProgramState.self,
        Session.self,
        SessionItem.self,
        SetLog.self,
        PRIndex.self,
        SessionHistory.self,
        SessionHistoryExercise.self,
        ExerciseNote.self,
        AppState.self,
        MesoBlock.self,
        UserProfile.self,
        CustomExercise.self
    ]

    static func makeSchema() -> Schema { Schema(models) }
}
