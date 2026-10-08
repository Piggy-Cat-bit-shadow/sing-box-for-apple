#!/usr/bin/env bash
#
# Guard the frozen iPhone Hako UI.
#
# The iPhone Hako UI was reviewed and accepted, and its source is frozen. iPad work happens on
# `ipad-upstream-ui` and must not disturb it. This script compares the protected paths against
# the freeze tag and fails if any of them changed.
#
# It deliberately does not compare the whole repository, and it does not repair anything. A
# failure means a human decides whether the change was intended; the answer is never "regenerate
# the baseline".
#
# Usage:
#   scripts/dev/check-iphone-hako-freeze.sh [ref]
#
# `ref` defaults to the working tree, so uncommitted edits are caught too. Pass a commit or
# branch to check something else, e.g. `... HEAD` or `... ipad-upstream-ui`.
#
# Exit status: 0 = frozen, 1 = changed (or the baseline is unavailable).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

FREEZE_TAG="${FREEZE_TAG:-iphone-hako-ui-freeze-v1}"
TARGET_REF="${1:-}"

# The protected iPhone UI surface.
#
# `SFI/MainView.swift` is on this list because this round's goal was to route the iPad at a seam
# above it, leaving the file untouched. If it ever has to change, that is exactly the event this
# check exists to force a conversation about.
PROTECTED_PATHS=(
    "ApplicationLibrary/Views/HakoStyle"
    "SFI/MainView.swift"
    "SFIUITests/HakoNavigationUITests.swift"
    "SFIUITests/HakoSnapshotUITests.swift"
)

if ! git rev-parse --verify --quiet "refs/tags/${FREEZE_TAG}" >/dev/null; then
    echo "FAIL: freeze tag '${FREEZE_TAG}' not found." >&2
    echo "      Cannot prove the iPhone UI is unchanged without a baseline." >&2
    exit 1
fi

FREEZE_SHA="$(git rev-parse "refs/tags/${FREEZE_TAG}^{commit}")"

if [ -z "$TARGET_REF" ]; then
    # Compare the tag against the working tree, so staged and unstaged edits are both visible.
    DIFF_CMD=(git diff --no-ext-diff --)
    TARGET_DESC="working tree"
else
    DIFF_CMD=(git diff --no-ext-diff "${FREEZE_SHA}" "${TARGET_REF}" --)
    TARGET_DESC="$TARGET_REF"
fi

echo "iPhone Hako UI freeze check"
echo "  baseline : ${FREEZE_TAG} (${FREEZE_SHA:0:12})"
echo "  comparing: ${TARGET_DESC}"
echo

CHANGED=0

for path in "${PROTECTED_PATHS[@]}"; do
    # `${path}` may be a directory; `git diff --` expands it to every file under it.
    if ! git cat-file -e "${FREEZE_SHA}:${path}" 2>/dev/null && [ ! -e "$path" ]; then
        printf '  %-56s %s\n' "$path" "MISSING"
        CHANGED=1
        continue
    fi

    if diff_output="$("${DIFF_CMD[@]}" "$path" 2>/dev/null)" && [ -z "$diff_output" ]; then
        printf '  %-56s %s\n' "$path" "unchanged"
    else
        printf '  %-56s %s\n' "$path" "CHANGED"
        if [ -n "${diff_output:-}" ]; then
            # Show which files moved, not the diff itself: this is a guard, not a review tool.
            printf '%s\n' "$diff_output" \
                | sed -n 's|^+++ b/||p; s|^--- a/||p' \
                | sort -u \
                | sed 's/^/        /'
        fi
        CHANGED=1
    fi
done

echo

if [ "$CHANGED" -ne 0 ]; then
    echo "FAIL: the frozen iPhone Hako UI changed."
    echo "      If this was intended, it needs a deliberate decision and a new freeze tag -"
    echo "      not a regenerated snapshot baseline."
    exit 1
fi

echo "PASS: the frozen iPhone Hako UI is byte-for-byte unchanged."
exit 0
