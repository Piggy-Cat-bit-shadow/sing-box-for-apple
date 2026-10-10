#!/usr/bin/env bash
# Run the screen-state policy tests.
#
# Links the app's own `ScreenStateObserver.swift` into the package, then runs it. Both steps are here
# rather than in the Package manifest because SwiftPM cannot express "compile this file from three
# directories up", and a copy of the file under test would stop testing the file that ships.
#
# Needs a Swift toolchain and nothing else: the package has no dependency on Apple frameworks,
# NetworkExtension or Libbox, so it builds and runs on Linux as well as on macOS.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$root/scripts/link-test-sources.sh"
cd "$root/Tests/HakoScreenState"
exec swift test "$@"
