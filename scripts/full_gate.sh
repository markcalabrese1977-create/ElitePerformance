#!/bin/bash
# The full gate, run ONCE at a final head: default test plan on the Oct 30 fixture (or $GATE_FIXTURE), then a Release device build.
# Prints wall time per phase (Debug build, test run, Release build) and the 10 slowest tests from the xcresult.
#
# Usage: scripts/full_gate.sh [tag]      Env: GATE_FIXTURE (default: the 2026-10-30 backup in ~/Downloads), OUT_DIR
cd "$(dirname "$0")/.." || exit 3
TAG="${1:-full}"
OUT_DIR="${OUT_DIR:-${TMPDIR:-/tmp}/ep_gate_$TAG}"; mkdir -p "$OUT_DIR"; export OUT_DIR
FIX="${GATE_FIXTURE:-$HOME/Downloads/ElitePerformance_Backup_v1_2026-10-30_19-02-11.json}"
export TEST_RUNNER_EP_BACKUP_FIXTURE="$FIX"
# Angela's 1.2.2 backup and the 1.3.0 backup first launch produced (PlaceholderRefreshAngelaFixtureTests); the tests skip when absent.
A122="${GATE_ANGELA_122:-$HOME/Downloads/ElitePerformance_Backup_v1_2026-11-20_14-25-03.json}"
A130="${GATE_ANGELA_130:-$HOME/Downloads/ElitePerformance_Backup_v1_2026-11-20_14-29-53.json}"
[ -f "$A122" ] && export TEST_RUNNER_EP_ANGELA_122="$A122"
[ -f "$A130" ] && export TEST_RUNNER_EP_ANGELA_130="$A130"
# Mark's live backup (MesoComparisonTests: the Meso Summary badge agrees with the PR events on every row); the test skips when absent.
LIVE="${GATE_LIVE_BACKUP:-$HOME/Downloads/ElitePerformance_Backup_v1_2026-11-20_17-18-55.json}"
[ -f "$LIVE" ] && export TEST_RUNNER_EP_LIVE_BACKUP="$LIVE"

# CoachingPolicyTests: `.shipped` reproduces every compound decision on Mark's and Angela's backups (golden dumps from the commit that introduced the policy).
PB1="${GATE_POLICY_MARK:-$HOME/Downloads/ElitePerformance_Backup_v1_2026-11-22_09-28-39.json}"; PB2="${GATE_POLICY_ANGELA:-$HOME/Downloads/ElitePerformance_Backup_v1_2026-11-20_19-37-34.json}"
PG1="$HOME/Downloads/EP_policy_golden_mark.json"; PG2="$HOME/Downloads/EP_policy_golden_angela.json"
if [ -f "$PB1" ] && [ -f "$PB2" ] && [ -f "$PG1" ] && [ -f "$PG2" ]; then export TEST_RUNNER_EP_POLICY_BACKUPS="$PB1,$PB2" TEST_RUNNER_EP_POLICY_GOLDEN="$PG1,$PG2"; fi
# Angela's Nov 25 19:04 backup (before her conversion) is checked against the same Angela golden dump, as a third pair.
PB3="${GATE_POLICY_ANGELA_1125:-$HOME/Downloads/ElitePerformance_Backup_v1_2026-11-25_19-04-35.json}"
if [ -n "${TEST_RUNNER_EP_POLICY_BACKUPS:-}" ] && [ -f "$PB3" ]; then export TEST_RUNNER_EP_POLICY_BACKUPS="$TEST_RUNNER_EP_POLICY_BACKUPS,$PB3" TEST_RUNNER_EP_POLICY_GOLDEN="$TEST_RUNNER_EP_POLICY_GOLDEN,$PG2"; fi

# SameEveryWeekReferenceTests.test_property_onTheRealBackups_forEveryKeptLetter: the golden test's backups PLUS Angela's Nov 25 19:04 backup (the
# Hammer Curl reproducer: before her conversion) and Mark's Nov 25 18:57 backup. Only files that exist are listed.
SW_LIST=""
for f in "${PB1:-}" "${PB2:-}" "${GATE_SW_ANGELA_1125:-$HOME/Downloads/ElitePerformance_Backup_v1_2026-11-25_19-04-35.json}" "${GATE_SW_MARK_1125:-$HOME/Downloads/ElitePerformance_Backup_v1_2026-11-25_18-57-55.json}"; do
  [ -f "$f" ] && SW_LIST="${SW_LIST:+$SW_LIST,}$f"
done
[ -n "$SW_LIST" ] && export TEST_RUNNER_EP_SW_BACKUPS="$SW_LIST"
scripts/run_bounded.sh > "$OUT_DIR/full.out" 2>&1
grep -E "^\[phase\]|^== |^VERDICT" "$OUT_DIR/full.out"

REL_START=$SECONDS
xcodebuild build -configuration Release -project ElitePerformance.xcodeproj -scheme ElitePerformance \
  -destination "generic/platform=iOS" -derivedDataPath "$OUT_DIR/rel" CODE_SIGNING_ALLOWED=NO EP_ALLOW_DIRTY=1 > "$OUT_DIR/rel.log" 2>&1
RC=$?
echo "[phase] release build $((SECONDS - REL_START))s (exit $RC)"

echo "== 10 slowest tests"
XCR="$(ls -dt "$OUT_DIR"/DD/Logs/Test/*.xcresult 2>/dev/null | head -1)"
if [ -n "$XCR" ] && xcrun xcresulttool get test-results tests --path "$XCR" > "$OUT_DIR/tests.json" 2>/dev/null; then
  python3 - "$OUT_DIR/tests.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
rows=[]
def walk(n,path):
    if n.get("nodeType")=="Test Case":
        dur=n.get("durationInSeconds")
        if dur is None:
            t=n.get("duration","")
            try: dur=float(str(t).split()[0].replace(",",""))
            except: dur=0
        rows.append((float(dur),n.get("name",""),path))
    for c in n.get("children",[]) or []: walk(c,path+[n.get("name","")])
for n in d.get("testNodes",[]): walk(n,[])
for dur,name,path in sorted(rows,reverse=True)[:10]: print(f"{dur:8.2f}s  {path[-1] if path else ''}.{name}")
PY
else
  grep -hE "^Test Case .* (passed|failed) \(" "$OUT_DIR/test.log" 2>/dev/null \
    | sed -E "s/^Test Case '-\[(.*)\]' (passed|failed) \(([0-9.]+) seconds\)\./\3s  \1/" | sort -rn | head -10
fi
[ "$RC" = 0 ]
