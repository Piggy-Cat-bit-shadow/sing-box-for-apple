#!/usr/bin/env bash
#
# Negative tests for scripts/dev/check-iphone-hako-freeze.sh.
#
# The freeze guard is only worth having if it actually fails when the frozen UI moves. This script
# injects each failure mode into a THROWAWAY clone and asserts the guard's exit code.
#
# It never touches the real repository:
#   - it clones into a temp directory (so the original's objects, refs and working tree are
#     untouched), and
#   - each scenario starts from a fresh `git checkout`/`reset --hard` INSIDE that clone.
#
# That isolation is the point: fault injection against the working repository would mean mutating
# the thing under test, and a corrupted freeze baseline is unrecoverable.
#
# Exit status: 0 = every scenario behaved as expected, 1 = at least one did not.
#
# Usage:
#   scripts/dev/test-iphone-hako-freeze.sh
#   KEEP_WORKDIR=1 scripts/dev/test-iphone-hako-freeze.sh    # keep the temp clone for inspection

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER_REL="scripts/dev/check-iphone-hako-freeze.sh"

# Expected exit codes from the guard.
PASS=0
FAIL=1
BLOCKED=2

TOTAL=0
UNEXPECTED=0

WORKDIR="$(mktemp -d)"
cleanup() {
    if [ "${KEEP_WORKDIR:-0}" = "1" ]; then
        echo "keeping temp clone at: $WORKDIR"
    else
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

echo "iPhone freeze guard - negative tests"
echo "  source repo : ${REPO_ROOT}"
echo "  scratch     : ${WORKDIR}"
echo

# Clone locally so nothing network-bound is involved and the original stays pristine.
if ! git clone --quiet --no-hardlinks --local "$REPO_ROOT" "$WORKDIR/repo" 2>"$WORKDIR/clone.err"; then
    echo "BLOCKED: could not clone the repository for fault injection." >&2
    cat "$WORKDIR/clone.err" >&2
    exit 2
fi
CLONE="$WORKDIR/repo"
cd "$CLONE" || exit 2

# Test the WORKING-TREE version of the guard, not whatever the last commit happened to contain.
# Without this the suite silently grades an older script: the first run of this file did exactly
# that, and reported PASS for committed drift, because the committed guard still had the v1 hole.
if [ -f "$REPO_ROOT/$CHECKER_REL" ]; then
    cp "$REPO_ROOT/$CHECKER_REL" "$CLONE/$CHECKER_REL"
fi

# The clone needs the freeze tag, which --local carries; assert it rather than assume.
if ! git rev-parse --verify --quiet refs/tags/iphone-hako-ui-freeze-v1 >/dev/null; then
    echo "BLOCKED: the freeze tag did not survive the clone; cannot run negative tests." >&2
    exit 2
fi

FREEZE_TAG_SHA="$(git rev-parse refs/tags/iphone-hako-ui-freeze-v1^{commit})"

# The pristine commit every scenario must start from. Captured now, because one scenario COMMITS
# its injected drift - and `reset --hard HEAD` would then reset to that dirty commit, quietly
# poisoning every later scenario. That was the second bug this suite found in itself.
BASE_SHA="$(git rev-parse HEAD)"

HAKO_DIR="ApplicationLibrary/Views/HakoStyle"
SHELL_FILE="$HAKO_DIR/HakoPrimaryShell.swift"
ROOT_FILE="SFI/HakoPhoneRootView.swift"
A_TEST="SFIUITests/HakoNavigationUITests.swift"

# `run_case <name> <expected-exit> <command...>`
run_case() {
    local name="$1" expected="$2"; shift 2
    TOTAL=$((TOTAL + 1))
    local out rc
    out="$("$@" 2>&1)"
    rc=$?
    local verdict
    if [ "$rc" -eq "$expected" ]; then
        verdict="ok"
    else
        verdict="UNEXPECTED"
        UNEXPECTED=$((UNEXPECTED + 1))
    fi
    printf '  [%-10s] %-52s expected=%s got=%s\n' "$verdict" "$name" "$expected" "$rc"
    if [ "$verdict" = "UNEXPECTED" ]; then
        printf '%s\n' "$out" | tail -8 | sed 's/^/        | /'
    fi
}

# Start every scenario from a clean clone state.
#
# The tag and the guard are restored unconditionally, because scenarios destroy both (the tag is
# deleted to prove fail-closed, the guard is overwritten to plant a fault). The first run of this
# suite forgot that, and one scenario's damage made every later scenario fail for the wrong reason.
reset_clone() {
    git -C "$CLONE" reset --hard --quiet "$BASE_SHA"
    git -C "$CLONE" clean -fdq
    if ! git -C "$CLONE" rev-parse --verify --quiet refs/tags/iphone-hako-ui-freeze-v1 >/dev/null; then
        git -C "$CLONE" update-ref refs/tags/iphone-hako-ui-freeze-v1 "$FREEZE_TAG_SHA"
    fi
    if [ -f "$REPO_ROOT/$CHECKER_REL" ]; then
        cp "$REPO_ROOT/$CHECKER_REL" "$CLONE/$CHECKER_REL"
    fi
}

guard() { bash "$CLONE/$CHECKER_REL" "$@"; }

# --- 1. clean -> PASS ---------------------------------------------------------------------------
reset_clone
run_case "clean working tree" "$PASS" guard

# --- 2. one byte changed in the WORKING TREE -> FAIL --------------------------------------------
reset_clone
printf '\n// injected\n' >> "$CLONE/$HAKO_DIR/HakoTheme.swift"
run_case "worktree byte change in HakoStyle" "$FAIL" guard

# --- 3. change only in the INDEX -> FAIL --------------------------------------------------------
reset_clone
printf '\n// injected\n' >> "$CLONE/$HAKO_DIR/HakoTheme.swift"
git -C "$CLONE" add "$HAKO_DIR/HakoTheme.swift"
run_case "staged-only change in HakoStyle" "$FAIL" guard

# --- 4. change COMMITTED, worktree clean -> FAIL (the hole v1 had) -------------------------------
reset_clone
printf '\n// injected\n' >> "$CLONE/$HAKO_DIR/HakoTheme.swift"
git -C "$CLONE" -c user.name=test -c user.email=test@example.com commit --quiet -am "inject committed drift"
run_case "committed drift, clean worktree" "$FAIL" guard

# --- 5. protected file deleted -> FAIL ----------------------------------------------------------
reset_clone
rm -f "$CLONE/$HAKO_DIR/HakoStatus.swift"
git -C "$CLONE" add -A "$HAKO_DIR" >/dev/null 2>&1
run_case "deleted HakoStyle file" "$FAIL" guard

# --- 6. new TRACKED file in the frozen directory -> FAIL ------------------------------------------
reset_clone
echo "// injected" > "$CLONE/$HAKO_DIR/HakoInjected.swift"
git -C "$CLONE" add "$HAKO_DIR/HakoInjected.swift"
run_case "new tracked HakoStyle file" "$FAIL" guard

# --- 7. new UNTRACKED file in the frozen directory -> FAIL (v1 could not see this) ---------------
reset_clone
echo "// injected" > "$CLONE/$HAKO_DIR/HakoUntracked.swift"
run_case "new untracked HakoStyle file" "$FAIL" guard

# --- 8. third, unpermitted edit in HakoPrimaryShell -> FAIL --------------------------------------
reset_clone
printf '\n// third change\n' >> "$CLONE/$SHELL_FILE"
run_case "HakoPrimaryShell extra edit" "$FAIL" guard

# --- 9. non-mechanical edit in the relocated root -> FAIL ----------------------------------------
reset_clone
printf '\n// third change\n' >> "$CLONE/$ROOT_FILE"
run_case "HakoPhoneRootView extra edit" "$FAIL" guard

# --- 10. a frozen UI test file changed -> FAIL ----------------------------------------------------
reset_clone
printf '\n// injected\n' >> "$CLONE/$A_TEST"
run_case "frozen UI test changed" "$FAIL" guard

# --- 11. TARGET_REF pointing at a deliberately modified commit -> FAIL ----------------------------
reset_clone
printf '\n// injected\n' >> "$CLONE/$HAKO_DIR/HakoCard.swift"
git -C "$CLONE" -c user.name=test -c user.email=test@example.com commit --quiet -am "inject for ref check"
BAD_REF="$(git -C "$CLONE" rev-parse HEAD)"
# Reset the working tree back to clean; the ref must still be judged on its own contents.
reset_clone
run_case "TARGET_REF = modified commit" "$FAIL" guard "$BAD_REF"

# --- 12. TARGET_REF pointing at the clean commit -> PASS ------------------------------------------
reset_clone
run_case "TARGET_REF = clean commit" "$PASS" guard HEAD

# --- 13. a modified ref must not be rescued by a clean worktree, nor the reverse ------------------
# The worktree is clean and HEAD is good, but the requested ref is bad. Only the ref may matter.
reset_clone
git -C "$CLONE" update-ref refs/heads/badref "$BAD_REF"
run_case "TARGET_REF bad while worktree clean" "$FAIL" guard badref

# --- 14. freeze tag missing -> BLOCKED, never PASS ------------------------------------------------
reset_clone
git -C "$CLONE" tag -d iphone-hako-ui-freeze-v1 >/dev/null 2>&1
run_case "freeze tag deleted" "$BLOCKED" guard

# --- 15. fixed upstream baseline absent -> BLOCKED, never PASS ------------------------------------
# Point the pin at a commit that cannot exist. The guard must refuse to report PASS.
reset_clone
TOTAL=$((TOTAL + 1))
out="$(cd "$CLONE" && FIXED_UPSTREAM_SHA_OVERRIDE=0000000000000000000000000000000000000000 \
    bash "$CHECKER_REL" 2>&1)"
rc=$?
if [ "$rc" -eq "$BLOCKED" ]; then
    printf '  [%-10s] %-52s expected=%s got=%s\n' "ok" "pinned baseline missing" "$BLOCKED" "$rc"
else
    printf '  [%-10s] %-52s expected=%s got=%s\n' "UNEXPECTED" "pinned baseline missing" "$BLOCKED" "$rc"
    printf '%s\n' "$out" | tail -6 | sed 's/^/        | /'
    UNEXPECTED=$((UNEXPECTED + 1))
fi

# --- 15b. the pin must not have rotted: it is still what the pinned commit really holds ----------
reset_clone
TOTAL=$((TOTAL + 1))
out="$(guard 2>&1)"
if printf '%s' "$out" | grep -q "matches pinned blob"; then
    printf '  [%-10s] %-52s expected=%s got=%s\n' "ok" "pinned upstream blob self-check" "present" "present"
else
    printf '  [%-10s] %-52s expected=%s got=%s\n' "UNEXPECTED" "pinned upstream blob self-check" "present" "absent"
    printf '%s\n' "$out" | grep -i "pin" | sed 's/^/        | /'
    UNEXPECTED=$((UNEXPECTED + 1))
fi

# --- 16. a floating upstream/dev move must NOT cause a false regression ---------------------------
# Simulate by asserting the guard never reads mutable upstream: it must pass while `upstream/dev`
# is absent entirely, because the expectation is pinned by SHA.
reset_clone
git -C "$CLONE" update-ref -d refs/remotes/upstream/dev >/dev/null 2>&1 || true
run_case "passes without upstream/dev present" "$PASS" guard

# --- summary --------------------------------------------------------------------------------------
echo
if [ "$UNEXPECTED" -ne 0 ]; then
    echo "FAIL: ${UNEXPECTED} of ${TOTAL} scenarios behaved unexpectedly."
    exit 1
fi
echo "PASS: all ${TOTAL} scenarios behaved as expected."
exit 0
