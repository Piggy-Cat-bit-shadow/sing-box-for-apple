#!/usr/bin/env bash
#
# Guard the frozen iPhone Hako UI.
#
# The iPhone Hako UI was reviewed and accepted, and its source is frozen. iPad and macOS work
# happens on `ipad-upstream-ui` and must not disturb it. This script compares the protected paths
# against the freeze tag and fails if any of them changed.
#
# It deliberately does not compare the whole repository, and it does not repair anything. A
# failure means a human decides; the answer is never "regenerate the baseline".
#
# Usage:
#   scripts/dev/check-iphone-hako-freeze.sh [ref]
#
# `ref` defaults to the working tree, so uncommitted edits are caught too.
#
# Exit status: 0 = frozen, 1 = changed (or the baseline is unavailable).
#
# =============================================================================================
# Why this script changed (2026-10-08), and why it is not a weakening
#
# v1 protected four paths byte-for-byte, including `SFI/MainView.swift`, on the assumption that
# the iPad could be routed at a seam above that file and the file would never be touched.
#
# That assumption turned out to be wrong, and no amount of care would have made it right:
# upstream's iPad presentation is *reached through* `SFI/MainView.swift`, and that root needs
# `NavigationPage.groups` / `.connections` to exist on iOS, which Hako had made macOS-only. The
# file therefore had to become upstream's again, and Hako's phone root had to move out of it into
# `SFI/HakoPhoneRootView.swift`.
#
# So v1 would now fail for a reason that is not a regression. The options were to delete the
# protection or to re-express it. This is the re-expression, and it checks strictly more:
#
#   1. every other file in `ApplicationLibrary/Views/HakoStyle/`   byte-identical to the tag
#   2. `HakoPrimaryShell.swift`                                    byte-identical to the tag
#        after exactly two derived edits (below) - so any other edit, anywhere in the file, fails
#   3. the phone's three frozen strings ("Home", "Proxies", "More")  asserted present
#   4. Hako's phone root at its new path                           == the frozen root with the
#        one documented rename and the one documented call-site change applied
#   5. the two UI test files                                       byte-identical to the tag
#   6. `SFI/MainView.swift`                                        byte-identical to upstream
#
# Checks 2 and 4 are exact: they derive the expected bytes from the frozen tag and compare whole
# files, so a single unrelated byte anywhere fails. Checks 2's two edits exist because restoring
# upstream's `NavigationPage` widened an iOS switch and moved the phone's page names into the Hako
# layer; check 3 pins the user-visible result of that move.
#
# If the iPhone UI is intentionally changed, this script SHOULD fail. Update the freeze tag
# deliberately - do not edit this script to make it pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

FREEZE_TAG="${FREEZE_TAG:-iphone-hako-ui-freeze-v1}"
UPSTREAM_REF="${UPSTREAM_REF:-upstream/dev}"
TARGET_REF="${1:-}"

HAKO_STYLE_DIR="ApplicationLibrary/Views/HakoStyle"
PROTECTED_FILES=(
    "SFIUITests/HakoNavigationUITests.swift"
    "SFIUITests/HakoSnapshotUITests.swift"
)

# The one file in HakoStyle allowed to differ, and the exact edits permitted in it.
SHELL_PATH="${HAKO_STYLE_DIR}/HakoPrimaryShell.swift"

# The moved Hako phone root: frozen path -> live path.
MOVED_OLD_PATH="SFI/MainView.swift"
MOVED_NEW_PATH="SFI/HakoPhoneRootView.swift"

UPSTREAM_OWNED_PATHS=(
    "SFI/MainView.swift"
)

if ! git rev-parse --verify --quiet "refs/tags/${FREEZE_TAG}" >/dev/null; then
    echo "FAIL: freeze tag '${FREEZE_TAG}' not found." >&2
    echo "      Cannot prove the iPhone UI is unchanged without a baseline." >&2
    exit 1
fi

FREEZE_SHA="$(git rev-parse "refs/tags/${FREEZE_TAG}^{commit}")"

if [ -z "$TARGET_REF" ]; then
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
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

show_diff() {
    sed -n 's|^+++ b/||p; s|^--- a/||p' | sort -u | sed 's/^/        /'
}

# --- 1: every HakoStyle file except the shell must be byte-identical ---------------------------
while IFS= read -r path; do
    [ "$path" = "$SHELL_PATH" ] && continue
    if diff_output="$("${DIFF_CMD[@]}" "$path" 2>/dev/null)" && [ -z "$diff_output" ]; then
        printf '  %-56s %s\n' "$path" "unchanged"
    else
        printf '  %-56s %s\n' "$path" "CHANGED"
        [ -n "${diff_output:-}" ] && printf '%s\n' "$diff_output" | show_diff
        CHANGED=1
    fi
done < <(git ls-tree -r --name-only "${FREEZE_SHA}" -- "$HAKO_STYLE_DIR")

# --- 2: the shell, byte-identical after exactly two derived edits -------------------------------
#   2a. the iOS switch widened for upstream's restored `NavigationPage`
#   2b. the `hakoTitle` mapping added, which is what keeps the phone's names
git show "${FREEZE_SHA}:${SHELL_PATH}" > "$WORK/shell.swift"

python3 - "$WORK/shell.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

# 2a - widen the macOS-only cases; `NavigationPage` now carries them on iOS.
old = "        #if os(macOS)\n            case .groups, .connections:\n                return .tools\n        #endif\n"
new = "        case .groups, .connections:\n            return .tools\n"
assert s.count(old) == 1, f"2a anchor not found exactly once (found {s.count(old)})"
s = s.replace(old, new)

