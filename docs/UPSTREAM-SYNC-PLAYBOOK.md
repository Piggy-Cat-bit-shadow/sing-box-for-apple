# Upstream sync playbook

How to take a change from SagerNet's client into this fork without turning the next sync into
archaeology. Written for whoever runs it next — including an AI agent with no memory of the last
one.

**The governing rule**: `upstream/dev` is the only development reference. `main` and `stable` are
not merged into this branch. This fork has one integration branch and it follows one upstream
branch.

---

## 0. Before anything: know what you are looking at

```bash
GIT=<path to git>            # this environment carries a portable git; see §7
REPO=<checkout>

$GIT -C $REPO fetch upstream "+refs/heads/*:refs/remotes/upstream/*"
$GIT -C $REPO rev-parse upstream/dev
```

**Record the SHA.** Everything below is relative to a fixed commit, and a floating `upstream/dev`
is how a comparison silently becomes meaningless. The current pin is

```
089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85   Bump version 1.15.0-alpha.11
```

and it is written down in `docs/APPLE-REFACTOR-BASELINES.md` together with the reason.

### Read the counts, then ignore them

```bash
$GIT -C $REPO merge-base upstream/dev HEAD
$GIT -C $REPO rev-list --left-right --count upstream/dev...HEAD
```

The second command's two numbers are **not a work list**. On this fork they have been misleading in
two separate ways, both measured:

1. **Commits already incorporated under other SHAs.** Eighteen of the fifty-three subjects
   `upstream/dev` appeared to hold uniquely already existed in the fork's history as
   differently-SHA'd commits, because the fork was rebuilt on a later `upstream/main` at some
   point. Cherry-picking them would apply each change twice. Always run the cherry-pick-aware form
   before believing a count:

   ```bash
   $GIT -C $REPO log --oneline --left-right --cherry-pick upstream/dev...HEAD
   ```

2. **A rebased merge base.** The fork's branch point (`2b1763a`) is not an ancestor of `upstream`'s
   history for the same subject — `git merge-base --is-ancestor 3bcb8ca 2b1763a` fails while
   `3bcb8ca..2b1763a` contains zero upstream commits. Treat the merge base as a hint, not a
   coordinate system.

### The only reliable unit is a file

```bash
# what upstream changed, relative to the fork's branch point
$GIT -C $REPO diff --name-status <branch-point>..upstream/dev

# what this fork changed, relative to the same point
$GIT -C $REPO diff --name-status <branch-point>..HEAD
```

Files in the first list but not the second are upstream's to change. Files in both are the
conflicts that need a decision. Files in the second only are this fork's work.

---

## 1. Classify every upstream change before touching anything

Walk `upstream/dev`'s commits since the last sync and put each in exactly one bucket. The bucket
decides what happens, and the classification is the work — the merge itself is usually mechanical.

| Bucket | What it looks like | What to do |
|---|---|---|
| **Upstream UI** | `ApplicationLibrary/Views/**`, `MacLibrary/**`, `SFI/MainView.swift`, `SidebarView`, `NavigationPage` | Take as-is. `upstream-files-untouched` will confirm it is byte-identical |
| **Shared business logic** | `Library/Network/**`, `Library/Database/**`, `Library/Shared/**` | Take as-is **unless** this fork has a reviewed modification there — the audit lists them |
| **Identity / protocol** | `PRODUCT_BUNDLE_IDENTIFIER`, `Variant.applicationName`, App Group, entitlements, `Info.plist` keys other than the display name | Never take a change here without reading it. These are the settings the brand rename is forbidden to touch |
| **Safety / lifecycle** | `ScreenStateObserver`, `ExtensionProvider`, tunnel start/stop, `HangWatchdog` | Read the diff, not the message. One of these was a real defect this fork had to fix (§3) |
| **Libbox API** | anything calling into the Go kernel | **Cannot be synced blind.** See §4 |
| **Build** | `project.pbxproj`, `Package.resolved`, `Makefile` | Take, then re-check §5 |

---

## 2. The merge, in the order that keeps conflicts small

1. **Branch first.** Never sync on top of uncommitted work, and never on top of a commit whose
   static audit is failing.

   ```bash
   python scripts/dev/audit_apple_ui_boundary.py --upstream-ref <old-pin>
   ```

   It must be `PASS 9  FAIL 0`. `UNKNOWN` is acceptable only if you know why and write it down.

