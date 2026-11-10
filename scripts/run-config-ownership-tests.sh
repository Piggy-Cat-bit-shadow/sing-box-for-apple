#!/usr/bin/env bash
# Run the configuration-ownership contract tests.
#
# Links the app's own sources into the package, then runs it. Both steps are here rather than in the
# manifest because SwiftPM cannot express "compile these files from four directories up", and a copy
# of a file under test would stop testing the file that ships.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$root/scripts/link-test-sources.sh"
cd "$root/Tests/HakoConfigurationOwnership"
exec swift test "$@"
