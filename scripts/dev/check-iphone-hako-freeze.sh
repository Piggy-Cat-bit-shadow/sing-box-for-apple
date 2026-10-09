#!/usr/bin/env bash
#
# Guard the frozen iPhone Hako UI.
#
# The iPhone Hako UI was reviewed and accepted and its source is frozen. iPad and macOS work
# happens on `ipad-upstream-ui` and must not disturb it. This script proves that, or fails.
#
# Usage:
#   scripts/dev/check-iphone-hako-freeze.sh [TARGET_REF]
#
#   No argument   -> validates three layers independently: the HEAD commit tree, the Git index,
#                    and the real working tree. A deviation in ANY layer fails.
#   TARGET_REF    -> validates that commit/tree only. The working tree is not consulted, so a
#                    dirty checkout cannot mask or fake a result for a given ref.
#
# Exit status: 0 = frozen, 1 = FAIL, 2 = BLOCKED (baseline unavailable / git failed).
# It repairs nothing; a failure means a human decides, never a regenerated snapshot baseline.
#
# =============================================================================================
# What this version fixes, and why
#
# v1 protected four paths by running `git diff -- <path>` in its default mode. That command
# compares the working tree against the INDEX - it cannot see a change that has already been
# committed, and it does not see untracked files at all. So a committed drift, or a brand-new
# untracked file dropped into HakoStyle/, would have reported PASS. That is a silent hole in the
# one guarantee this project depends on most.
#
# v2 closes it by checking three layers separately and by comparing directory CONTENTS rather
# than running a diff:
#
#   HEAD tree   every protected path's blob as committed
#   index       every protected path's staged blob
#   worktree    the actual bytes on disk
#
# plus an entry-set comparison for HakoStyle/, which is what catches a file that was ADDED (in
# any layer, including untracked) or REMOVED. A `git diff` cannot express "this file should not
# exist", which is exactly the failure mode of a stray file appearing in a frozen directory.
#
# It also stops deriving the iPad root's expected content from the mutable `upstream/dev` ref and
# pins it to the fixed audited baseline commit instead, so upstream moving forward cannot make
# this check pass or fail for the wrong reason.
#
# Fail-closed: a missing tag, a missing expected blob, or a git error is BLOCKED/FAIL, never PASS.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 2

# --- pinned expectations ------------------------------------------------------------------------
#
# FROZEN_TAG is the immutable reference for the iPhone presentation. Never move or rebuild it.
FROZEN_TAG="${FREEZE_TAG:-iphone-hako-ui-freeze-v1}"

# The audited upstream baseline. Pinned by SHA on purpose: `upstream/dev` moves, and a checker
# whose expected value drifts with it would fail (or pass) for reasons that are not a regression.
#
# `FIXED_UPSTREAM_SHA_OVERRIDE` exists only so the negative-test script can point the pin at a
# commit that does not exist and prove the guard fails closed. It is not a normal-use knob.
FIXED_UPSTREAM_SHA="${FIXED_UPSTREAM_SHA_OVERRIDE:-3cc0835f2a44d9fc5ecc6140c149d374f915d43c}"

# Blob in FIXED_UPSTREAM_SHA->SFI/MainView.swift. This is upstream's iPad root, byte for byte.
EXPECTED_UPSTREAM_ROOT_BLOB="ae10d3e53ade2d91d59fdb8d7696d8bdec3dbb8b"

HAKO_STYLE_DIR="ApplicationLibrary/Views/HakoStyle"

# The one file in HakoStyle allowed to differ from the tag, and the only two edits permitted in
# it. Everything else in the directory must match its tagged blob exactly.
SHELL_PATH="${HAKO_STYLE_DIR}/HakoPrimaryShell.swift"

# Hako's phone root: the frozen path, and where it lives now.
FROZEN_ROOT_PATH="SFI/MainView.swift"
LIVE_ROOT_PATH="SFI/HakoPhoneRootView.swift"

# The phone's page names. These are checked as a MAPPING (case -> string), not as "the strings
# appear somewhere", so moving them to the wrong case still fails.
declare -a PHONE_TITLE_CASES=(dashboard groups settings)
declare -a PHONE_TITLE_VALUES=(Home Proxies More)

TARGET_REF="${1:-}"

# --- small helpers ------------------------------------------------------------------------------