2. **Merge upstream's commit range**, not a squashed blob:

   ```bash
   $GIT -C $REPO merge --no-ff upstream/dev
   ```

   A merge keeps upstream's history reachable, so the next sync's `--cherry-pick` comparison still
   works. A rebase or a squash destroys that and makes the next sync guess.

3. **Resolve conflicts by owner**, using the table from §1:
   - conflict in an upstream-UI file → **take upstream's side**, then check whether this fork
     actually needed its change there. If it did, the change belongs in a Hako-owned file instead
     (see §3).
   - conflict in a reviewed shared file → keep this fork's change, and re-read it against upstream's
     new version. Upstream may have fixed the same thing better.
   - conflict in `project.pbxproj` → **take upstream's side entirely**, then re-apply the four
     `CFBundleDisplayName` lines with `scripts/dev/set_display_name.py` if it is present, or by hand
     anchored on `INFOPLIST_FILE` as that script does. Never hand-merge a pbxproj.

4. **Re-run the audit** with the new pin:

   ```bash
   python scripts/dev/audit_apple_ui_boundary.py --upstream-ref upstream/dev
   ```

   Four outcomes, each with a different meaning:

   | Result | Meaning | Action |
   |---|---|---|
   | all `PASS` | the merge did not cross a boundary | continue |
   | `upstream-files-untouched` FAIL, listing files | upstream changed files this fork also changed, and the conflict resolution kept this fork's version | expected. For each, decide: is this fork's change still needed? If yes, add it to `REVIEWED_UPSTREAM_MODIFICATIONS` **with a reason**. If no, take upstream's |
   | `shared-pages-are-clean` or `no-reverse-dependency` FAIL | a merge resolution pulled a Hako symbol into upstream's pages | **stop.** This is the failure the whole arrangement exists to prevent |
   | `UNKNOWN` | a comparison could not be made | fix the comparison before continuing |

5. **Update the pin** in `docs/APPLE-REFACTOR-BASELINES.md`, with the new SHA and date.

---

## 3. The rule that decides where a change goes

This is the part that is easy to get wrong, and getting it wrong is what the last refactor had to
undo.

> **A change to how a page looks belongs in a file this fork owns.
> A change to what a page does belongs in the shared file, with a test.**

Concretely:

- Need a different visual on a page iPad or the Mac can also show? Create a Hako-owned variant and
  point `SFI/HakoPageContent.swift` at it. **Do not edit the shared page.**
- Need a genuine bug fix in a page that both presentations show? Fix the shared file, add it to
  `REVIEWED_UPSTREAM_MODIFICATIONS` with the reason, and keep the diff minimal so the next
  upstream change to that file still applies.
- Need a new shared token or environment value? Add it. Additive changes do not break upstream.
- Tempted to check `UIDevice` in a shared component? Don't. The one place the design family is
  decided is `SFIUIFamily.resolve(idiom:)`, and the audit asserts it.

### Files that are hard boundaries

| Path | Owner | Rule |
|---|---|---|
| `ApplicationLibrary/Views/HakoStyle/**` | this fork | free to change |
| `SFI/HakoPhoneRootView.swift`, `SFI/HakoPageContent.swift` | this fork | free to change |
| `SFI/Application.swift` | shared, one function | change `SFIUIFamily` deliberately; the audit will notice |
| `ApplicationLibrary/Views/**` (everything else) | upstream | reviewed modifications only |
| `MacLibrary/**` | upstream | reviewed modifications only |
| `Library/**` | shared | take upstream; reviewed modifications only |

---

## 4. Libbox: the one thing that cannot be synced blind

`Libbox.xcframework` is **not in this repository** — `.gitignore` excludes it, and it is built from
the parent repository's `clients/apple` kernel. That has two consequences:

1. **Nothing can be compiled here.** Every "does this build" question is answered on a machine with
   Xcode and the framework.
2. **A change to a libbox call site cannot be validated at all here.** There is a live example:
   the fork carries a commit that rewrites twenty call sites from `address()` to `address()!.value`,
   on the theory that those methods now return a bound `StringBox`. `upstream/dev` calls
   `address()` directly. Neither side pins a framework version, so **nothing in this repository
   says which is right**.

   Do not pick one. The way to settle it:

   ```bash
   # with the framework in place
   xcrun swift-api-digester -dump-sdk -module Libbox -o /tmp/libbox.json -I <framework headers>
   grep -A2 'func address' /tmp/libbox.json
   ```

   and then make both the fork's branch and upstream agree with what it says.

