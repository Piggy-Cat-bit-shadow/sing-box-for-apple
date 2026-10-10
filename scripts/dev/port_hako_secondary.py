#!/usr/bin/env python3
"""Port the phone's second-level pages: every view the fork changed that the phone can reach.

# Why these are copies and not edits

Each of these files is upstream's, and an iPad or a Mac loads most of them too. The fork's change to
each is one Hako modifier - `.hakoNavigationChrome`, `HakoSettingsScaffold`, `HakoSelectionMark` - and
applying that modifier to the shared file is exactly the leak the platform boundary exists to prevent:
phase 1 did it to the official profile picker and an iPad showed a quota row upstream's picker does not
have. So each file is copied into the fork's namespace and the copy carries the modifier. The shared
file stays upstream's bytes.

# What "mechanically" means here

The copy is `git show c1935cf:<path>` with:
  * the platform conditionals resolved for iOS, because the phone's copy builds for one platform;
  * every file-level type renamed into the `Hako` namespace, because two files in one module may not
    declare the same name;
  * declarations that the shared tree already owns dropped, with the drop verified against that tree,
    because the fork's copies of them are stale;
  * a two-anchor completion for a body that has to change to compile against upstream rather than the
    fork's own helper.

There is no hand-editing step and no re-design step. Anything this script cannot express is a file
listed in `UNEXPRESSED` with the reason, rather than a file quietly left out.
"""
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from swift_directives import resolve  # noqa: E402

GIT = os.environ.get("DSH_GIT") or "git"
ROOT = os.path.dirname(os.path.dirname(HERE))
REPO = os.environ.get("DSH_REPO") or os.path.join(
    os.path.dirname(os.path.dirname(HERE)), "sing-box-for-apple")

FORK_REF = "c1935cff77246f97498400f5a0a7f430cfabbd55"
PLATFORM = "ios"
DESTINATION_DIR = "ApplicationLibrary/Views/HakoStyle/"

