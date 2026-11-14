import XCTest
import SwiftData
@testable import ElitePerformance

final class HeartRateAgeTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
    private func age(hk: DateComponents? = nil, override: Date? = nil, at: Date) -> Int? {
        HeartRateAge.ageYears(healthKitBirth: hk, profileOverride: override, at: at, calendar: cal)
    }

    func test_healthKitDateOfBirth_isUsed() {
        let hk = DateComponents(year: 1990, month: 3, day: 15)
        XCTAssertEqual(age(hk: hk, at: date(2026, 10, 18)), 36)
        XCTAssertEqual(age(hk: hk, at: date(2026, 3, 14)), 35, "birthday not reached yet")
        XCTAssertEqual(age(hk: hk, at: date(2026, 3, 15)), 36)
    }

    func test_healthKitWinsOverTheSettingsOverride() {
        let hk = DateComponents(year: 1990, month: 1, day: 1)
        XCTAssertEqual(age(hk: hk, override: date(1970, 1, 1), at: date(2026, 10, 18)), 36)
    }

    func test_settingsOverride_usedWhenHealthKitHasNoBirthDate() {
        XCTAssertEqual(age(hk: nil, override: date(1980, 6, 1), at: date(2026, 10, 18)), 46)
        // HealthKit returned components without a year → treated as absent.
        XCTAssertEqual(age(hk: DateComponents(month: 6, day: 1), override: date(1980, 6, 1), at: date(2026, 10, 18)), 46)
    }

    func test_noSource_meansNoAge_andNoAssumedFallback() {
        XCTAssertNil(age(at: date(2026, 10, 18)))
    }

    func test_implausibleDates_areTreatedAsMissing() {
        XCTAssertNil(age(override: date(2030, 1, 1), at: date(2026, 10, 18)), "future birthdate")
        XCTAssertNil(age(override: date(2024, 1, 1), at: date(2026, 10, 18)), "age under 5")
        XCTAssertNil(age(override: date(1900, 1, 1), at: date(2026, 10, 18)), "age over 110")
        // An implausible HealthKit value does not block a good override.
        XCTAssertEqual(age(hk: DateComponents(year: 2030, month: 1, day: 1), override: date(1980, 6, 1), at: date(2026, 10, 18)), 46)
    }

    func test_zoneModel_needsBothAnAgeAndRestingHR() {
        XCTAssertEqual(HeartRateAge.zoneModel(ageYears: 36, restingHR: 55), .hrr(ageYears: 36, restingHR: 55))
        XCTAssertEqual(HeartRateAge.zoneModel(ageYears: nil, restingHR: 55), .percentMax, "no age -> no HRR zones")
        XCTAssertEqual(HeartRateAge.zoneModel(ageYears: 36, restingHR: nil), .percentMax)
        XCTAssertEqual(HeartRateAge.zoneModel(ageYears: 36, restingHR: 0), .percentMax)
    }

    func test_profileBirthdate_defaultsToNil_andSurvivesABackupRoundTrip() throws {
        XCTAssertNil(UserProfile().birthDateOverride)

        let schema = Schema([
            User.self, ProgramState.self, Session.self, SessionItem.self, SetLog.self, PRIndex.self,
            SessionHistory.self, SessionHistoryExercise.self, ExerciseNote.self, AppState.self,
            MesoBlock.self, UserProfile.self, CustomExercise.self
        ])
        func container() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        }
        for birth in [Date(timeIntervalSince1970: 315_532_800), nil] {   // 1980-01-01 UTC, and none
            let src = try container()
            let sctx = ModelContext(src)
            let p = UserProfile()
            p.birthDateOverride = birth
            sctx.insert(p)
            try sctx.save()
            let result = try BackupSnapshotExporter.exportFullBackupJSON(modelContext: sctx)
            defer { try? FileManager.default.removeItem(at: result.url) }
            let dst = try container()
            _ = try BackupSnapshotImporter.importFullBackupJSON(from: result.url, modelContainer: dst)
            let restored = try XCTUnwrap(try ModelContext(dst).fetch(FetchDescriptor<UserProfile>()).first)
            XCTAssertEqual(restored.birthDateOverride, birth)
        }
    }
}
