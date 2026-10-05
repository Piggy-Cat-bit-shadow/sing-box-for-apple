#!/usr/bin/env bash
# Compiles and runs the primary-route mapping check.
#
# Why a standalone harness rather than a unit test target: the Apple project has no
# unit-test target, and this machine has no simulator runtime, so this is the only way to
# EXECUTE a decision the primary shell makes. Adding a test target would mean restructuring
# the project for one check.
#
# Why the sources and not the built framework: importing the framework drags in the Clang
# modules its interface re-exports (libghostty, GRDBSQLite, CrashReporter, ...), and
# reconstructing that module graph outside the Xcode build is whack-a-mole. The mapping and
# the shell's arming state machine depend only on NavigationPage, the palette and the theme,
# so the harness compiles exactly those files - the production sources, not a copy - together
# with the check. Library and Libbox are needed only because NavigationPage imports them.
#
# STATUS: BLOCKED_BY_ENVIRONMENT on this machine, and the blocker is precise rather than
# mysterious: Library.framework's module interface re-exports PLCrashReporter as a FRAMEWORK
# Clang module, and Clang resolves that module's umbrella header relative to the module map
# in the package checkout, where the header does not live:
#
#   plcrashreporter/Resources/CrashReporter.modulemap:2:19:
#     error: umbrella header 'CrashReporter.h' not found
#
# The Xcode build satisfies it with a generated framework layout that only exists inside the
# build. Until the project has a unit-test target (or someone runs this where that layout is
# available), the mapping's runtime half stays unverified exactly like the snapshot evidence;
# the extraction itself - a pure HakoPrimaryRoute and HakoPrimaryChildArmer used by the shell -
# is what the shell change is judged on.
#
# Usage: scripts/dev/check-hako-primary-route.sh [derived-data-path]
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

derived_data="${1:-/tmp/dd-mac}"
products="$derived_data/Build/Products/Debug"
libbox="Libbox.xcframework/macos-arm64_x86_64"

for required in "$products/Library.framework" "$libbox"; do
    if [ ! -e "$required" ]; then
        echo "FAIL: $required is missing; build SFM first:" >&2
        echo "      DISABLE_SWIFTLINT=1 xcodebuild -project sing-box.xcodeproj -scheme SFM \\" >&2
        echo "        -configuration Debug -destination 'generic/platform=macOS' \\" >&2
        echo "        -derivedDataPath $derived_data CODE_SIGNING_ALLOWED=NO build" >&2
        exit 2
    fi
done

# Library's interface re-exports the modules it was built against, so its Clang modules have
# to resolve too. This is the bounded set for the two files the check compiles.
packages="$derived_data/SourcePackages"
xcc=(
    -Xcc "-I$packages/checkouts/GRDB.swift/Sources/GRDBSQLite"
    -Xcc "-I$packages/checkouts/GRDB.swift/Sources/GRDBSQLCipher/include"
    -Xcc "-I$packages/checkouts/plcrashreporter/include"
    -Xcc "-fmodule-map-file=$packages/checkouts/plcrashreporter/Resources/CrashReporter.modulemap"
)

out="$(mktemp -d)/check-hako-primary-route"
swiftc \
    -I "$products" \
    -F "$products" \
    -F "$products/PackageFrameworks" \
    -F "$libbox" \
    "${xcc[@]}" \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$out" \
    ApplicationLibrary/Views/NavigationPage.swift \
    ApplicationLibrary/Views/HakoStyle/HakoTheme.swift \
    ApplicationLibrary/Views/HakoStyle/HakoSurface.swift \
    ApplicationLibrary/Views/HakoStyle/HakoPrimaryShell.swift \
    scripts/dev/check-hako-primary-route.swift

DYLD_FRAMEWORK_PATH="$products:$libbox" "$out"
