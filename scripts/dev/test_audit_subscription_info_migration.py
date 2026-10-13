#!/usr/bin/env python3
"""Negative controls for `audit_subscription_info_migration.py`.

An audit that passes proves nothing on its own - it has to be shown to fail when the thing it
checks is actually broken. This stages a copy of the two real files, breaks exactly one property,
and asserts the audit reports it. It also asserts the audit *passes* on the unmodified files, so a
control cannot pass by the audit being broken in the other direction.

Two of these controls have already earned their keep. The first version of the audit's
"NOT NULL / default" check matched with a `[^)]*` pattern, which cannot cross the `)` in
`.datetime).notNull()` and so matched nothing at all; the control caught it. And the first version
of the rename control replaced the first occurrence of the name in `Profile.swift`, which is the
`@Published` property rather than the `Columns` case - renaming that alone does not change what
reaches the database, so the audit was right to pass and the control was testing nothing.

Run from anywhere: `python scripts/dev/test_audit_subscription_info_migration.py`
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
AUDIT_REL = os.path.join("scripts", "dev", "audit_subscription_info_migration.py")

CONTROLS = [
    (
        # The `Columns` case, not the `@Published` property that appears first in the file: only
        # the case decides what is written to the database.
        "the record's Columns case is renamed and the migration is not",
        "Profile.swift",
        [("case subscriptionInfoUpdatedAt", "case subscriptionCapturedAt")],
    ),
    (
        "the migration adds a backfill",
        "Database.swift",
        [
            (
                't.add(column: "subscriptionInfoUpdatedAt", .datetime)',
                't.add(column: "subscriptionInfoUpdatedAt", .datetime)\n'
                '                    try db.execute(sql: "UPDATE profiles '
                'SET subscriptionInfoUpdatedAt = lastUpdated")',
            )
        ],
    ),
    (
        "the migration makes the column NOT NULL",
        "Database.swift",
        [
            (
                't.add(column: "subscriptionInfoUpdatedAt", .datetime)',
                't.add(column: "subscriptionInfoUpdatedAt", .datetime).notNull()',
            )
        ],
    ),
    (
        "the migration gives the column a default",
        "Database.swift",
        [
            (
                't.add(column: "subscriptionInfoUpdatedAt", .datetime)',
                't.add(column: "subscriptionInfoUpdatedAt", .datetime).defaults(to: Date())',
            )
        ],
    ),
    (
        "the record stops encoding the column",
        "Profile.swift",
        [("container[Columns.subscriptionInfoUpdatedAt] = subscriptionInfoUpdatedAt", "")],
    ),
    (
        "the record stops decoding the column",
        "Profile.swift",
        [("subscriptionInfoUpdatedAt = row[Columns.subscriptionInfoUpdatedAt] ?? nil", "")],
    ),
    (
        "the migration stops adding the column at all",
        "Database.swift",
        [('t.add(column: "subscriptionInfoUpdatedAt", .datetime)', "// column removed")],
    ),
]


def stage(workspace):
    for name in ("Database.swift", "Profile.swift"):
        shutil.copy(
            os.path.join(ROOT, "Library", "Database", name),
            os.path.join(workspace, "Library", "Database", name),
        )
    shutil.copy(os.path.join(ROOT, AUDIT_REL), os.path.join(workspace, AUDIT_REL))


def run(workspace):
    result = subprocess.run(
        [sys.executable, os.path.join(workspace, AUDIT_REL)],
        capture_output=True,
        text=True,
    )
    return result.returncode, (result.stdout + result.stderr).strip()


def fresh_workspace():
    workspace = tempfile.mkdtemp(prefix="hako-migration-audit-")
    os.makedirs(os.path.join(workspace, "Library", "Database"))
    os.makedirs(os.path.join(workspace, "scripts", "dev"))
    return workspace


def main():
    print("=== control 0: the real files, unmodified (the audit must pass) ===")
    workspace = fresh_workspace()
    stage(workspace)
    code, out = run(workspace)
    print(out)
    print("exit code: %d" % code)
    shutil.rmtree(workspace, ignore_errors=True)
    if code != 0:
        print("the audit does not pass on the real files, so its controls mean nothing")
        return 1

    missed = 0
    for label, filename, replacements in CONTROLS:
        print("\n=== control: %s ===" % label)
        workspace = fresh_workspace()
        stage(workspace)
        path = os.path.join(workspace, "Library", "Database", filename)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for old, new in replacements:
            if old not in text:
                print("  could not stage this control: %r not found in %s" % (old, filename))
                missed += 1
                continue
            text = text.replace(old, new, 1)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

        code, out = run(workspace)
        print(out)
        print("exit code: %d" % code)
        if code == 0:
            print("  PROBLEM: the audit did not notice this break")
            missed += 1
        else:
            print("  ok: the audit caught it")
        shutil.rmtree(workspace, ignore_errors=True)

    print("\ncontrols run: %d, not caught: %d" % (len(CONTROLS), missed))
    return 1 if missed else 0


if __name__ == "__main__":
    sys.exit(main())
