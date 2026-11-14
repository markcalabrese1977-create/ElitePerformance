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

scripts/run_bounded.sh > "$OUT_DIR/full.out" 2>&1
grep -E "^\[phase\]|^== |^VERDICT" "$OUT_DIR/full.out"

REL_START=$SECONDS
xcodebuild build -configuration Release -project ElitePerformance.xcodeproj -scheme ElitePerformance \
  -destination "generic/platform=iOS" -derivedDataPath "$OUT_DIR/rel" CODE_SIGNING_ALLOWED=NO > "$OUT_DIR/rel.log" 2>&1
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
