#!/usr/bin/env bash
# Compiles and runs the primary-route mapping check.
#
# Why a standalone harness rather than a unit test target: the Apple project has no
# unit-test target, and this machine has no simulator runtime, so this is the only way to
# EXECUTE a decision the primary shell makes. Adding a test target would mean restructuring
# the project for one check.
#
# It links the framework the shipping app links, so the mapping and the state machine it exercises
# are the production ones, not a copy. Three properties of the dependency graph have to be
# reconstructed outside the Xcode build, and each is a packaging fact rather than a project one:
#
#   CrashReporter  ships a framework module map whose umbrella header only resolves inside a
#                  framework layout, so the harness assembles that layout in a temp directory;
#   libghostty     lives in an SPM artifact bundle, so its slice is added to the search path;
#   Libbox         is a STATIC Go framework that embeds C++ libraries ApplicationLibrary also
#                  embeds, so linking both is 87 duplicate symbols - an empty dynamic library with
#                  the same name satisfies the link and the real one is loaded at runtime.
#
# None of that touches the project, and nothing here reimplements production logic.
#
# STATUS: WORKS, and this header used to say the opposite.
#
# It read `BLOCKED_BY_ENVIRONMENT`, on the grounds that Library.framework's module interface
# re-exports PLCrashReporter as a FRAMEWORK Clang module and Clang resolves that module's umbrella
# header relative to the module map in the package checkout, where the header does not live:
#
#   plcrashreporter/Resources/CrashReporter.modulemap:2:19:
#     error: umbrella header 'CrashReporter.h' not found
#
# That diagnosis describes a real property of the dependency, but it is the property the
# CrashReporter shim below already exists to neutralise - it assembles the `CrashReporter.framework`
# layout Clang expects, in a temp directory, and passes it with `-F "$shim_root"`. The run reaches
# the harness and executes it: 55 cases pass against the built framework.
#
# What the header was really recording was one missing prerequisite, described with the wrong
# cause. `libbox` below is resolved RELATIVE to this repository's root, and a checkout that has
# never had Libbox installed fails the prerequisite loop with exit 2 before compiling anything.
# On this host the framework lives in the parent repository's `clients/apple`, so the run needs:
#
#   ln -sfn <parent>/clients/apple/Libbox.xcframework Libbox.xcframework   # gitignored path
#   scripts/dev/check-hako-primary-route.sh [derived-data-path]
#
# with the SFM scheme built into that derived-data path first. Exit 2 is the prerequisite check
# and not a compile failure; the two are distinguishable by whether swiftc ran at all.
#
# Separately, the harness's settings-push cases named `HakoSettingsPush.decide` and
# `HakoSettingsPush.Decision`, which the Hako migration renamed to `HakoSettingsRoute.decide` and
# the nested `HakoSettingsRoute.HakoSettingsPushDecision`. Those cases could not compile, so no
# harness run had ever executed them; the rename is in the same commit as this header.
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

# PLCrashReporter ships a FRAMEWORK module map, and Clang resolves a framework module's umbrella
# header relative to the framework layout - which only exists inside the Xcode build, so outside it
# the module cannot be built at all ("umbrella header 'CrashReporter.h' not found"). The package
# checkouts have the pieces, so the harness assembles the layout Clang expects in a temporary
# directory: Modules/module.modulemap copied and Headers/ symlinked. That is a property of how the
# dependency is packaged, not of this project, and nothing here copies production code.
ghostty="$packages/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64"

# Libbox is a STATIC Go framework whose archive embeds C++ libraries that ApplicationLibrary also
# embeds, so folding both into one binary is 87 duplicate symbols - and the module interface's
# autolink directive pulls it in whether or not this harness mentions it. An empty dynamic library
# with the same name satisfies the link step; the real Libbox is loaded at runtime from the built
# products, which is where DYLD_FRAMEWORK_PATH points. The harness calls none of its symbols.
libbox_stub="$(mktemp -d)/libbox-stub"
mkdir -p "$libbox_stub/Libbox.framework"
printf 'int hako_route_check_libbox_stub(void) { return 0; }\n' > "$libbox_stub/stub.c"
clang -dynamiclib -o "$libbox_stub/Libbox.framework/Libbox" "$libbox_stub/stub.c" \
    -install_name "@rpath/Libbox.framework/Libbox" 2>/dev/null
shim_root="$(mktemp -d)/shim"
shim_framework="$shim_root/CrashReporter.framework"
mkdir -p "$shim_framework/Modules" "$shim_framework/Headers"
cp "$packages/checkouts/plcrashreporter/Resources/CrashReporter.modulemap" "$shim_framework/Modules/module.modulemap"
for header in "$packages"/checkouts/plcrashreporter/include/*.h; do
    ln -sf "$header" "$shim_framework/Headers/$(basename "$header")"
done

xcc=(
    -Xcc "-I$packages/checkouts/GRDB.swift/Sources/GRDBSQLite"
    -Xcc "-I$packages/checkouts/GRDB.swift/Sources/GRDBSQLCipher/include"
    -Xcc "-I$packages/checkouts/plcrashreporter/include"
)

out="$(mktemp -d)/check-hako-primary-route"

# Linked against the built framework rather than compiled with the production sources: the page
# mapping's neighbours reference the whole view tree, so compiling sources would mean compiling the
# application. The framework is the module the shipping app links, so this exercises the same code.
# -parse-as-library: a single input file would otherwise be compiled as a script, where top-level
# code is allowed and @main is not. The harness has an explicit entry point instead.
swiftc \
    -parse-as-library \
    -I "$products" \
    -F "$libbox_stub" \
    -F "$products" \
    -F "$products/PackageFrameworks" \
    -F "$shim_root" \
    -F "$ghostty" \
    -I "$ghostty/Headers" \
    "${xcc[@]}" \
    -L "$products" \
    -framework ApplicationLibrary \
    -Xlinker -undefined \
    -Xlinker dynamic_lookup \
    -framework AppKit \
    -framework SwiftUI \
    -framework Network \
    -framework NetworkExtension \
    -framework Security \
    -framework SystemConfiguration \
    -framework IOKit \
    -framework IOUSBHost \
    -framework CoreWLAN \
    -framework CoreLocation \
    -lresolv \
    -lbsm \
    -lc++ \
    "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.profile_osx.a" \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$out" \
    scripts/dev/check-hako-primary-route.swift

# The framework is built with coverage instrumentation, so the harness writes a profile file. It is
# given a temporary directory to do that in: a stray default.profraw lands inside the repository and
# dirties the submodule, which the publish script's clean-tree gate - correctly - refuses to publish
# from.
scratch="$(mktemp -d)"
( cd "$scratch" && LLVM_PROFILE_FILE="$scratch/coverage.profraw" \
    DYLD_FRAMEWORK_PATH="$products:$libbox" "$out" )