#: `(source path under ApplicationLibrary/Views, type renames, drops, completions)`.
#:
#: The renames move every file-level type the file declares. A type already prefixed `Hako…` needs no
#: entry because it cannot collide, and the script asserts that each rename it is given was found, so a
#: stale table stops the run rather than producing a file with two declarations of one name.
PAGES = (
    # ---- Proxies and Activity detail -------------------------------------------------------
    ("Connections/ConnectionView.swift",
     (("ConnectionView", "HakoConnectionView"),), (), ()),
    ("Groups/GroupView.swift",
     (("GroupView", "HakoGroupView"),), (), ()),
    ("Groups/GroupItemView.swift",
     (("GroupItemView", "HakoGroupItemView"),), (), ()),
    ("Tools/OutboundPickerView.swift",
     (("OutboundPickerView", "HakoOutboundPickerView"),), (), ()),

    # ---- More destinations -----------------------------------------------------------------
    ("Setting/CoreView.swift", (("CoreView", "HakoCoreView"),), (), ()),
    ("Setting/PacketTunnelView.swift",
     (("PacketTunnelView", "HakoPacketTunnelView"),), (), ()),
    ("Setting/OnDemandRulesView.swift",
     (("OnDemandRulesView", "HakoOnDemandRulesView"),), (), ()),
    ("Setting/ProfileOverrideView.swift",
     (("ProfileOverrideView", "HakoProfileOverrideView"),), (), ()),
    ("Setting/SponsorsView.swift", (("SponsorsView", "HakoSponsorsView"),), (), ()),
    ("Setting/FontPickerView.swift", (("FontPickerView", "HakoFontPickerView"),), (), ()),
    ("Setting/GhosttyConfigurationView.swift",
     (("GhosttyConfigurationView", "HakoGhosttyConfigurationView"),), (), ()),

    # ---- Tools destinations ----------------------------------------------------------------
    ("Tools/NetworkQualityView.swift",
     (("NetworkQualityView", "HakoNetworkQualityView"),), (), ()),
    ("Tools/STUNTestView.swift", (("STUNTestView", "HakoSTUNTestView"),), (), ()),
    ("Tools/CrashReportListView.swift",
     (("CrashReportListView", "HakoCrashReportListView"),), (), ()),
    ("Tools/OOMReportListView.swift",
     (("OOMReportListView", "HakoOOMReportListView"),), (), ()),
    ("Tools/PowerReportListView.swift",
     (("PowerReportListView", "HakoPowerReportListView"),), (), ()),
    ("Tools/CrashReportDetailView.swift",
     (("CrashReportDetailView", "HakoCrashReportDetailView"),), (), ()),
    ("Tools/OOMReportDetailView.swift",
     (("OOMReportDetailView", "HakoOOMReportDetailView"),), (), ()),
    ("Tools/PowerReportDetailView.swift",
     (("PowerReportDetailView", "HakoPowerReportDetailView"),), (), ()),
    ("Tools/ReportShared.swift", (), (), ()),
    ("Tools/TaildropView.swift", (("TaildropView", "HakoTaildropView"),), (), ()),
    ("Tools/USBIPServerView.swift",
     (("USBIPServerView", "HakoUSBIPServerView"),), (), ()),
    ("Tools/TailscaleExitNodePickerView.swift",
     (("TailscaleExitNodePickerView", "HakoTailscaleExitNodePickerView"),), (), ()),
    ("Tools/TailscaleSSHPromptView.swift",
     (("TailscaleSSHPromptView", "HakoTailscaleSSHPromptView"),), (), ()),
    ("Tools/ExportReportView.swift",
     (("ExportReportView", "HakoExportReportView"),), (), ()),

    # ---- Settings and shared chrome --------------------------------------------------------
    ("RemoteControl/RemoteControlView.swift",
     (("RemoteControlView", "HakoRemoteControlView"),), (), ()),
    ("Profile/ProfileSheetHelpers.swift", (), (), ()),
    ("Profile/NewProfileMenuView.swift",
     (("NewProfileMenuView", "HakoNewProfileMenuView"),), (), ()),
    ("Profile/NewProfileView.swift", (("NewProfileView", "HakoNewProfileView"),), (), ()),
    ("Profile/EditProfileView.swift", (("EditProfileView", "HakoEditProfileView"),), (), ()),
    ("Profile/EditorToolbarView.swift",
     (("EditorToolbarView", "HakoEditorToolbarView"),), (), ()),
    ("Profile/QRSDisplayView.swift",
     (("QRSDisplayView", "HakoQRSDisplayView"),), (), ()),
    ("Profile/ProfileActionToolbar.swift",
     (("ProfileActionToolbar", "HakoProfileActionToolbar"),), (), ()),
    ("Terminal/ThemePickerView.swift",
     (("ThemePickerView", "HakoThemePickerView"),), (), ()),
    ("Terminal/TerminalSessionContentView.swift",
     (("TerminalSessionContentView", "HakoTerminalSessionContentView"),), (), ()),
)

#: Files the fork changed that this script deliberately does **not** port, each with the reason. The
#: list exists so that "40 pages" cannot quietly become "the ones that were easy".
UNEXPRESSED = {
    "EnvironmentValues.swift":
        "declares `HakoCompactRowsKey` and the `hakoCompactRows` environment value. It is not a page "
        "and it is not in HakoStyle; it belongs with the phone's environment injection, which is "
        "SFI/HakoPhoneRootView.swift's job, and it needs a decision about whether upstream's own "
        "environment file should carry it.",
    "Abstract/GlobalChecksModifier.swift":
        "a shared modifier, reached from every platform. Adding the phone's behaviour here reaches an "
        "iPad, so it needs a narrower hook than a copy.",
    "Connections/ConnectionListViewModel.swift":
        "view-model state, not a view. The fork's two additions are `isLoading` being cleared when the "
        "client is not connected - a real defect fix that belongs in the shared view model - and a "
        "screenshot fixture.",
    "Groups/GroupListViewModel.swift":
        "the `testingItems` half of a latency sweep. Already applied to the shared view model in an "
        "earlier slice, so there is nothing left to port.",
}