FAILED=0
BLOCKED=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { printf '  %-58s %s\n' "$1" "$2"; }
fail() { printf '  %-58s %s\n' "$1" "$2"; FAILED=1; }
blocked() { printf '  %-58s %s\n' "$1" "$2"; BLOCKED=1; }

# Print the added/removed lines of a unified diff, indented. Keeps the output about WHAT moved.
show_moved_lines() {
    grep -E '^[+-][^+-]' | head -24 | sed 's/^/        /'
}

if ! git rev-parse --verify --quiet "refs/tags/${FROZEN_TAG}" >/dev/null; then
    echo "BLOCKED: freeze tag '${FROZEN_TAG}' not found." >&2
    echo "         Cannot prove the iPhone UI is unchanged without its baseline." >&2
    exit 2
fi
if ! git cat-file -e "${FIXED_UPSTREAM_SHA}^{commit}" 2>/dev/null; then
    echo "BLOCKED: fixed upstream baseline '${FIXED_UPSTREAM_SHA}' is not present in this clone." >&2
    echo "         The iPad root cannot be verified against a floating ref." >&2
    exit 2
fi

FREEZE_SHA="$(git rev-parse "refs/tags/${FROZEN_TAG}^{commit}")"

echo "iPhone Hako UI freeze check"
echo "  frozen baseline : ${FROZEN_TAG} (${FREEZE_SHA:0:12})"
echo "  upstream pin    : ${FIXED_UPSTREAM_SHA:0:12}"
if [ -z "$TARGET_REF" ]; then
    echo "  validating      : HEAD tree, index, working tree (all three)"
    LAYERS=(head index worktree)
else
    echo "  validating      : ${TARGET_REF} only (working tree not consulted)"
    LAYERS=(ref)
fi
echo

# --- expected HakoStyle entry set, derived from the tag -----------------------------------------

# Build the canonical list: "<relative path>\t<blob>".
git ls-tree -r "${FREEZE_SHA}" -- "$HAKO_STYLE_DIR" | awk '{print $3"\t"$4}' | sort -k2 > "$WORK/expected.tsv"

if [ ! -s "$WORK/expected.tsv" ]; then
    echo "BLOCKED: the frozen tag has no files under ${HAKO_STYLE_DIR}; refusing to report PASS." >&2
    exit 2
fi

# Derive the shell's permitted end state from the tag, once, and reuse it for every layer.
git show "${FREEZE_SHA}:${SHELL_PATH}" > "$WORK/expected-shell.swift" 2>/dev/null || {
    echo "BLOCKED: cannot read ${SHELL_PATH} from the frozen tag." >&2
    exit 2
}
python3 - "$WORK/expected-shell.swift" <<'PY' || exit 2
import sys
p = sys.argv[1]
s = open(p).read()

# Edit 1: widen the switch that upstream's restored `NavigationPage` makes necessary on iOS.
old = ("        #if os(macOS)\n"
       "            case .groups, .connections:\n"
       "                return .tools\n"
       "        #endif\n")
new = "        case .groups, .connections:\n            return .tools\n"
if s.count(old) != 1:
    sys.exit(f"BLOCKED: shell edit-1 anchor found {s.count(old)} times, expected 1")
s = s.replace(old, new)

# Edit 2: the phone's page-name mapping, which is what keeps Home / Proxies / More rendering.
anchor = "    var isHakoPrimaryRoot: Bool {\n        self == hakoPrimary.rootPage\n    }\n}"
if s.count(anchor) != 1:
    sys.exit(f"BLOCKED: shell edit-2 anchor found {s.count(anchor)} times, expected 1")
block = '''
    /// The name the Hako presentation shows for a page.
    ///
    /// `NavigationPage` carries upstream's vocabulary - Dashboard, Groups, Settings - because it is
    /// shared with the Mac and iPad presentations, which are upstream's. The Hako phone names its
    /// pages differently, and a name is presentation, so the mapping lives here with the rest of the
    /// Hako presentation instead of in the shared enum.
    ///
    /// This is the only reason the phone's navigation-bar title still reads "Home" and "More" now
    /// that `NavigationPage` has been restored to upstream.
    var hakoTitle: String {
        switch self {
        case .dashboard:
            return String(localized: "Home")
        case .groups:
            return String(localized: "Proxies")
        case .settings:
            return String(localized: "More")
        case .connections:
            return String(localized: "Connections")
        case .logs:
            return String(localized: "Logs")
        case .tools:
            return String(localized: "Tools")
        }
    }
}'''
s = s.replace(anchor, anchor[:-1] + block)
open(p, "w").write(s)
PY

