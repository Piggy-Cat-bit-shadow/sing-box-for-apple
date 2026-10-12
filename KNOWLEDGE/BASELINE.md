# Baseline pins

| Field | Value | Evidence |
|---|---|---|
| Generated | 2026-10-12 (Asia/Shanghai) | knowledge refresh inspection |
| Repository | `Piggy-Cat-bit-shadow/sing-box-for-apple` | `origin` remote |
| Knowledge / product HEAD | `f4a98590e9edaefc4a231b7f30d5b81a30917b66` | checked-out `jiejiebox/ne-p3-code-closure` |
| Working tree | clean when generated | `git status --short --branch` |
| GitHub default ref | `origin/dev` at `d1224bb5081b3df5d0ecc55b1bd3d72ea6c60628` | `origin/HEAD -> origin/dev` |
| Current product integration ref | `origin/jiejiebox/integrated` at `3a550d0de30e113c2dd11dcb92150ca08550d11c` | remote ref |
| Current closure ref | `origin/jiejiebox/ne-p3-code-closure` at this baseline | remote ref |
| Upstream | `SagerNet/sing-box-for-apple`, `upstream/dev` | remote |
| Upstream product reference pin | `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` | integration ancestry / audits |
| Hako original design source | `hako-ui@c1935cff77246f97498400f5a0a7f430cfabbd55` | README + migration/audit material |
| Hako freeze tag | `iphone-hako-ui-freeze-v1` -> `fc7f77b82a7ca432294addfa001fcacfd5776223` | annotated tag; do not move |
| Runestone gitlink | `baeb3cbf8332d26b4f7b4c175a01f288ebbf3e7f` | `git ls-tree HEAD Frameworks/Runestone` |
| Parent/core linkage | `EXTERNAL-CHECK-REQUIRED` | parent repo is outside this checkout; `Libbox.xcframework` is absent |

`main` is not the product authority for this baseline: `origin/main` is upstream-line history. `dev` remains GitHub's default but is also not the active fork product line. Do not silently merge, retag, or change the default branch to reconcile that governance state.
