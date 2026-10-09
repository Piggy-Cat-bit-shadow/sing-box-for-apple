#!/usr/bin/env bash
# Point the subscription-usage test package at the app's own sources.
#
# The tests must compile the files that ship, not copies of them - a copy silently stops testing
# anything the moment the original changes. SwiftPM resolves symlinks to regular files, so the
# package targets can name real filenames while the content lives in `Library/`.
#
# Run this before `swift test` (or let `run-tests.sh` do both). Re-running is harmless.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
package="$root/Tests/HakoSubscriptionUsage"

core=(
    "Library/Network/SubscriptionInfo.swift"
    "Library/Shared/BlockingIO.swift"
    "Library/Network/RemoteProfileFetcher.swift"
    "Library/Database/RemoteProfileUpdatePolicy.swift"
    "Library/Database/RemoteRefreshApplier.swift"
)
profile=(
    "Library/Database/Profile.swift"
    "Library/Database/Profile+Hashable.swift"
    "Library/Database/Profile+RW.swift"
    "Library/Database/Profile+Update.swift"
)

# Relative targets, so the checkout stays where it is put: a link recorded against an absolute
# path would break as soon as the repository is cloned somewhere else.
link() {
    local source="$1" destination="$2"
    if [ ! -f "$root/$source" ]; then
        echo "missing source: $source" >&2
        exit 1
    fi
    local directory
    directory="$(dirname "$destination")"
    ln -sfn "$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$root/$source" "$directory")" "$destination"
}

for source in "${core[@]}"; do
    link "$source" "$package/Sources/Core/$(basename "$source")"
done
for source in "${profile[@]}"; do
    link "$source" "$package/Sources/Profile/$(basename "$source")"
done

echo "linked ${#core[@]} core and ${#profile[@]} profile source(s) into the test package"
