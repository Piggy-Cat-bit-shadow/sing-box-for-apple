#!/usr/bin/env bash
# Run the subscription-usage tests.
#
# Links the app's own sources into the test package, then runs it. Both steps are here rather than
# in the Package manifest because SwiftPM cannot express "compile these files from two directories
# up", and a copy of the file under test would stop testing the file that ships.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$root/scripts/link-test-sources.sh"
cd "$root/Tests/HakoSubscriptionUsage"
exec swift test "$@"
