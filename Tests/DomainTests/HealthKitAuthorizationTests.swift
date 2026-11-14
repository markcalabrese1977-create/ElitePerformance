import XCTest
import HealthKit
import SwiftData
@testable import ElitePerformance

// MARK: - Fakes

private final class FakeAuthorizer: HealthKitAuthorizing {
    var available = true
    var status: Result<HKAuthorizationRequestStatus, Error> = .success(.shouldRequest)
    var requestError: Error?
    private(set) var statusCalls = 0
    private(set) var requestCalls = 0

    var isHealthDataAvailable: Bool { available }
    func authorizationRequestStatus(read: Set<HKObjectType>) async throws -> HKAuthorizationRequestStatus {
        statusCalls += 1
        return try status.get()
    }
    func requestAuthorization(read: Set<HKObjectType>) async throws {
        requestCalls += 1
        if let requestError { throw requestError }
    }
}

private struct Boom: Error {}

/// A HealthKit with one strength workout and a heart-rate trace. `birth == nil` models a denied or
/// missing date of birth (the real call throws).
private final class FakeSource: HealthKitDataSource {
    let workouts: [HKWorkout]
    let samples: [HKQuantitySample]
    let restingHR: Double?
    let birth: DateComponents?
    private(set) var calls: [String] = []

    init(workouts: [HKWorkout], samples: [HKQuantitySample], restingHR: Double? = 55, birth: DateComponents? = nil) {
        self.workouts = workouts; self.samples = samples; self.restingHR = restingHR; self.birth = birth
    }
    func workoutCandidates(from start: Date, to end: Date) async throws -> [HKWorkout] { calls.append("workouts"); return workouts }
    func basalCalories(from start: Date, to end: Date) async throws -> Double { calls.append("basal"); return 120 }
    func heartRateStats(from start: Date, to end: Date) async throws -> (avg: Double, max: Double) { calls.append("stats"); return (130, 150) }
    func heartRateSamples(from start: Date, to end: Date) async throws -> [HKQuantitySample] { calls.append("samples"); return samples }
    func restingHeartRateAverage(endingAt end: Date, lookbackDays: Int) async throws -> Double? { calls.append("rhr"); return restingHR }
    func dateOfBirthComponents() throws -> DateComponents {
        calls.append("dob")
        guard let birth else { throw Boom() }
        return birth
    }
}

// MARK: - Coordinator

@MainActor
final class HealthKitAuthorizationCoordinatorTests: XCTestCase {

    private func make(_ authorizer: FakeAuthorizer) -> HealthKitAuthorizationCoordinator {
        HealthKitAuthorizationCoordinator(authorizer: authorizer)
    }

    func test_requestsOnlyWhenStatusIsShouldRequest() async {
        let granted = FakeAuthorizer(); granted.status = .success(.unnecessary)
        let outcome = await make(granted).attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertEqual(granted.statusCalls, 1)
        XCTAssertEqual(granted.requestCalls, 0, "everything already decided: no request")

        let fresh = FakeAuthorizer()
        let requested = await make(fresh).attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        XCTAssertEqual(requested, .requested)
        XCTAssertEqual(fresh.requestCalls, 1)
    }

    func test_requestsOncePerLaunch() async {
        let auth = FakeAuthorizer()
        let coordinator = make(auth)
        _ = await coordinator.attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        let second = await coordinator.attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        XCTAssertEqual(second, .alreadyRequestedThisLaunch)
        XCTAssertEqual(auth.requestCalls, 1)
        XCTAssertEqual(auth.statusCalls, 1, "a later active moment doesn't even re-check")
    }

    func test_neverWhileOnboardingIsIncomplete_thenRequestsOnceItIs() async {
        let auth = FakeAuthorizer()
        let coordinator = make(auth)
        let early = await coordinator.attemptIfNeeded(onboardingComplete: false, isNothingPresented: { true })
        XCTAssertEqual(early, .deferredOnboarding)
        XCTAssertEqual(auth.statusCalls, 0)
        XCTAssertEqual(auth.requestCalls, 0)
        XCTAssertFalse(coordinator.requestedThisLaunch, "a deferral doesn't use up the launch's request")

        let later = await coordinator.attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        XCTAssertEqual(later, .requested)
        XCTAssertEqual(auth.requestCalls, 1)
    }

