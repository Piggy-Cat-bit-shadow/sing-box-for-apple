#!/usr/bin/env bash
# Run the macOS quota caption's decision-table tests.
#
# This package needs no link step: its two sources are committed symlinks into
# `Library/Network`, so `swift test` compiles the files that ship. Both are
# Foundation-only, which is why the package runs on a non-Apple host as well.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$root/Tests/SubscriptionQuotaCaption"
exec swift test "$@"
