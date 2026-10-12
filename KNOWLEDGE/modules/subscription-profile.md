# Profiles, imports, subscriptions

Profile import/export/UI belongs in the shared profile/database/network services; Hako supplies phone presentation. The fork's subscription work preserves usage metadata across parse, refresh/merge, persistence and display. `Tests/HakoSubscriptionUsage` is a SwiftPM package intended to test this seam with linked real sources plus stubs.

`run-subscription-usage-tests.sh` and `link-test-sources.sh` define the local test route. At this Windows baseline Swift tooling is unavailable, so the suite is `BLOCKED_BY_ENVIRONMENT`; historical green claims must not be promoted to current execution evidence.

Remote refresh policy and usage values may be absent or stale by design; UI must distinguish unavailable data from a successful zero value.
