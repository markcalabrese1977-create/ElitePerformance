import XCTest
import SwiftData
@testable import ElitePerformance

/// Session.insertedDeload survives a backup export/import, and a backup written before the key
/// existed restores it as nil.
final class InsertedDeloadMarkerTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self,
            PRIndex.self, SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self,
            AppState.self, MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func seed(_ container: ModelContainer) throws {
        let ctx = ModelContext(container)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for (i, marker) in [Bool?.some(true), .some(false), nil].enumerated() {
            let s = Session(date: t0.addingTimeInterval(Double(i) * 86_400), status: .planned,
                            weekIndex: 1, dayLabel: "D\(i)", programIndex: i + 1)
            s.insertedDeload = marker
            ctx.insert(s)
        }
        try ctx.save()
    }

    private func markers(_ container: ModelContainer) throws -> [Bool?] {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\.date)])).map(\.insertedDeload)
    }

    func test_insertedDeload_roundTripsThroughBackup() throws {
        let source = try makeContainer()
        try seed(source)
        let export = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ModelContext(source))

        let target = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: export.url, modelContainer: target)
        let restored = try markers(target)
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored[0], true)
        XCTAssertEqual(restored[1], false)
        XCTAssertNil(restored[2])
    }

    func test_oldBackupWithoutTheKey_restoresNil() throws {
        let source = try makeContainer()
        try seed(source)
        let export = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: ModelContext(source))

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: export.url)) as? [String: Any])
        var sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertTrue(sessions.contains { $0["insertedDeload"] != nil }, "sanity: the new key is exported")
        for i in sessions.indices { sessions[i].removeValue(forKey: "insertedDeload") }
        json["sessions"] = sessions
        let oldURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: json).write(to: oldURL)

        let target = try makeContainer()
        _ = try BackupSnapshotImporter.importFullBackupJSON(from: oldURL, modelContainer: target)
        let restored = try markers(target)
        XCTAssertEqual(restored.count, 3)
        XCTAssertTrue(restored.allSatisfy { $0 == nil })
    }
}
