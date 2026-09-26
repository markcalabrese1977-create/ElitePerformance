import Foundation
import SwiftData

/// Decides whether a block's prescriptions are wave-based (DUP A/B/C), and must
/// therefore never have plan fields copied from one session onto another.
///
/// Why this exists: the meso-wide propagation paths copy the *whole* prescription
/// (`waveRaw`, `repMin`/`repMax`, `targetRIRMin`/`Max`, `targetSets`, `setMin`/`setMax`
/// and the per-set arrays) from a source session onto every other session sharing
/// its day type. On a DUP block that is a wave-flattening bug, not a feature: it
/// rewrites the B and C weeks with the A week's prescription and the undulation
/// is gone. The copy is only safe where every session of the day type is meant to
/// carry the same prescription — a maintenance block, or a block with no waves.
enum WavePrescriptionGuard {

    /// A "wave letter" is an A/B/C undulation marker.
    ///
    /// `deload` is a `waveRaw` value too, but it is not a letter: a block whose only
    /// non-nil waves are deloads has no A/B/C rotation to flatten, so it does not
    /// need the guard.
    static func isWaveLetter(_ waveRaw: String?) -> Bool {
        guard let trimmed = waveRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return false
        }
        return trimmed != "deload"
    }

    /// True when `session` belongs to a block whose prescriptions undulate by wave.
    ///
    /// Maintenance blocks are never wave-based — every session of a day type there is
    /// deliberately identical, which is exactly what propagation is for.
    ///
    /// The check is block-wide, not session-local: the A week of a DUP meso must be
    /// guarded just as hard as the B and C weeks, and it is the A week the user is
    /// most likely to be editing when the flattening happens.
    ///
    /// Falls back to the session's own items when the session has no meso, so an
    /// orphaned wave-based session is still protected.
    static func isWaveBasedBlock(_ session: Session) -> Bool {
        guard let meso = session.meso else {
            return session.items.contains { isWaveLetter($0.waveRaw) }
        }
        guard !meso.isMaintenance else { return false }
        return meso.sessions.contains { blockSession in
            blockSession.items.contains { isWaveLetter($0.waveRaw) }
        }
    }
}