# Derive the relocated root's permitted end state from the frozen root.
git show "${FREEZE_SHA}:${FROZEN_ROOT_PATH}" > "$WORK/expected-root.swift" 2>/dev/null || {
    echo "BLOCKED: cannot read ${FROZEN_ROOT_PATH} from the frozen tag." >&2
    exit 2
}
python3 - "$WORK/expected-root.swift" <<'PY' || exit 2
import sys
p = sys.argv[1]
s = open(p).read()

old, new = "struct MainView: View {", "struct HakoPhoneRootView: View {"
if s.count(old) != 1:
    sys.exit(f"BLOCKED: root type anchor found {s.count(old)} times, expected 1")
s = s.replace(old, new)

old_call = "        page.contentView\n            .navigationTitle(page.title)\n"
new_call = (
    "        page.contentView\n"
    "            // The Hako name, not upstream's: `NavigationPage` is shared with the Mac and iPad\n"
    "            // presentations and now carries their vocabulary, so the phone's naming comes from the\n"
    "            // Hako mapping. This is what keeps the phone's title reading \"Home\" and \"More\".\n"
    "            .navigationTitle(page.hakoTitle)\n"
)
if s.count(old_call) != 1:
    sys.exit(f"BLOCKED: root call-site anchor found {s.count(old_call)} times, expected 1")
s = s.replace(old_call, new_call)
open(p, "w").write(s)
PY

# --- per-layer validation -----------------------------------------------------------------------

# `layer_entries <layer>` prints "<blob>\t<path>" for HakoStyle as that layer sees it.
layer_entries() {
    local layer="$1"
    case "$layer" in
        head) git ls-tree -r HEAD -- "$HAKO_STYLE_DIR" | awk '{print $3"\t"$4}' ;;
        index) git ls-files -s -- "$HAKO_STYLE_DIR" | awk '$1!="160000"{print $2"\t"$4}' ;;
        worktree)
            # Real files on disk, tracked or not. This is what catches an untracked stray file.
            find "$HAKO_STYLE_DIR" -type f -print 2>/dev/null | sed 's|^\./||' | sort | while IFS= read -r p; do
                printf '%s\t%s\n' "$(git hash-object "$p" 2>/dev/null || echo UNKNOWN)" "$p"
            done
            ;;
        ref) git ls-tree -r "$TARGET_REF" -- "$HAKO_STYLE_DIR" | awk '{print $3"\t"$4}' ;;
        *) return 1 ;;
    esac
}

layer_label() {
    case "$1" in
        head) echo "HEAD tree" ;;
        index) echo "index" ;;
        worktree) echo "working tree" ;;
        ref) echo "$TARGET_REF" ;;
    esac
}

# `blob_of <layer> <path>` -> the blob id that layer holds for that path, or MISSING.
#
# Each layer has to be read its own way. Treating a non-`head` layer as "empty rev" and falling
# back to the working tree is what let an earlier revision of this guard consult the wrong layer -
# it is why `TARGET_REF` mode silently graded the checkout instead of the ref.
blob_of() {
    local layer="$1" path="$2"
    case "$layer" in
        head) git rev-parse "HEAD:${path}" 2>/dev/null || echo MISSING ;;
        ref) git rev-parse "${TARGET_REF}:${path}" 2>/dev/null || echo MISSING ;;
        index)
            local entry
            entry="$(git ls-files -s -- "$path" 2>/dev/null)"
            if [ -z "$entry" ]; then echo MISSING; else printf '%s' "$entry" | awk '{print $2}'; fi
            ;;
        worktree)
            if [ -f "$path" ]; then git hash-object "$path" 2>/dev/null || echo MISSING; else echo MISSING; fi
            ;;
        *) echo MISSING ;;
    esac
}

