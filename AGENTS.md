# AI entry point

1. Read `KNOWLEDGE/README.md` first, then `KNOWLEDGE/BASELINE.md`.
2. **This knowledge base describes a frozen audit line, not live `main`.**
   Production baseline `f4a98590e9edaefc4a231b7f30d5b81a30917b66` on
   `jiejiebox/ne-p3-code-closure`. The fork's default branch is `origin/main`
   (`d0524912`), which is **63 commits ahead** and already fixes defects still present
   here. Before asserting anything about current behaviour, run
   `git log --oneline HEAD..origin/main` and `git diff --stat HEAD..origin/main`.
3. Inspect `baseline..HEAD` (`git log --oneline` and `git diff --stat`) to classify the
   delta — but read that as *this line's* delta only. It is 3 docs commits and says
   nothing about the product's.
4. Identify the affected ownership domains and deep-read only their module files.
5. Preserve iPhone Hako versus iPad/macOS upstream ownership unless the task explicitly changes product policy.
6. Treat source, Git, project settings, and executable audits as stronger than reports; archived/pending material is not current truth.
7. Do not rewrite this knowledge during ordinary feature work. Refresh it only for an explicit Knowledge Refresh.
8. Do not alter signing, entitlements, bundle/app-group identity, Runestone gitlink, release state, tags, or history without explicit authorization.
9. **Never run `git fetch --prune`, `git remote prune`, or an aggressive `git gc` in this
   clone.** Several fork lines now exist only as local `origin/*` refs — the remote
   branches are gone. Fetch with `git fetch --tags origin`; the `archive/*` tags are the
   remote-preserved copies (see `KNOWLEDGE/BASELINE.md`).
10. Normal development must not update `KNOWLEDGE/` in real time. Only an explicit
    Knowledge Refresh / Re-baseline runs `KNOWLEDGE/REFRESH.md`, which is the procedure
    for moving the knowledge baseline.
