# Product and scope

Jiejiebox is a non-official Apple fork of SagerNet's `sing-box-for-apple`. It overlays a preserved Hako experience on **iPhone only**, keeps iPad and macOS official UI, and shares one business/network/configuration layer. The core comes from the related Jiejiebox sing-box line, but the exact parent pin is `EXTERNAL_CHECK_REQUIRED` here.

Fork-delta rule: upstream is the implementation fact source for unchanged code; this fork and its commits are the product-difference source. Do not turn this into a complete upstream encyclopedia.

Current shipping/product truth is resolved from **`main`**, the fork's default branch and its only remote branch. This baseline describes `main` @ `5cab4ec`; the previously separate `jiejiebox/ne-p3-code-closure` and `jiejiebox/integrated` lines have been merged into it and are history. The old GitHub default `dev` **no longer exists** — it was audited (19 unique commits: 13 patch-identical to `main`, 6 superseded) and deleted, so any document that calls `dev` the default or treats it as product-bearing is stale.
