#!/usr/bin/env python3
"""Check the subscription-capture migration against the record that reads it.

This is NOT the migration test. A real one has to run GRDB's `DatabaseMigrator` against a real
SQLite database, and it cannot run everywhere: SwiftPM needs `git` to fetch GRDB, GRDB does not
support Windows, and a hand-written `ALTER TABLE` would test a re-implementation rather than the
migration. That test belongs on a machine with Xcode.

What this covers is the part that can be checked anywhere, and it is the part that actually rots:
the migration and `Profile.swift` are two files that must agree, and nothing in the compiler or in
the existing tests compares them. `Profile.swift` names its columns as Swift identifiers while the
migration names them as strings, so a rename on either side is silent until a user's database
fails to upgrade.

Four things are asserted:

1. the column the migration adds is one `Profile.Columns` declares;
2. the record encodes it and decodes it (both, or the round trip silently drops it);
3. the migration is additive and nullable - no `NOT NULL`, no default that could be mistaken for
   a real capture time;
4. the migration does not backfill. §22's `NO BACKFILL` is the whole point of the column: filling
   it from `lastUpdated` would fabricate exactly the false freshness it exists to prevent, and
   that is a one-line mistake nothing else would catch.

Exit code 0 when everything holds, 1 with a list of problems otherwise.
"""

import os
import re
import sys

MIGRATION_NAME = "add_subscription_info_updated_at"
COLUMN = "subscriptionInfoUpdatedAt"
#: The sibling columns from the earlier migration, which the record must keep handling.
LEGACY_COLUMNS = [
    "subscriptionUpload",
    "subscriptionDownload",
    "subscriptionTotal",
    "subscriptionExpire",
]

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATABASE = os.path.join(ROOT, "Library", "Database", "Database.swift")
PROFILE = os.path.join(ROOT, "Library", "Database", "Profile.swift")


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def migration_body(source):
    """The text of the migration registration, up to the closing of its closure."""
    start = source.find('registerMigration("%s")' % MIGRATION_NAME)
    if start < 0:
        return None
    # Walk braces from the first '{' after the registration so nested closures are included.
    brace = source.find("{", start)
    if brace < 0:
        return None
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    return None


def main():
    problems = []
    if not os.path.exists(DATABASE):
        print("missing %s" % DATABASE)
        return 1
    if not os.path.exists(PROFILE):
        print("missing %s" % PROFILE)
        return 1

    database = read(DATABASE)
    profile = read(PROFILE)

    body = migration_body(database)
    if body is None:
        print("no migration named %r in Database.swift" % MIGRATION_NAME)
        return 1

    # 1. The migration's column is one the record declares.
    added = re.findall(r'add\(column:\s*"([^"]+)"', body)
    if COLUMN not in added:
        problems.append(
            "the %r migration adds %s, not %r" % (MIGRATION_NAME, added or "nothing", COLUMN)
        )

    columns_block = re.search(r"enum Columns[^{]*\{(.*?)\n    \}", profile, re.S)
    if not columns_block:
        problems.append("Profile.Columns could not be read")
        declared = []
    else:
        declared = re.findall(r"\b(\w+)\b", columns_block.group(1).replace("case", " "))
    if COLUMN not in declared:
        problems.append("Profile.Columns does not declare %r" % COLUMN)
    for legacy in LEGACY_COLUMNS:
        if legacy not in declared:
            problems.append("Profile.Columns no longer declares %r" % legacy)

    # 2. The record both writes and reads it.
    if "container[Columns.%s]" % COLUMN not in profile:
        problems.append("Profile.encode(to:) does not write Columns.%s" % COLUMN)
    if "row[Columns.%s]" % COLUMN not in profile:
        problems.append("Profile.init(row:) does not read Columns.%s" % COLUMN)

    # 3. Additive, nullable, no default that could pass for a capture time.
    #
    # The window is taken from the column's own `add(column: ...)` rather than matched with a
    # `[^)]*` pattern: a modifier is written *after* the type, as in
    # `t.add(column: "x", .datetime).notNull()`, so a pattern that cannot cross a `)` silently
    # matches nothing. A negative control caught exactly that.
    statement = ""
    located = re.search(r'add\(column:\s*"%s"' % COLUMN, body)
    if located:
        statement = body[located.start() : located.start() + 240]
    if ".notNull" in statement:
        problems.append("the new column is NOT NULL, so an older row could not simply lack it")
    if "defaults(to:" in statement:
        problems.append(
            "the new column has a default, which every existing row would read as a real value"
        )
    if 'alter(table: "profiles")' not in body:
        problems.append("the migration does not alter the profiles table")

    # 4. No backfill. Any write to the column other than the schema change is one.
    for statement in re.findall(r"(?:execute|sql)\s*\(\s*sql:\s*\"([^\"]+)\"", database):
        if COLUMN.lower() in statement.lower() and "add column" not in statement.lower():
            problems.append("a migration statement writes %s: %r" % (COLUMN, statement))
    if re.search(r"UPDATE\s+profiles[^\"]*%s" % COLUMN, database, re.I):
        problems.append("an UPDATE backfills %s" % COLUMN)

    if problems:
        print("subscription-capture migration check FAILED:")
        for problem in problems:
            print("  - %s" % problem)
        return 1

    print(
        "subscription-capture migration check passed: %s adds a nullable %s with no default and "
        "no backfill; Profile declares, encodes and decodes it, and still declares %s."
        % (MIGRATION_NAME, COLUMN, ", ".join(LEGACY_COLUMNS))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
