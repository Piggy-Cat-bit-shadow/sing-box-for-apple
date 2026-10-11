#!/usr/bin/env bash
# Run the interface-monitor startup policy tests.
#
# Links the app's own `InterfaceMonitorStartup.swift` into the package, then runs it. Both steps are
# here rather than in the Package manifest because SwiftPM cannot express "compile this file from
# three directories up", and a copy of the file under test would stop testing the file that ships.
#
# Needs a Swift toolchain and nothing else. The policy imports Foundation only - no NetworkExtension,
# no Libbox - so this runs on any macOS host, which is the whole reason the bound and the generation
# check live in a type of their own instead of inside the adapter that starts a real `NWPathMonitor`.
#
# What this does NOT cover, and cannot: whether a real `NWPathMonitor` delivers a first update in a
# given network state. That is `NEEDS_DEVICE` - airplane mode on hardware - and
# `NEEDS_DEVICE` is the honest answer rather than a substitute.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$root/scripts/link-test-sources.sh"
cd "$root/Tests/HakoInterfaceStartup"
exec swift test "$@"
