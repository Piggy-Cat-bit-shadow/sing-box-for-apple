# Profiles, imports, subscriptions

Profile import/export/UI belongs in the shared profile/database/network services; Hako supplies phone presentation. The fork's subscription work preserves usage metadata across parse, refresh/merge, persistence and display. `Tests/HakoSubscriptionUsage` is a SwiftPM package intended to test this seam with linked real sources plus stubs.

## Import presentation is a product trap, and it is gated

The phone's profile import must **not** be presented inside the modal form. `6240a74` routed
Hako profile imports outside it, and `747a5d8` added a guard for the rule. The reasoning is the
SwiftUI form-embedding class of bug: a navigation destination presented inside a `Form` inherits
the form's layout and pushes the row content into a container that cannot express it.

`audit_apple_ui_boundary.py` carries this as the `form-pages-are-not-embedded` check, which is
green at this baseline. This is one of the few places the knowledge base records UI structure on
purpose, because it encodes a known product trap rather than a layout preference.

## Test route

`run-subscription-usage-tests.sh` and `link-test-sources.sh` define the local test route. At this
Windows baseline Swift tooling cannot execute the package: its sources are git symlinks and the
checkout has no symlink support, so `swift test` fails at compile regardless of toolchain. The
suite is therefore `BLOCKED_BY_ENVIRONMENT`, and historical green claims must not be promoted to
current execution evidence. See `modules/tests-audits.md`.

## Data semantics

Remote refresh policy and usage values may be absent or stale by design; UI must distinguish unavailable data from a successful zero value.

The three count strings that were missing at the previous baseline — `%lld groups`,
`%lld active`, `%lld unread` — are present now, and the wider localization defect behind them is
recorded in `modules/localization-branding.md`. `String(localized:)` returning its own key on a
miss is why those labels rendered English without any error.
