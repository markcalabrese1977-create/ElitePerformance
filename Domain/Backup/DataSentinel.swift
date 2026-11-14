import Foundation

/// The missing-data sentinel: the number of completed sessions the store held after the last successful launch (or legitimate
/// import). If a later launch opens a store with 0 completed sessions while this is above 0, the data has gone missing and the
/// app must not carry on as if nothing happened (no backfills, no automatic backup that would overwrite good state).
///
/// DEVICE state, kept in the app-group defaults next to the store it describes: registered in PersistedKeyRegistry and
/// excluded from restore (a backup must not carry a count that belongs to another device's store).
struct DataSentinelStore {
    static let appGroupSuite = "group.com.markcalabrese.eliteperformance"

    /// Tests point this at an isolated suite so they never touch the device's real sentinel.
    nonisolated(unsafe) static var overrideDefaults: UserDefaults?

    var defaults: UserDefaults = DataSentinelStore.overrideDefaults ?? UserDefaults(suiteName: appGroupSuite) ?? .standard

    var completedSessions: Int {
        get { defaults.integer(forKey: "dataSentinel.completedSessions") }
        nonmutating set { defaults.set(newValue, forKey: "dataSentinel.completedSessions") }
    }

    func record(_ completedSessions: Int) { self.completedSessions = completedSessions }

    /// Which defaults the value lives in, for the launch log.
    var describeSource: String { defaults === UserDefaults.standard ? "standard defaults" : "app-group defaults \(Self.appGroupSuite)" }
}
