# Backlog

One line per item; dates are 2026.

- Insert deload week (target: ready before rotation 3, Fri Nov 6; needed because a v5.3 tripwire deload must happen within days of the trigger). A USER-INITIATED action with a dry-run preview and a confirm step, never a startup migration. Start at the next Friday (week boundary). Shift every PLANNED session on or after that date by +7 days; completed sessions never move. Insert 6 deload sessions (one per day label) with that day's current roster, waveRaw "deload", ~half the sets, RIR 3-4, loads ~60% of each lift's most recent completed same-day load. Renumber weekInMeso and programIndex; totalWeeks +1 (update a week count in the block name if present). Verify before save: no completed session moved; every same-letter chain target is unchanged (week numbers shift, targets don't); nothing targets a deload item and deload items write nothing; no date collisions, no Thursdays; backup round-trip clean. Snapshot-and-restore rollback, same pattern as the 12-week conversion.
- Deload in place (fallback, works today): log the week light with load-override reason Deliberate Deload. Follow-ups: (a) verify a deload-flagged source never seeds an EMPTY same-letter target (new-lift first exposure) with light loads; (b) the "Last A/B/C" caption and the meso summary verdicts must skip items flagged Deliberate Deload, as they already skip deload-wave items.
- Start next meso from this one: clone roster, wave prescriptions, notes and length onto new dates; anchored loads, exempt lifts seed from the last lifted load (not peak e1RM). Needed by Dec 1; current meso ends Dec 16.
- Earned volume (v5.2): Pull A hammer curl 4th set if earned on Oct 18 (>20 reps at 102 or heavier vs Sept 27); parameterized one-shot repair, weeks 5-12; later decline the 4th set, then one open slot chosen at rotation 3.
- Rotation 4 (weeks 10-12): optional RIR 1 on upper compounds and hack squat/hip thrust A/B weeks; decide ~Nov 20.
- Deinit fix (feat/nonisolated-deinit): own install after Oct 21; then remove B10/F6/M7 from Tests/known_failures.txt and delete the parking workaround.
- Next install after Oct 21: main branch; verify the launch log equals today's minus the three unregistered migrations (StartupBackfills refactor).
- Coach-message honesty: non-exempt reduce text says "next session"; "N sets in. Finish the session." appears on completed sessions with incomplete evidence; blocked-write wording.
- Pushdown follows the lifter's last load (parked; user raises by hand).
- Import hardening: atomic import with pre-restore safety copy, tolerant decoding, version check, history order, HealthDashboard rebuild after import, build identity in export, custom-exercise mirror (clear when empty, isBodyweight), tolerant dedup (Dictionary(uniqueKeysWithValues:) trap), idempotent CustomExerciseStoreMigration.
- Swap/add service: Today "Apply to future <weekday>" is unscoped and zeroes loads (guard or scope it); arrays sized to sets; rep range and wave on adds; lastKnownLoad must not read future plans; custom names from the table.
- Test infrastructure: J4 flake; synchronized test folder (no hand-edited pbxproj); keep Tests/known_failures.txt set-based.
- Universality guard (C5): never extend the allowlist except for unregistered one-shot repairs; add new patterns when new user-specific data appears.
- Optional: give the two hand-added week-1 lifts their wave letters; slotOverrides per-day key; bench top set as a feature; isCleanSession vs deliberateDeload; onChange deprecations.
- Hack squat re-entry after Dr. Alexander clears (sled + 135 at W1 stance pain-free -> fresh anchors per letter); cable hip adduction returns only after hips clear.
- E1RM RIR model (low priority): HistorySeedLoad credits RIR additively on input (reps+RIR); load(for:reps:targetRIR:) applies 2.5%/RIR on output. Within ~1% at RIR<=2, ~2% at RIR 4 / low reps. Unify into one E1RMCalculator RIR function used by both; run a C3b-style before/after seed comparison.
- Replace: optional prescription override (e.g. RIR) applied by the service without setting planEdited (planEdited blocks carry-forward writes into the item).
- kg support: User.units is unused; loads/increments/display/backups.
