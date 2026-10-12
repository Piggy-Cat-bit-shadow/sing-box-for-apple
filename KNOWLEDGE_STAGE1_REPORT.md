# Knowledge Stage 1 report — Apple

## Result

`KNOWLEDGE_STAGE1 = COMPLETE` for the inspected product worktree baseline `f4a98590e9edaefc4a231b7f30d5b81a30917b66`.

- `PRODUCTION_CODE_CHANGED = NO`
- `UI_CHANGED = NO`
- `GIT_HISTORY_REWRITTEN = NO`
- `BASELINE_PINNED = YES`
- `UPSTREAM_RELATIONSHIP_CAPTURED = YES`
- `HAKO_DESIGN_PROVENANCE_CAPTURED = YES`
- `COMMIT_PROVENANCE_BUILT = YES`
- `READY_FOR_INDEPENDENT_REVIEW = YES`

## Evidence captured

The checked-out closure head is `f4a9859`; `jiejiebox/integrated` is `3a550d0`; default `origin/dev` is `d1224bb`; upstream reference is `089d35e`; the Hako original is `c1935cf`; the immutable freeze tag resolves to `fc7f77b`; Runestone gitlink is `baeb3cb`. The fork product ancestry contains 86 commits over the upstream reference. Commit navigation classifies the routing/Hako, audit, subscription, screen-state and NE closure series rather than treating titles as proof.

The repository contains a governance distinction that must not be hidden: GitHub's default `dev` does not represent the active Hako product line. No branch/default/tag state was changed.

## Modules and limitations

The knowledge base records ownership, source/design provenance, shared profile/subscription data, screen-state/NetworkExtension races, signing/build contracts, gates and historical-document classifications. Parent/core pin and actual Libbox source are `EXTERNAL-CHECK-REQUIRED`. Windows lacks Xcode, Apple hardware and Libbox artifact, so build, simulator, device, signed tunnel and TestFlight outcomes are not claimed.

The Python-backed static gates were not run for this refresh because `python` is unavailable in the checked Windows environment (exit `9009`). `git diff --check` completed successfully; prior report pass counts remain historical evidence, not refresh evidence.

## Old documents

No historical evidence was deleted. Root and `docs/` material is classified in `KNOWLEDGE/modules/repository-history.md`; historical reports remain available but do not override source/Git.
