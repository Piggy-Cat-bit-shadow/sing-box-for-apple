# AI entry point

1. Read `KNOWLEDGE/README.md` first, then `KNOWLEDGE/BASELINE.md`.
2. **This knowledge base describes the live product line.** Production implementation baseline
   `5cab4ec5bcb405265e077f8bdb6e287101af4405` on `main`, which is also the fork's default branch
   and the only remote branch. Earlier revisions of this file said the opposite — that the
   knowledge base was a frozen audit line 63 commits behind `main`. That is no longer true: the
   knowledge line was merged into `main` and the two are one line. See `KNOWLEDGE/BASELINE.md`.
3. Inspect `baseline..HEAD` (`git log --oneline` and `git diff --stat`) to classify the delta.
   At this refresh that range is 0 commits, because the baseline is the newest production commit;
   re-derive it rather than trusting that number.
4. Identify the affected ownership domains and deep-read only their module files.
5. Preserve iPhone Hako versus iPad/macOS upstream ownership unless the task explicitly changes product policy.
6. Treat source, Git, project settings, and executable audits as stronger than reports; archived/pending material is not current truth.
7. Do not rewrite this knowledge during ordinary feature work. Refresh it only for an explicit Knowledge Refresh.
8. Do not alter signing, entitlements, bundle/app-group identity, Runestone gitlink, release state, tags, or history without explicit authorization.
9. **Do not run `git fetch --prune`, `git remote prune`, or an aggressive `git gc` in this
   clone.** `main` is the only remote branch; every other fork line survives only as a local
   branch/remote-tracking ref or a tag. Prefer `git fetch --tags origin` (no `--prune`). The
   `archive/*` tags are the remote-preserved copies (see `KNOWLEDGE/BASELINE.md`). This caution was
   re-audited at the 2026-10-12 refresh and narrowed, not removed.
10. Normal development must not update `KNOWLEDGE/` in real time. Only an explicit
    Knowledge Refresh / Re-baseline runs `KNOWLEDGE/REFRESH.md`, which is the procedure
    for moving the knowledge baseline.