    func test_defersWhileSomethingIsPresented_andRetriesAtTheNextActiveMoment() async {
        let auth = FakeAuthorizer()
        let coordinator = make(auth)
        let blocked = await coordinator.attemptIfNeeded(onboardingComplete: true, isNothingPresented: { false })
        XCTAssertEqual(blocked, .deferredPresentation)
        XCTAssertEqual(auth.requestCalls, 0)
        XCTAssertFalse(coordinator.requestedThisLaunch)

        let clear = await coordinator.attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        XCTAssertEqual(clear, .requested)
        XCTAssertEqual(auth.requestCalls, 1)
    }

    func test_errorsAreLoggedNotThrown() async {
        let statusFails = FakeAuthorizer(); statusFails.status = .failure(Boom())
        let c1 = make(statusFails)
        let o1 = await c1.attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        guard case .statusFailed = o1 else { return XCTFail("\(o1)") }
        XCTAssertEqual(statusFails.requestCalls, 0)
        XCTAssertFalse(c1.requestedThisLaunch, "a failed status check can be retried")

        let requestFails = FakeAuthorizer(); requestFails.requestError = Boom()
        let c2 = make(requestFails)
        let o2 = await c2.attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        guard case .requestFailed = o2 else { return XCTFail("\(o2)") }
        let again = await c2.attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        XCTAssertEqual(again, .alreadyRequestedThisLaunch, "still only one request per launch")
        XCTAssertEqual(requestFails.requestCalls, 1)
    }

    func test_unavailableHealthData_doesNothing() async {
        let auth = FakeAuthorizer(); auth.available = false
        let outcome = await make(auth).attemptIfNeeded(onboardingComplete: true, isNothingPresented: { true })
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(auth.statusCalls, 0)
        XCTAssertEqual(auth.requestCalls, 0)
    }

    func test_readSet_includesWorkoutsHeartRateAndDateOfBirth() {
        let full = HealthKitReadSet.full
        XCTAssertTrue(full.contains(HKObjectType.workoutType()))
        XCTAssertTrue(full.contains(HKObjectType.quantityType(forIdentifier: .heartRate)!))
        XCTAssertTrue(full.contains(HKObjectType.quantityType(forIdentifier: .restingHeartRate)!))
        XCTAssertTrue(full.contains(HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!))
    }
}

// MARK: - Sync never waits on authorization

@MainActor
final class HealthKitSyncWithoutAuthorizationTests: XCTestCase {

    private var container: ModelContainer!

    private let completedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Session.self, SessionItem.self, SetLog.self, MesoBlock.self,
                             UserProfile.self, User.self, CustomExercise.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    private func completedSession(_ ctx: ModelContext) -> Session {
        let s = Session(date: completedAt, status: .completed, weekIndex: 1, dayLabel: "Push B", items: [])
        s.completedAt = completedAt
        ctx.insert(s)
        return s
    }

