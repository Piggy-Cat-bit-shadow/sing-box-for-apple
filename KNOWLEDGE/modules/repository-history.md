# Repository history and document status

## Ref roles

`upstream/dev@089d35e` is the fixed official reference for this product line. `jiejiebox/integrated` is the integration lineage; `jiejiebox/ne-p3-code-closure` adds the NE closure fix. `r8/*` are construction/audit lines, with merge commits requiring child-diff review. `dev` is the current remote default but is historical/default governance state for this fork product. `main` and `stable` are preserved upstream lines. Do not infer equivalence from ahead/behind counts; use patch/diff analysis.

`iphone-hako-ui-freeze-v1` is a design-provenance tag and must not move. ABI tags (`libbox-stringbox-abi-*`) are historical ABI markers. Historical topic refs (`hako-ui`, `ipad-upstream-ui`, `fix/*`) are evidence, not automatic merge targets.

## Existing documentation classification

| Material | Classification | Current use |
|---|---|---|
| README, `APPLE-DEVICE-ACCEPTANCE.md`, visual acceptance, upstream playbook | KEEP | entry/checklist/procedure; verify against source |
| architecture audit, refactor baselines/final, phase status/reports, screen facts, migration/parity/reachability docs | ABSORB-INTO-KNOWLEDGE | evidence remains; this knowledge is the concise current map |
| Round 8/9 handoffs and remaining-failures docs | ARCHIVE | point-in-time forensic record |
| `docs/pending/` | ARCHIVE-ONLY | frozen unported/blocked material; never current shipping truth |
| root `APPLE-UI-MAC-VERIFICATION-REPORT.md` | ARCHIVE | evidence snapshot, not current design source |

Nothing was deleted or moved in Stage 1; classification is deliberately semantic so links and forensic evidence remain intact.
