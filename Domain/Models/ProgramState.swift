import Foundation
import SwiftData

@Model
final class ProgramState {
    /// The next session the user should perform in this meso (1...N).
    var currentProgramIndex: Int

    /// Optional: identifies the active meso/version if you ever support “start new meso”.
    var activeMesoId: String

    init(currentProgramIndex: Int = 1, activeMesoId: String = "meso.v1") {
        self.currentProgramIndex = currentProgramIndex
        self.activeMesoId = activeMesoId
    }
}