# `content_of <layer> <path>` -> writes that layer's bytes to stdout. Only used for the two files
# whose expected content is derived rather than a fixed blob.
content_of() {
    local layer="$1" path="$2"
    case "$layer" in
        head) git show "HEAD:${path}" 2>/dev/null ;;
        ref) git show "${TARGET_REF}:${path}" 2>/dev/null ;;
        index) git show ":${path}" 2>/dev/null ;;
        worktree) [ -f "$path" ] && cat "$path" ;;
    esac
}

for layer in "${LAYERS[@]}"; do
    label="$(layer_label "$layer")"
    echo "-- ${label}"

    # 1. entry set: nothing added, nothing removed.
    entries_file="$WORK/entries-${layer}.tsv"
    if ! layer_entries "$layer" > "$entries_file"; then
        fail "  (${label}) HakoStyle enumeration" "GIT FAILED"
        continue
    fi

    missing="$(comm -23 <(cut -f2 "$WORK/expected.tsv" | sort) <(cut -f2 "$entries_file" | sort))"
    extra="$(comm -13 <(cut -f2 "$WORK/expected.tsv" | sort) <(cut -f2 "$entries_file" | sort))"

    if [ -n "$missing" ]; then
        fail "  (${label}) missing HakoStyle file(s)" "FAIL"
        printf '%s\n' "$missing" | sed 's/^/        - /'
    fi
    if [ -n "$extra" ]; then
        fail "  (${label}) unexpected HakoStyle file(s)" "FAIL"
        printf '%s\n' "$extra" | sed 's/^/        + /'
    fi
    if [ -z "$missing" ] && [ -z "$extra" ]; then
        pass "  (${label}) HakoStyle entry set" "unchanged ($(wc -l < "$WORK/expected.tsv" | tr -d ' ') files)"
    fi

    # 2. per-file content, for every file except the shell.
    while IFS=$'\t' read -r expected_blob path; do
        [ "$path" = "$SHELL_PATH" ] && continue
        actual_blob="$(blob_of "$layer" "$path")"
        if [ "$actual_blob" = "MISSING" ]; then
            # Already reported by the entry-set check; do not double-count.
            continue
        fi
        if [ "$actual_blob" != "$expected_blob" ]; then
            fail "  (${label}) ${path#${HAKO_STYLE_DIR}/}" "CHANGED"
        fi
    done < "$WORK/expected.tsv"

    # 3. the shell, byte-exact after the two permitted edits.
    shell_actual="$WORK/actual-shell-${layer}.swift"
    if [ "$(blob_of "$layer" "$SHELL_PATH")" = "MISSING" ]; then
        : > "$shell_actual.missing"
    else
        content_of "$layer" "$SHELL_PATH" > "$shell_actual"
    fi
    if [ -f "$shell_actual.missing" ]; then
        : # entry-set check already reported it
    elif diff -q "$WORK/expected-shell.swift" "$shell_actual" >/dev/null 2>&1; then
        pass "  (${label}) HakoPrimaryShell.swift" "unchanged (2 permitted edits)"
    else
        fail "  (${label}) HakoPrimaryShell.swift" "CHANGED BEYOND PERMITTED EDITS"
        diff -u "$WORK/expected-shell.swift" "$shell_actual" 2>/dev/null | show_moved_lines
    fi

    # 4. the phone's page names, as a mapping.
    titles_ok=1
    for i in "${!PHONE_TITLE_CASES[@]}"; do
        case_name="${PHONE_TITLE_CASES[$i]}"
        value="${PHONE_TITLE_VALUES[$i]}"
        block="case .${case_name}:\n            return String(localized: \"${value}\")"
        if ! grep -qz "$(printf "$block")" <(tr -d '\r' < "${shell_actual}" 2>/dev/null) 2>/dev/null; then
            # Fall back to a portable check: the case and its returned literal must be adjacent.
            if ! awk -v c="case .${case_name}:" -v v="return String(localized: \"${value}\")" '
                $0 ~ c { found=1; next }
                found && /return String\(localized:/ { if (index($0, v) > 0) ok=1; found=0 }
                END { exit ok ? 0 : 1 }' "${shell_actual}" 2>/dev/null; then
                titles_ok=0
                fail "  (${label}) phone title .${case_name}" "not mapped to \"${value}\""
            fi
        fi
    done
    [ "$titles_ok" = 1 ] && pass "  (${label}) phone titles Home/Proxies/More" "mapped"

    # 5. the relocated Hako phone root.
    root_actual="$WORK/actual-root-${layer}.swift"
    if [ "$(blob_of "$layer" "$LIVE_ROOT_PATH")" = "MISSING" ]; then
        : > "$root_actual.missing"
    else
        content_of "$layer" "$LIVE_ROOT_PATH" > "$root_actual"
    fi
    if [ -f "$root_actual.missing" ]; then
        if [ "$layer" = "head" ] || [ "$layer" = "ref" ]; then
            fail "  (${label}) ${LIVE_ROOT_PATH}" "MISSING"
        fi
    elif diff -q "$WORK/expected-root.swift" "$root_actual" >/dev/null 2>&1; then
        pass "  (${label}) ${LIVE_ROOT_PATH}" "unchanged (relocated)"
    else
        fail "  (${label}) ${LIVE_ROOT_PATH}" "CHANGED BEYOND PERMITTED EDITS"
        diff -u "$WORK/expected-root.swift" "$root_actual" 2>/dev/null | show_moved_lines
    fi

    # 6. the two frozen UI test files.
    for path in "SFIUITests/HakoNavigationUITests.swift" "SFIUITests/HakoSnapshotUITests.swift"; do
        expected_blob="$(git rev-parse "${FREEZE_SHA}:${path}" 2>/dev/null || echo MISSING)"
        if [ "$expected_blob" = "MISSING" ]; then
            blocked "  (${label}) ${path}" "BASELINE MISSING"
            continue
        fi
        actual_blob="$(blob_of "$layer" "$path")"
        case "$actual_blob" in
            MISSING) fail "  (${label}) $(basename "$path")" "MISSING" ;;
            "$expected_blob") pass "  (${label}) $(basename "$path")" "unchanged" ;;
            *) fail "  (${label}) $(basename "$path")" "CHANGED" ;;
        esac
    done

    echo