**Never** change a libbox call site to make a static check pass. The failure it hides is a runtime
one in the tunnel.

---

## 5. Xcode project sync

The project uses **synchronised root groups** (`PBXFileSystemSynchronizedRootGroup`). A Swift file
dropped anywhere under `ApplicationLibrary/`, `SFI/`, `SFM/`, `Library/`, `MacLibrary/` and the
extension folders joins its target automatically. There is nothing to add to `project.pbxproj` for
a new source file.

What *does* need care:

- **`membershipExceptions`** lists files Xcode must keep out of a target — `Info.plist` inside a
  synchronised folder, and the `Application.swift` files that two targets share a folder with.
  These are upstream's own arrangement. Do not "clean them up".
- **`IPHONEOS_DEPLOYMENT_TARGET`.** The fork raised it to 16.0 across the SFI side; an upstream
  merge will bring 15.0 back where upstream still supports it. Decide deliberately: raising it
  drops iOS 15 users, and 15.0 is upstream's published floor. This branch **kept 15.0** and
  guarded the 16-only APIs instead.
- **`Localizable.xcstrings`.** Never replace this file wholesale. It is generated, it is 374 KB, and
  a fork's version diverges from upstream's by tens of thousands of lines because of key ordering.
  Add entries individually, in sorted position — `docs/APPLE-ARCHITECTURE-AUDIT.md` §3 describes the
  one entry this branch added.

---

## 6. What to run afterwards

```bash
# 1. the boundary must hold
python scripts/dev/audit_apple_ui_boundary.py --upstream-ref upstream/dev

# 2. the audit must still be able to fail
python scripts/dev/test_audit_apple_ui_boundary.py

# 3. the business logic, on a machine with Swift
scripts/run-subscription-usage-tests.sh

# 4. whitespace and submodule drift
$GIT -C $REPO diff --check
$GIT -C $REPO submodule status
```

Then, on a Mac with the framework in place:

```bash
DISABLE_SWIFTLINT=1 xcodebuild -project sing-box.xcodeproj -scheme SFI \
  -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
DISABLE_SWIFTLINT=1 xcodebuild -project sing-box.xcodeproj -scheme SFM \
  -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

and the device checklist in `docs/APPLE-DEVICE-ACCEPTANCE.md`.

---

## 7. Running this on Windows

This repository is worked on from Windows, which has two consequences.

**Git is portable and not on PATH.** It lives beside the other clients:

```powershell
$git = "C:\Deepseek\安卓客户端\.tools\git\cmd\git.exe"
& $git -C $repo status
```

The audit script finds it without configuration: it checks `DSH_GIT`, then PATH, then a short list of
known locations. Set `DSH_GIT` to override.

**`core.symlinks` is false.** `Tests/HakoSubscriptionUsage/Sources/{Core,Profile}` holds nine
Git symlinks into `Library/`, so the tests compile the files that ship. On Windows they check out as
one-line text files containing the target path, and `swift test` would fail there — but there is no
Swift toolchain on Windows either, so this costs nothing. On macOS and Linux they materialise as
real links.

**No Swift, no Xcode, no framework.** Every Apple-side gate is deferred. Say so; do not claim
otherwise.

---

## 8. Recovering from a bad sync

The integration branch is a normal branch; nothing about this playbook requires rewriting it.

```bash
# keep the merge commit but drop its changes
$GIT -C $REPO revert -m 1 <merge-commit>

# or back up entirely, keeping the attempt on a side branch
$GIT -C $REPO branch sync-attempt-<date>
$GIT -C $REPO reset --hard <last-good>
```

Two things are **not** recovery options, and both are forbidden by this repository's rules:

- `git push --force` to any branch. The old branches are read by other work; the fork's history is
  not a scratch pad.
- Updating the parent repository's `clients/apple` gitlink to point at a half-synced branch. The
  parent's `testing` reference is the shipping pointer, and it is updated deliberately, by the
  person who owns it, after a device pass — never as a side effect of a sync.