    /// A 45-minute strength workout ending shortly before completion, with an 8-point HR trace at 140 bpm.
    private func source(birth: DateComponents? = nil, noWorkout: Bool = false) -> FakeSource {
        let start = completedAt.addingTimeInterval(-50 * 60), end = completedAt.addingTimeInterval(-5 * 60)
        let workout = HKWorkout(activityType: .traditionalStrengthTraining, start: start, end: end)
        let unit = HKUnit.count().unitDivided(by: .minute())
        let type = HKQuantityType(.heartRate)
        let samples = (0..<8).map { i -> HKQuantitySample in
            let t = start.addingTimeInterval(Double(i) * 6 * 60)
            return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: 140), start: t, end: t)
        }
        return FakeSource(workouts: noWorkout ? [] : [workout], samples: samples, restingHR: 55, birth: birth)
    }

    private func zones(_ s: Session) -> [Double] {
        [s.hkZone1Seconds, s.hkZone2Seconds, s.hkZone3Seconds, s.hkZone4Seconds, s.hkZone5Seconds].map { Double($0) }
    }

    func test_syncRunsWithNoAuthorizationAtAll_andLinksTheWorkout() async throws {
        let ctx = try makeContext()
        let session = completedSession(ctx)
        let src = source()
        await HealthKitWorkoutSummarySyncService.syncForCompletedSession(session, in: ctx, source: src)

        XCTAssertNotNil(session.hkWorkoutUUID, "linked using existing grants")
        XCTAssertTrue(src.calls.contains("workouts"))
        XCTAssertGreaterThan(zones(session).reduce(0, +), 0)
    }

    func test_dateOfBirthDenied_stillLinks_andUsesPercentOfMaxZones() async throws {
        let ctx = try makeContext()
        let denied = completedSession(ctx)
        let src = source(birth: nil)                 // dateOfBirthComponents() throws
        await HealthKitWorkoutSummarySyncService.syncForCompletedSession(denied, in: ctx, source: src)
        XCTAssertNotNil(denied.hkWorkoutUUID, "a missing date of birth must not stop the link")
        XCTAssertTrue(src.calls.contains("dob"))

        // Same trace with an age: the HRR model gives a different distribution than %-of-observed-max.
        let ctx2 = try makeContext()
        let aged = completedSession(ctx2)
        await HealthKitWorkoutSummarySyncService.syncForCompletedSession(
            aged, in: ctx2, source: source(birth: DateComponents(year: 1990, month: 1, day: 1)))
        XCTAssertNotNil(aged.hkWorkoutUUID)
        XCTAssertNotEqual(zones(denied), zones(aged), "no age -> %-of-max zones; with an age -> HRR zones")
    }

    func test_settingsBirthdate_isUsedWhenHealthHasNone() async throws {
        let ctx = try makeContext()
        let profile = UserProfile()
        profile.birthDateOverride = Calendar.current.date(from: DateComponents(year: 1990, month: 1, day: 1))
        ctx.insert(profile)
        let viaSettings = completedSession(ctx)
        await HealthKitWorkoutSummarySyncService.syncForCompletedSession(viaSettings, in: ctx, source: source(birth: nil))

        let ctx2 = try makeContext()
        let viaHealth = completedSession(ctx2)
        await HealthKitWorkoutSummarySyncService.syncForCompletedSession(
            viaHealth, in: ctx2, source: source(birth: DateComponents(year: 1990, month: 1, day: 1)))

        XCTAssertNotNil(viaSettings.hkWorkoutUUID)
        XCTAssertEqual(zones(viaSettings), zones(viaHealth), "same birth year -> same HRR zones")
    }

    func test_noWorkout_returnsWithoutLinking_andWithoutThrowing() async throws {
        let ctx = try makeContext()
        let session = completedSession(ctx)
        await HealthKitWorkoutSummarySyncService.syncForCompletedSession(session, in: ctx, source: source(noWorkout: true))
        XCTAssertNil(session.hkWorkoutUUID)
    }

    /// Structure: the only production call to `requestAuthorization(` is the coordinator's.
    func test_onlyTheCoordinatorRequestsAuthorization() throws {
        var dir = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/", !["App", "Domain", "Features"].allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
            dir.deleteLastPathComponent()
        }
        guard dir.path != "/" else { return XCTFail("source root not found") }
        var offenders: [String] = []
        var scanned = 0
        for folder in ["App", "Domain", "Features"] {
            let walker = try XCTUnwrap(fm.enumerator(at: dir.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let text = UniversalityGuardTests.strippingComments(try String(contentsOf: url, encoding: .utf8))
                if text.contains("requestAuthorization(") && url.lastPathComponent != "HealthKitAuthorizationCoordinator.swift" {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50)
        XCTAssertEqual(offenders, [], "HealthKit authorization may only be requested by HealthKitAuthorizationCoordinator")
    }
}