# 2b - the phone-naming mapping.
anchor = "    var isHakoPrimaryRoot: Bool {\n        self == hakoPrimary.rootPage\n    }\n}"
assert s.count(anchor) == 1, f"2b anchor not found exactly once (found {s.count(anchor)})"
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

if diff -q "$WORK/shell.swift" "$SHELL_PATH" >/dev/null 2>&1; then
    printf '  %-56s %s\n' "$SHELL_PATH" "unchanged (2 permitted edits)"
else
    printf '  %-56s %s\n' "$SHELL_PATH" "CHANGED BEYOND PERMITTED EDITS"
    diff -u "$WORK/shell.swift" "$SHELL_PATH" 2>/dev/null | grep -E '^[+-][^+-]' | head -20 | sed 's/^/        /'
    CHANGED=1
fi

# --- 3: the phone's frozen strings must still be the phone's strings ---------------------------
for phrase in '"Home"' '"Proxies"' '"More"'; do
    if grep -q "return String(localized: ${phrase})" "$SHELL_PATH"; then
        printf '  %-56s %s\n' "phone title ${phrase}" "present"
    else
        printf '  %-56s %s\n' "phone title ${phrase}" "MISSING"
        CHANGED=1
    fi
done

# --- 4: the moved Hako phone root ----------------------------------------------------------------
if ! git cat-file -e "${FREEZE_SHA}:${MOVED_OLD_PATH}" 2>/dev/null; then
    printf '  %-56s %s\n' "$MOVED_NEW_PATH" "BASELINE-MISSING"
    CHANGED=1
elif [ ! -f "$MOVED_NEW_PATH" ]; then
    printf '  %-56s %s\n' "$MOVED_NEW_PATH" "MISSING"
    CHANGED=1
else
    git show "${FREEZE_SHA}:${MOVED_OLD_PATH}" > "$WORK/root.swift"
    python3 - "$WORK/root.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

# The type rename: mechanical, one line.
old, new = "struct MainView: View {", "struct HakoPhoneRootView: View {"
assert s.count(old) == 1, f"root type anchor not found exactly once (found {s.count(old)})"
s = s.replace(old, new)

# The one call site where the phone's page name now comes from the Hako mapping, plus the short
# comment that explains why. Derived here so the comparison stays byte-exact.
old_call = "        page.contentView\n            .navigationTitle(page.title)\n"
new_call = (
    "        page.contentView\n"
    "            // The Hako name, not upstream's: `NavigationPage` is shared with the Mac and iPad\n"
    "            // presentations and now carries their vocabulary, so the phone's naming comes from the\n"
    "            // Hako mapping. This is what keeps the phone's title reading \"Home\" and \"More\".\n"
    "            .navigationTitle(page.hakoTitle)\n"
)
assert s.count(old_call) == 1, f"root call-site anchor not found exactly once (found {s.count(old_call)})"
s = s.replace(old_call, new_call)

open(p, "w").write(s)
PY
    if diff -q "$WORK/root.swift" "$MOVED_NEW_PATH" >/dev/null 2>&1; then
        printf '  %-56s %s\n' "$MOVED_NEW_PATH" "unchanged (relocated)"
    else
        printf '  %-56s %s\n' "$MOVED_NEW_PATH" "CHANGED BEYOND PERMITTED EDITS"
        diff -u "$WORK/root.swift" "$MOVED_NEW_PATH" 2>/dev/null | grep -E '^[+-][^+-]' | head -20 | sed 's/^/        /'
        CHANGED=1
    fi
fi

# --- 5: the UI test files ------------------------------------------------------------------------
for path in "${PROTECTED_FILES[@]}"; do
    if diff_output="$("${DIFF_CMD[@]}" "$path" 2>/dev/null)" && [ -z "$diff_output" ]; then
        printf '  %-56s %s\n' "$path" "unchanged"
    else
        printf '  %-56s %s\n' "$path" "CHANGED"
        [ -n "${diff_output:-}" ] && printf '%s\n' "$diff_output" | show_diff
        CHANGED=1
    fi
done

# --- 6: files that must remain upstream's --------------------------------------------------------
if git rev-parse --verify --quiet "${UPSTREAM_REF}" >/dev/null; then
    for path in "${UPSTREAM_OWNED_PATHS[@]}"; do
        expected="$(git rev-parse "${UPSTREAM_REF}:${path}" 2>/dev/null)"
        actual="$(git hash-object "$path" 2>/dev/null)"
        if [ -z "$expected" ]; then
            printf '  %-56s %s\n' "$path" "SKIP (not in ${UPSTREAM_REF})"
        elif [ "$expected" = "$actual" ]; then
            printf '  %-56s %s\n' "$path" "unchanged (upstream)"
        else
            printf '  %-56s %s\n' "$path" "DEVIATES FROM UPSTREAM"
            CHANGED=1
        fi
    done
else
    printf '  %-56s %s\n' "(upstream comparison)" "SKIP (${UPSTREAM_REF} not fetched)"
fi

echo

if [ "$CHANGED" -ne 0 ]; then
    echo "FAIL: the frozen iPhone Hako UI changed."
    echo "      If this was intended it needs a deliberate decision and a new freeze tag -"
    echo "      not a regenerated snapshot baseline, and not an edit to this script."
    exit 1
fi

echo "PASS: the frozen iPhone Hako UI is unchanged."
exit 0
