#!/bin/bash
#
# Stamps the git commit and branch into the BUILT product's Info.plist.
#
# Run as the LAST Run Script build phase, after "Process Info.plist" — it edits
# "${TARGET_BUILD_DIR}/${INFOPLIST_PATH}", the copy inside the .app bundle. The
# source Info.plist is never touched, so this leaves no diff in the working tree
# (which would otherwise make every build mark itself dirty).
#
# Requires ENABLE_USER_SCRIPT_SANDBOXING = NO: the sandbox denies writes to paths
# outside the phase's declared inputs/outputs, and TARGET_BUILD_DIR is one.
#
# Never fails the build. Every value falls back to "unknown" — a missing git, a
# tarball export with no .git, or a CI checkout without history all produce a
# readable build rather than a broken one.

set -u

PLIST="${TARGET_BUILD_DIR:-}/${INFOPLIST_PATH:-}"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

GIT_COMMIT="unknown"
GIT_BRANCH="unknown"
FALLBACK_REASON=""

# Prefer Xcode's git; fall back to whatever is on PATH.
if GIT_BIN=$(xcrun --find git 2>/dev/null) && [ -x "${GIT_BIN}" ]; then
    :
elif GIT_BIN=$(command -v git 2>/dev/null) && [ -x "${GIT_BIN}" ]; then
    :
else
    GIT_BIN=""
    FALLBACK_REASON="no git binary on PATH and none from xcrun"
fi

if [ -z "${SRCROOT:-}" ] && [ -z "${FALLBACK_REASON}" ]; then
    FALLBACK_REASON="SRCROOT is unset in the script environment"
fi

if [ -n "${GIT_BIN}" ] && [ -n "${SRCROOT:-}" ]; then
    if "${GIT_BIN}" -C "${SRCROOT}" rev-parse --git-dir >/dev/null 2>&1; then

        if HASH=$("${GIT_BIN}" -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null) && [ -n "${HASH}" ]; then
            GIT_COMMIT="${HASH}"

            # Untracked files are counted as dirty on purpose: this project uses
            # Xcode synchronized folder groups, so an untracked .swift file in one
            # of them is compiled into the build even though it is not committed.
            # Excluding it would let a build claim a clean commit it does not match.
            if [ -n "$("${GIT_BIN}" -C "${SRCROOT}" status --porcelain 2>/dev/null)" ]; then
                GIT_COMMIT="${GIT_COMMIT}-dirty"
            fi
        fi

        if BRANCH=$("${GIT_BIN}" -C "${SRCROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null) && [ -n "${BRANCH}" ]; then
            # Detached HEAD reports "HEAD"; name it for what it is.
            if [ "${BRANCH}" = "HEAD" ]; then
                GIT_BRANCH="detached"
            else
                GIT_BRANCH="${BRANCH}"
            fi
        fi

        if [ "${GIT_COMMIT}" = "unknown" ] || [ "${GIT_BRANCH}" = "unknown" ]; then
            FALLBACK_REASON="${FALLBACK_REASON:-git found a repository at SRCROOT but rev-parse produced nothing (no commits yet, or unreadable history)}"
        fi
    else
        FALLBACK_REASON="${FALLBACK_REASON:-no git repository at SRCROOT '${SRCROOT}' (shallow/tarball export, or the sandbox is hiding .git)}"
    fi
fi

# A build that cannot name its own revision is worth flagging. Warning, never an
# error: a tarball export with no .git must still produce a usable build.
if [ "${GIT_COMMIT}" = "unknown" ] || [ "${GIT_BRANCH}" = "unknown" ]; then
    echo "warning: stamp_build_info: stamping GitCommit=${GIT_COMMIT} GitBranch=${GIT_BRANCH} — ${FALLBACK_REASON:-cause undetermined}. This build cannot be traced back to a revision."
fi

if [ ! -f "${PLIST}" ]; then
    echo "warning: stamp_build_info: no built Info.plist at '${PLIST}' — skipping stamp"
    exit 0
fi

# Add if the key is missing, Set if it already exists.
stamp() {
    local key="$1"
    local value="$2"
    if ! "${PLIST_BUDDY}" -c "Add :${key} string ${value}" "${PLIST}" >/dev/null 2>&1; then
        "${PLIST_BUDDY}" -c "Set :${key} ${value}" "${PLIST}" >/dev/null 2>&1 \
            || echo "warning: stamp_build_info: could not write ${key}"
    fi
}

stamp "GitCommit" "${GIT_COMMIT}"
stamp "GitBranch" "${GIT_BRANCH}"

# Read back, so a PlistBuddy write that failed for any reason is not silent.
# NOTE: this only proves the value was in the plist when THIS phase finished. It
# cannot catch a later task rewriting the plist — which is exactly what
# ProcessInfoPlistFile does when it is scheduled after this phase. That ordering
# has to be fixed in the build graph, not here.
READ_COMMIT=$("${PLIST_BUDDY}" -c "Print :GitCommit" "${PLIST}" 2>/dev/null || echo "")
READ_BRANCH=$("${PLIST_BUDDY}" -c "Print :GitBranch" "${PLIST}" 2>/dev/null || echo "")

if [ "${READ_COMMIT}" != "${GIT_COMMIT}" ] || [ "${READ_BRANCH}" != "${GIT_BRANCH}" ]; then
    echo "warning: stamp_build_info: read-back mismatch in '${PLIST}' — wrote GitCommit=${GIT_COMMIT} GitBranch=${GIT_BRANCH}, read GitCommit=${READ_COMMIT:-<missing>} GitBranch=${READ_BRANCH:-<missing>}"
fi

echo "stamp_build_info: GitCommit=${GIT_COMMIT} GitBranch=${GIT_BRANCH}"
exit 0
