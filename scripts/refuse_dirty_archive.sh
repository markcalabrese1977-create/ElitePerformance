#!/bin/sh
#
# Release builds (an archive is one) refuse a dirty git tree, so a build that ships can always be traced to one commit.
# Debug builds are unaffected. Run as the FIRST build phase of the app target.
#
# Dirty = anything `git status --porcelain` reports (modified, staged, deleted, or untracked files; untracked files count because
# the synchronized folder groups compile an untracked .swift file into the build), except the untracked .claude/ folder.
# No git repository at SRCROOT (a tarball export): nothing to check, the build goes on (stamp_build_info.sh warns about it).
# EP_ALLOW_DIRTY=1 lets a non-archive Release build through (scripts/full_gate.sh sets it for its own Release compile check).

[ "${CONFIGURATION:-}" = "Release" ] || exit 0
[ "${EP_ALLOW_DIRTY:-}" = "1" ] && exit 0

if GIT_BIN=$(xcrun --find git 2>/dev/null) && [ -x "${GIT_BIN}" ]; then :; else GIT_BIN=$(command -v git 2>/dev/null) || exit 0; fi
"${GIT_BIN}" -C "${SRCROOT}" rev-parse --git-dir >/dev/null 2>&1 || exit 0

DIRTY=$("${GIT_BIN}" -C "${SRCROOT}" status --porcelain 2>/dev/null | grep -v '^?? \.claude/')
if [ -n "${DIRTY}" ]; then
    echo "${DIRTY}" | head -20 | sed 's/^/  /'
    echo "error: Archive refused: uncommitted changes (commit or stash first)"
    exit 1
fi
exit 0
