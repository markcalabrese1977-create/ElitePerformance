# Backlog

One line per item; dates are 2026.

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
- Optional: give the two hand-added week-1 lifts their wave letters; slotOverrides per-day key; bench top set as a feature; isCleanSession vs deliberateDeload; onChange deprecations.
