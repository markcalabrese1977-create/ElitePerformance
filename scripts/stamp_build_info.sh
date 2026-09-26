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

# Prefer Xcode's git; fall back to whatever is on PATH.
if GIT_BIN=$(xcrun --find git 2>/dev/null) && [ -x "${GIT_BIN}" ]; then
    :
elif GIT_BIN=$(command -v git 2>/dev/null) && [ -x "${GIT_BIN}" ]; then
    :
else
    GIT_BIN=""
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
    fi
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

echo "stamp_build_info: GitCommit=${GIT_COMMIT} GitBranch=${GIT_BRANCH}"
exit 0