HEADER = '''//
//  {name}.swift
//  ApplicationLibrary
//
//  The phone's {what}, from `hako-ui` @ `{short}`.
//
//  A copy rather than an edit, because `{source}` is upstream's and an iPad or a
//  Mac loads it too. Applying the fork's Hako modifier to the shared file is exactly the leak the
//  platform boundary exists to prevent. The shared file stays upstream's bytes.
//
//  Generated from `{short}` by `scripts/dev/port_hako_secondary.py`. The transform is mechanical:
//  platform conditionals resolved for iPhone, file-level types renamed into the Hako namespace, and
//  declarations the shared tree already owns dropped. Nothing about the page's drawing, spacing,
//  strings or behaviour is changed.
//

'''


def git(*args: str) -> str:
    proc = subprocess.run([GIT, "-C", REPO, *args], capture_output=True)
    if proc.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: "
                         f"{proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout.decode("utf-8", "replace")


def explain(path: str) -> str:
    """A short phrase for the header: what the page is."""
    stem = os.path.basename(path)[:-len(".swift")]
    words = re.findall(r"[A-Z][a-z0-9]*", stem) or [stem]
    return " ".join(words).lower()


def port(path: str, renames, drops, completions) -> str:
    source = git("show", f"{FORK_REF}:ApplicationLibrary/Views/{path}")
    text = resolve(source, PLATFORM)

    for old, new in sorted(renames, key=lambda pair: -len(pair[0])):
        text, count = re.subn(rf"\b{re.escape(old)}\b", new, text)
        if count == 0:
            raise SystemExit(f"FAILED [{path}]: {old!r} appears nowhere in the source")
        print(f"    {old} -> {new} ({count})")

    for anchor, old, new, why in completions:
        if anchor not in text:
            raise SystemExit(f"FAILED [{path}]: completion anchor missing: {anchor.splitlines()[0]!r}")
        if text.count(old) != 1:
            raise SystemExit(f"FAILED [{path}]: completion target appears {text.count(old)} times")
        text = text.replace(old, new, 1)
        print(f"    completion: {why}")

    text = re.sub(r"\A(?://[^\n]*\n)+", "", text)
    text = HEADER.format(name=os.path.basename(path)[:-len(".swift")], what=explain(path),
                         short=FORK_REF[:7], source=path) + text

    if text.count("{") != text.count("}"):
        raise SystemExit(f"FAILED [{path}]: braces unbalanced")
    if text.count("(") != text.count(")"):
        raise SystemExit(f"FAILED [{path}]: parentheses unbalanced")
    return text


def main() -> int:
    check_only = "--check" in sys.argv
    regenerate = "--regenerate" in sys.argv
    if git("rev-parse", f"{FORK_REF}^{{commit}}").strip() != FORK_REF:
        raise SystemExit("FAILED: the pinned reference did not resolve to itself")
    print(f"    pin {FORK_REF[:7]}; {len(PAGES)} page(s); {len(UNEXPRESSED)} recorded as not ported")

    written = unchanged = 0
    for path, renames, drops, completions in PAGES:
        print(f"  [{path}]")
        destination = os.path.join(ROOT, DESTINATION_DIR + "Hako" + os.path.basename(path))
        text = port(path, renames, drops, completions)
        if check_only:
            continue
        if os.path.exists(destination) and not regenerate:
            if io.open(destination, encoding="utf-8").read() != text:
                print("    differs from what this script would write; pass --regenerate",
                      file=sys.stderr)
                return 1
            unchanged += 1
            print(f"    unchanged ({len(text.splitlines())} lines)")
            continue
        io.open(destination, "w", encoding="utf-8", newline="").write(text)
        written += 1
        print(f"    wrote {os.path.relpath(destination, ROOT)}: {len(text.splitlines())} lines")
    print(f"\n  {written} written, {unchanged} already current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