done

# --- upstream-owned files, pinned to the audited baseline ---------------------------------------
# Only meaningful against real content; checked once, against the worktree, plus the committed
# tree when validating the default three layers.
echo "-- upstream-owned iPad root (pinned to ${FIXED_UPSTREAM_SHA:0:12})"

check_upstream_root() {
    local where="$1" blob="$2"
    if [ "$blob" = "$EXPECTED_UPSTREAM_ROOT_BLOB" ]; then
        pass "  (${where}) SFI/MainView.swift" "byte-identical to upstream"
    else
        fail "  (${where}) SFI/MainView.swift" "DEVIATES FROM UPSTREAM ($blob)"
    fi
}

if [ -z "$TARGET_REF" ]; then
    check_upstream_root "HEAD tree" "$(git rev-parse "HEAD:SFI/MainView.swift" 2>/dev/null || echo MISSING)"
    check_upstream_root "working tree" "$(git hash-object "SFI/MainView.swift" 2>/dev/null || echo MISSING)"
    # And prove the pinned blob really is what the audited commit holds, so the pin cannot rot.
    actual_fixed="$(git rev-parse "${FIXED_UPSTREAM_SHA}:SFI/MainView.swift" 2>/dev/null || echo MISSING)"
    if [ "$actual_fixed" = "$EXPECTED_UPSTREAM_ROOT_BLOB" ]; then
        pass "  (pin) ${FIXED_UPSTREAM_SHA:0:12}:SFI/MainView.swift" "matches pinned blob"
    else
        blocked "  (pin) ${FIXED_UPSTREAM_SHA:0:12}:SFI/MainView.swift" "PIN STALE ($actual_fixed)"
    fi
else
    check_upstream_root "$TARGET_REF" "$(git rev-parse "${TARGET_REF}:SFI/MainView.swift" 2>/dev/null || echo MISSING)"
fi

echo

if [ "$BLOCKED" -ne 0 ]; then
    echo "BLOCKED: the guard could not establish its baseline. This is not a PASS."
    exit 2
fi
if [ "$FAILED" -ne 0 ]; then
    echo "FAIL: the frozen iPhone Hako UI changed."
    echo "      If that was intended it needs a deliberate decision and a new freeze tag -"
    echo "      not a regenerated snapshot baseline, and not an edit to this script."
    exit 1
fi

echo "PASS: the frozen iPhone Hako UI is unchanged in every checked layer."
exit 0
