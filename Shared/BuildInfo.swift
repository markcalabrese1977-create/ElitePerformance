import Foundation

/// Identifies the running build: marketing version, build number, and the git
/// commit / branch it was built from.
///
/// Version and build come from the normal Info.plist keys. `commit` and `branch`
/// are stamped into the BUILT Info.plist by scripts/stamp_build_info.sh, which runs
/// as the last Run Script build phase — the source Info.plist never carries them,
/// so a checkout with no Run Script phase configured reads "unknown" rather than a
/// stale value from a previous build.
///
/// A commit ending in "-dirty" means the build included uncommitted changes and
/// cannot be reproduced from that hash alone.
enum BuildInfo {

    /// CFBundleShortVersionString — e.g. "1.2.1".
    static var version: String { infoString("CFBundleShortVersionString") }

    /// CFBundleVersion — e.g. "4".
    static var build: String { infoString("CFBundleVersion") }

    /// Short git hash, with "-dirty" appended when the tree had uncommitted changes.
    static var commit: String { infoString("GitCommit") }

    /// Branch the build came from, or "detached" for a detached HEAD.
    static var branch: String { infoString("GitBranch") }

    /// One line identifying this build, for display.
    /// e.g. "Version 1.2.1 (4) · a1b2c3d · main"
    static var description: String {
        "Version \(version) (\(build)) · \(commit) · \(branch)"
    }

    /// The same identity in launch-log form.
    /// e.g. "Build 1.2.1 (4) · a1b2c3d · main"
    static var logLine: String {
        "Build \(version) (\(build)) · \(commit) · \(branch)"
    }

    /// Reads a string from the main bundle's Info.plist, collapsing a missing,
    /// non-string, or blank value to "unknown" so callers never render an empty gap.
    private static func infoString(_ key: String) -> String {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "unknown"
        }
        return value
    }
}
