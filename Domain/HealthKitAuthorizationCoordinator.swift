import Foundation
import HealthKit
import UIKit

/// Every HealthKit type the app reads. The single definition of the read set.
enum HealthKitReadSet {
    static var full: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        let identifiers: [HKQuantityTypeIdentifier] = [.heartRate, .activeEnergyBurned, .basalEnergyBurned, .restingHeartRate]
        for id in identifiers {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        // Date of birth: age for HRR zones (Settings birthdate or %-of-max zones are the fallbacks).
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { types.insert(dob) }
        return types
    }
}

/// The two HealthKit authorization calls the coordinator needs, so it can be driven without a device.
protocol HealthKitAuthorizing {
    var isHealthDataAvailable: Bool { get }
    func authorizationRequestStatus(read: Set<HKObjectType>) async throws -> HKAuthorizationRequestStatus
    func requestAuthorization(read: Set<HKObjectType>) async throws
}

struct LiveHealthKitAuthorizer: HealthKitAuthorizing {
    private let store = HKHealthStore()
    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    func authorizationRequestStatus(read: Set<HKObjectType>) async throws -> HKAuthorizationRequestStatus {
        try await store.statusForAuthorizationRequest(toShare: [], read: read)
    }
    func requestAuthorization(read: Set<HKObjectType>) async throws {
        try await store.requestAuthorization(toShare: [], read: read)
    }
}

/// Requests HealthKit permissions at a safe moment, and only that. The workout sync never waits on
/// authorization (a permission sheet that cannot present would stall it), so this is the one place
/// the request is made: from the root view's active moments, once per launch, after onboarding, and
/// only when nothing is presented. Errors are logged, never thrown.
@MainActor
final class HealthKitAuthorizationCoordinator {

    enum Outcome: Equatable {
        case unavailable
        case deferredOnboarding
        case deferredPresentation
        case alreadyRequestedThisLaunch
        case notNeeded
        case requested
        case statusFailed(String)
        case requestFailed(String)
    }

    static let shared = HealthKitAuthorizationCoordinator(authorizer: LiveHealthKitAuthorizer())

    private let authorizer: HealthKitAuthorizing
    private let readTypes: Set<HKObjectType>
    private(set) var requestedThisLaunch = false

    init(authorizer: HealthKitAuthorizing, readTypes: Set<HKObjectType> = HealthKitReadSet.full) {
        self.authorizer = authorizer
        self.readTypes = readTypes
    }

    /// Call at each active moment. Anything that makes now a bad time returns early WITHOUT using up
    /// the once-per-launch request, so the next active moment tries again.
    @discardableResult
    func attemptIfNeeded(onboardingComplete: Bool, isNothingPresented: () -> Bool) async -> Outcome {
        guard !requestedThisLaunch else { return log(.alreadyRequestedThisLaunch) }
        guard authorizer.isHealthDataAvailable else { return log(.unavailable) }
        guard onboardingComplete else { return log(.deferredOnboarding) }
        guard isNothingPresented() else { return log(.deferredPresentation) }

        let status: HKAuthorizationRequestStatus
        do {
            status = try await authorizer.authorizationRequestStatus(read: readTypes)
        } catch {
            return log(.statusFailed("\(error)"))
        }
        guard status == .shouldRequest else { return log(.notNeeded) }

        // Mark before awaiting so a second active moment during the sheet can't ask again.
        requestedThisLaunch = true
        print("ℹ️ HK auth: requesting (\(readTypes.count) types, status shouldRequest)")
        do {
            try await authorizer.requestAuthorization(read: readTypes)
            return log(.requested)
        } catch {
            return log(.requestFailed("\(error)"))
        }
    }

    private func log(_ outcome: Outcome) -> Outcome {
        switch outcome {
        case .requested: print("✅ HK auth: request returned")
        case .requestFailed(let e): print("⚠️ HK auth: request failed: \(e)")
        case .statusFailed(let e): print("⚠️ HK auth: status check failed: \(e)")
        default: print("ℹ️ HK auth: \(outcome)")
        }
        return outcome
    }
}

/// Whether the app is showing anything modal (sheet, full-screen cover, alert, dialog). SwiftUI
/// presentations are UIKit view controllers presented over the root, including while one is still
/// animating in or out.
enum PresentationProbe {
    @MainActor
    static func nothingPresented() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }),
              let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController
        else { return false }
        return root.presentedViewController == nil && !root.isBeingPresented && !root.isBeingDismissed
    }
}
