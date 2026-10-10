#!/usr/bin/env python3
"""Port the fork's `StartStopButton` as a Hako-owned component.

# Why a copy rather than upstream's button

The correction order's option C, exactly. Upstream's `StartStopButton` has drifted from the one the
phone's design was built on: it lost the `isCompact` parameter and the `install` closure, so a page that
wants the phone's header - a capsule sized to its label beside the configuration's name, and an install
action in the one state that exists to be fixed - cannot get it from upstream without editing a
component that an iPad and a Mac also use.

The phone's copy is `HakoStartStopButton`, in the fork's own namespace, reachable only from the phone.
Upstream's component is untouched. Code duplication is the accepted cost; appearance drift is not.

# The one dependency that is not a type

`hakoConnectionActionButtonStyle` already lives in `HakoStyle/HakoRow.swift`, so it is already
Hako-owned and the copy can call it as it stands.

# Why `--regenerate` alone no longer overwrites

The candidate is a fresh function of the pinned upstream text; the file on disk is the product of the last
run **plus every human repair since**. Regenerating over those repairs silently reverts them - the platform
guards and the renamed call sites this round restored come back spelled the upstream way - with exit status
0, and `audit_hako_lossless_parity.py` does not notice, because a deleted guard does not change the set of
UI tokens. So an existing, differing target now has to be authorized by name and by blob, exactly as
`migrate_secondary_page.py` requires; see `_safety_gate.OverwriteAuthorization`.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from _safety_gate import OverwriteAuthorization, plan_writes  # noqa: E402
from swift_directives import resolve  # noqa: E402

GIT = os.environ.get("DSH_GIT") or "git"
ROOT = os.path.dirname(os.path.dirname(HERE))
REPO = os.environ.get("DSH_REPO") or os.path.join(
    os.path.dirname(os.path.dirname(HERE)), "sing-box-for-apple")

FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
PLATFORM = "ios"

SOURCES = (
    {
        "label": "StartStopButton",
        "source": "ApplicationLibrary/Views/Dashboard/Components/StartStopButton.swift",
        "destination": "ApplicationLibrary/Views/HakoStyle/HakoStartStopButton.swift",
        "renames": (
            ("StartStopButton", "HakoStartStopButton"),
            ("ToggleConnectionButton", "HakoToggleConnectionButton"),
            ("PrimaryTintModifier", "HakoPrimaryTintModifier"),
        ),
    },
)

HEADER = '''//
//  {name}.swift
//  ApplicationLibrary
//
//  The phone's connect/stop control, from `hako-ui` @ `{fork_ref_short}`.
//
//  # Why this is a copy and not upstream's component
//
//  Upstream's `StartStopButton` is the tunnel's state machine and an iPad and a Mac use it, so it is
//  not the place to put the phone's metrics. It has also drifted from the one the phone's design was
//  built on: it no longer takes `isCompact` - the capsule sized to its own label that the phone's
//  header needs, because a full-width action beside the configuration's name pushes the name off the
//  row - and it no longer takes the `install` closure that makes the button the page's action in the
//  one state that exists to be fixed.
//
//  So the phone gets its own copy. This is deliberate duplication: two implementations of one state
//  machine, kept apart so that neither platform's design has to be renegotiated to change the other's.
//  `docs/HAKO-LOSSLESS-PARITY-AUDIT.md` records it.
//
//  Generated from `{fork_ref_short}` by `scripts/dev/port_hako_components.py`. Re-run that rather than
//  editing here.
//

'''


def git(*args: str) -> str:
    proc = subprocess.run([GIT, "-C", REPO, *args], capture_output=True)
    if proc.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: "
                         f"{proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout.decode("utf-8", "replace")


def main() -> int:
    check_only = "--check" in sys.argv
    regenerate = "--regenerate" in sys.argv
    guard = OverwriteAuthorization(sys.argv)

    resolved = git("rev-parse", f"{FORK_REF}^{{commit}}").strip()
    if resolved != FORK_REF:
        raise SystemExit(f"FAILED: {FORK_REF} resolved to {resolved}")
    print(f"    pin {FORK_REF[:7]}")

    items = []
    for component in SOURCES:
        print(f"  [{component['label']}]")
        source = git("show", f"{FORK_REF}:{component['source']}")
        text = resolve(source, PLATFORM)
        print(f"    resolved for {PLATFORM}: {len(source.splitlines())} -> {len(text.splitlines())}")

        for old, new in sorted(component["renames"], key=lambda pair: -len(pair[0])):
            text, count = re.subn(rf"\b{re.escape(old)}\b", new, text)
            if count == 0:
                raise SystemExit(f"FAILED [{component['label']}]: {old!r} appears nowhere")
            print(f"    {old} -> {new} ({count})")

        text = re.sub(r"\A(?://[^\n]*\n)+", "", text)
        text = HEADER.format(
            name=os.path.basename(component["destination"])[:-len(".swift")],
            fork_ref_short=FORK_REF[:7],
        ) + text

        if text.count("{") != text.count("}"):
            raise SystemExit(f"FAILED [{component['label']}]: braces unbalanced")

        destination = os.path.join(ROOT, component["destination"].replace("/", os.sep))
        items.append((component["label"], destination, text))

    _approved, failure = plan_writes(guard, items, "port_hako_components.py",
                                     plan_only=check_only, regenerate=regenerate)
    return failure or 0


if __name__ == "__main__":
    sys.exit(main())
