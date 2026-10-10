# Apple device acceptance checklist

## Read this first — the iPad and Mac clients cannot be tested here, and that is permanent

**This is an iron rule of this project, not a temporary limitation** (铁律 · iron law):

* **The iPad and Mac clients are never tested on this machine — not on a device, and not in a
  simulator.** The environment does not permit it; they do not run. Do not try, do not "just verify
  the build launched", and do not record a UI result for them.
* **iPad and Mac are code-review-only surfaces.** The evidence for them is reading the code and the
  static audits below — `upstream-files-untouched`, `tablet-and-mac-entry`, `phone-entry`. Nothing
  else. A green compile is a compile, not acceptance.
* **Only the iPhone surface is testable**, and only the iPhone surface may carry a UI-test result.
  `SFI` builds, the iPhone simulator runs, and `HakoNavigationUITests` / `HakoSnapshotUITests` are
  real evidence for it.
* **A build command is not a test.** `xcodebuild build` for `SFM` (the Mac app) is a static check and
  is allowed and wanted. `xcodebuild test` against a Mac or iPad destination is what this rule
  forbids — it will fail or, worse, appear to pass for reasons unrelated to the product.

If you are an agent reading this: **do not spend a turn trying to run the iPad or Mac client.**
Report the code review, say the surface is not testable here, and move on. This section exists
because that mistake was made repeatedly, and each attempt cost a full test cycle and produced
nothing that could be believed.

Everything below this line is `DEFERRED` or `UNVERIFIED` and is kept as the list to run **on
hardware where those clients actually start** — not as a list to attempt here.

---

**Nothing in the rest of this file has been executed**, with one exception recorded in
`APPLE-UI-MAC-VERIFICATION-REPORT.md`: the **iPhone** simulator gates have now been run there
(`SFI` builds, 18/18 navigation, 24/28 snapshot, 33/33 screen-state), and the audit row above is
current. Every other item below is `DEFERRED` or `UNVERIFIED` until someone runs it and records the
result — and the iPad and Mac items cannot be run here at all, per the rule above.

Read `docs/APPLE-ARCHITECTURE-AUDIT.md` §7 first: it states exactly what *was* verified here
(source-level boundaries, on Windows) and what was not (everything on Apple platforms).

---

## 0. What is already verified, so it is not on this list

| Verified here | How |
|---|---|
| The phone route is chosen by the device idiom and nothing else | `scripts/dev/audit_apple_ui_boundary.py` → `phone-entry` **PASS** |
| Every idiom other than `.phone` reaches upstream's root | same → `tablet-and-mac-entry` **PASS** |
| No Hako symbol is reachable from upstream's pages | same → `shared-pages-are-clean`, `no-reverse-dependency` **PASS** (339 files, 0 matches) |
| Upstream's files are byte-identical | same → `upstream-files-untouched` **PASS** (449/459 identical, 10 reviewed) |
| The brand overlay is the only identity change | same → `branding` **PASS** |
| New source files join a target | same → `project-membership` **PASS** |
| The migration is additive | same → `subscription-feature` **PASS** |
| The audit can fail | `scripts/dev/test_audit_apple_ui_boundary.py` → 14/14 as designed |

None of that is a substitute for anything below. A static boundary audit proves where code *can*
go; it cannot prove what a person sees.

---

## 1. Build gates (Mac, `Libbox.xcframework` present)

Run these before any device work. A build failure invalidates the rest of the list, and the first
thing to check is §4.

```bash
cd <checkout>

# iPhone/iPad app + its extensions
DISABLE_SWIFTLINT=1 xcodebuild -project sing-box.xcodeproj -scheme SFI \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -40

# Mac app
DISABLE_SWIFTLINT=1 xcodebuild -project sing-box.xcodeproj -scheme SFM \
  -configuration Debug -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -40
```

- [ ] `SFI` Debug builds
- [ ] `SFI` Release builds
- [ ] `SFM` Debug builds
- [ ] `SFM` Release builds
- [ ] `SFT` builds unchanged, or a documented reason it does not (tvOS is out of scope; it must not
      have been *broken* by this work)
- [ ] `Jailbreak` build configuration compiles, if it is part of the release flow

**Expected failure modes and what they mean**

| Failure | Meaning |
|---|---|
| `While building for macOS, no library for this platform was found` | `Libbox.xcframework` has no macOS slice. An environment problem, not a code one — see §4 |
| `value of type 'String' has no member 'value'`, or the reverse | the `StringBox` question. See `docs/UPSTREAM-SYNC-PLAYBOOK.md` §4 |
| `cannot find 'HakoPhoneRootView' in scope` | the file is not in the `SFI` target. `project-membership` should have caught it; run the audit |
| `ambiguous use of 'remainingTrafficInfo'` | unlikely; the two declarations are in different types. Check the audit's `subscription-feature` evidence |

### 1.1 The unit tests, which need no simulator

```bash
scripts/run-subscription-usage-tests.sh
```

- [ ] All cases pass

This is the only executable test in the repository that covers the subscription feature. It compiles
the files that ship (through symlinks) against stubs for GRDB and Libbox, and it is where the
`subscription-userinfo` parser, the merge rule and the record encoding are actually exercised. If it
fails, treat it as a product bug, not a test problem.

- [ ] `Frameworks/Runestone` is checked out (`git submodule update --init Frameworks/Runestone`)

---

## 2. iPhone

Launch on an iPhone or an iPhone simulator.

### 2.1 The shell

- [ ] The app launches into the Hako shell: three destinations — **Home / Tools / More**
- [ ] The tab bar's labels read Home, Tools, More (not Dashboard, Tools, Settings)
- [ ] The badge on Tools counts the same things it did before (tools badge + failed Taildrop
      sessions)
- [ ] Each root page's title is **inline**, not a large system title
- [ ] Logs is a **child of Tools**, not a fourth tab: selecting it pushes, and Back returns to the
      Tools root
- [ ] Open Logs, switch to Home, switch back to Tools → **Logs is still open** (this was a real
      regression in the fork's history; the arming rule guards it, but confirm on device)
- [ ] Deep links still land: the crash-report notification selects Tools; a settings notification
      selects More
- [ ] `-FASTLANE_SNAPSHOT` + `SCREENSHOT_PAGE=<page>` still starts on the named page

### 2.2 Home

- [ ] The page draws with no profile configured, and says so
- [ ] With a profile: the card grid draws, and each card that should be hidden when disconnected is
      hidden
- [ ] Start / Stop works from the page's own control
- [ ] The profile card's menu opens the picker, the QR sheet and the editor
- [ ] System HTTP proxy card appears only when the system proxy is available and connected
- [ ] **Known gap**: this is upstream's card grid, not the fork's Hako Home page. Do not record
      "Hako Home" as verified. See `docs/pending/README.md`

### 2.3 Profiles and the remaining-quota row — **the feature this refactor exists to keep**

- [ ] Profile picker opens; rows show **type · remaining quota · last update**
- [ ] A remote profile whose panel sends `subscription-userinfo` shows e.g. `远程 75 GB 可用 6天前`
      (Chinese) or `Remote 75 GB left 6d ago` (English)
- [ ] A remote profile whose panel sends **no** `subscription-userinfo` shows **no quota item at
      all** — not `0 B`, not `0 GB`
- [ ] A panel reporting `total=0` also shows no quota item
- [ ] A panel reporting a remainder larger than the total shows `0 B`, never a negative number
- [ ] A very large quota reads `1.2 TB`, not `1200.0 GB`
- [ ] A quota of exactly 10 units reads `10 GB`, not `10.0 GB`
- [ ] English rows stay **one line** at the default text size (the layout's whole purpose)
- [ ] English rows stay one line at the largest non-accessibility text size
- [ ] Chinese rows keep the full relative time (`6天前`, not `6d ago`)
- [ ] Add / edit / delete / reorder profiles still work
- [ ] QR import and QR share still work
- [ ] **Update** on a remote profile refreshes the quota, and the timestamp moves
- [ ] Changing a profile's remote URL clears the old panel's quota **before** the next refresh
- [ ] A failed refresh (airplane mode) leaves the stored quota **intact** and shows an error
- [ ] Updating a profile whose configuration body is unchanged does **not** restart the tunnel
      (watch the tunnel status: it must stay connected)

### 2.4 Everything else on the phone

- [ ] Connect / disconnect; the tunnel comes up and the status reads correctly
- [ ] Proxies (Groups): list, expand a group, select an outbound
- [ ] Activity (Connections): list populates, rows are readable, closing works
- [ ] Logs: stream populates, scrolling works, the bottom accessory does not overlap the text
- [ ] Tools: every row opens its page (Tailscale, Taildrop, network quality, STUN, USB/IP, reports)
- [ ] More: every settings page opens (App, Core, Packet Tunnel, On Demand Rules, Profile Override,
      Remote Control, Sponsors)
- [ ] Remote control: pick a server, the chip appears in the navigation bar, disconnect ends it
- [ ] Network permission prompt appears on first run and its text is readable
- [ ] Location permission prompt (WiFi rules) appears and its text is readable
- [ ] Background / foreground: returning to the app reloads and does not lose the selected page
- [ ] Rotation and Split View on a **large** iPhone: the shell stays the shell

### 2.5 Screen state (the fix ported in `f77289f`) — **needs a device, not a simulator**

- [ ] Lock the device while connected, wait, unlock → the tunnel resumes and stays connected
- [ ] Receive a push notification while connected (the lock screen lights but the device stays
      locked) → the tunnel does **not** claim the device woke
- [ ] Lock while connected, leave it locked, check the log for the device-axis messages → no
      repeated wake/pause churn
- [ ] In Console: `log stream --predicate 'subsystem CONTAINS "sf" AND category == "ui"'` while
      locking and unlocking → transitions appear once each, not twice

---

## 3. iPad — the presentation that must be upstream's

**The single most important check in this file.** The product requirement is that an iPad is always
the official UI, in every window environment.

### 3.1 Entry

- [ ] The app launches into upstream's presentation: a **sidebar or tab bar with Dashboard, Logs,
      Tools, Settings** — *not* Home / Tools / More
- [ ] The title on the Dashboard page reads **"Dashboard"**, not "Home"
- [ ] The title on the settings page reads **"Settings"**, not "More"

If any of those three shows the phone's naming, the device split is broken. Record it as a **P0**
and stop.

### 3.2 Every window environment stays upstream

- [ ] Full screen landscape → upstream's split view / sidebar
- [ ] Full screen portrait → upstream's layout
- [ ] **Split View** (half screen) → **still upstream's presentation**, with upstream's adaptive
      layout. It must **not** become the three-tab Hako shell
- [ ] **Slide Over** (narrow) → still upstream's presentation
- [ ] **Stage Manager** with a small window → still upstream's presentation
- [ ] Rotate in each of the above → layout adapts, presentation does not change

`SidebarLayout.isEnabled(horizontalSizeClass)` is what decides compact vs regular *inside*
upstream's presentation. A narrow window is expected to fall back to upstream's compact **TabView**
(Dashboard / Logs / Tools / Settings) — that is upstream's own design, and it is **not** a failure.
A narrow window showing Home / Tools / More **is** a failure.

### 3.3 Pages reached inside upstream's presentation carry no Hako styling

For each: open it, look for a Hako canvas colour, Hako card shape, Hako row metric, or the phone's
wording.

- [ ] Dashboard (cards, traffic charts, runtime figures) — upstream's card language, glass on 26
- [ ] Dashboard Items sheet
- [ ] Settings → App / Core / Packet Tunnel / On Demand Rules / Profile Override / Remote Control /
      Sponsors — **system grouped form rows**, not painted Hako cards; row heights are the
      platform's
- [ ] Tools — upstream's sections and headings, not the Hako "questions as headings" restructure
- [ ] Logs — upstream's log surface and bottom accessory
- [ ] Proxies (Groups) — upstream's list and group rows
- [ ] Activity (Connections) — upstream's list
- [ ] Profile picker — the quota item is expected here too (it is a shared component), but the row's
      **chrome** must be upstream's
- [ ] Profile editor, QR sheets, new-profile flows
- [ ] Remote control

### 3.4 Nothing else changed

- [ ] The app's name under the icon reads **Jiejiebox**
- [ ] The document type still opens `.bpf` files from Files
- [ ] `sing-box://` URLs still open the app
- [ ] A VPN profile created before this work is still recognised and connectable
- [ ] Existing profiles, preferences and remote servers are all still there

---

## 4. Mac

### 4.1 Build

- [ ] `SFM` builds. If it fails on a missing macOS `Libbox` slice, record
      `UNVERIFIED: no macOS slice in Libbox.xcframework` and skip to §5. Do **not** patch the code
      to make it look buildable.

### 4.2 Presentation

- [ ] The main window is upstream's: sidebar, toolbar, detail column
- [ ] The sidebar reads **Dashboard / Logs / Tools / Settings** — not Home / Tools / More
- [ ] Sidebar selection, window commands and menu bar items behave as upstream's do
- [ ] Every settings page is upstream's grouped form, not a Hako page
- [ ] The menu bar extra works; the icon reflects stopped/running
- [ ] Mac-only features: terminal, font picker, Ghostty configuration, USB/IP provider
- [ ] Helper service / XPC / System Extension install, start and stop
- [ ] The app's name in the Dock and menu bar reads **Jiejiebox**
- [ ] `PRODUCT_NAME` was not changed: the built product is still named as before (check
      `SFM.app`'s bundle name, not its display name)

---

## 5. Cross-device data compatibility

Run on a device that had a **pre-refactor** build installed. Do not uninstall between.

- [ ] Existing profiles still open and connect (the `add_subscription_info` migration ran)
- [ ] Preferences (selected profile, card configuration, appearance) survive
- [ ] Remote servers and their secrets survive
- [ ] Reports (crash / OOM / power) written before the update are still listed and readable
- [ ] iCloud profiles still resolve (the container name was deliberately not changed)
- [ ] A profile created after the update, then read by a build without the new columns, still works
      — that is what the nullable columns are for
- [ ] Downgrading to the previous build after the migration does not corrupt the profile list

---

## 6. The framework question

- [ ] `Libbox.xcframework` present, with the slices each target needs:
      `ios-arm64`, `ios-arm64_x86_64-simulator`, and **`macos-arm64_x86_64`** if the Mac app is
      expected to build
- [ ] The client's Swift API matches the parent repository's kernel build:
      ```bash
      xcrun swift-api-digester -dump-sdk -module Libbox -o /tmp/libbox.json -I <headers>
      grep -A2 'func address' /tmp/libbox.json      # String or StringBox?
      grep -A2 'func name' /tmp/libbox.json
      ```
- [ ] Whichever it says, `Library/Network/ExtensionPlatformInterface.swift` agrees with it. This is
      the open question recorded in `docs/APPLE-ARCHITECTURE-AUDIT.md` §5.1 — it needs a person
      with the framework, not a guess

---

## 7. How to record the result

For each section, record one of:

| Marker | Meaning |
|---|---|
| **PASS** | executed, and it behaved as written |
| **FAIL** | executed, and it did not. Include what you saw and what you expected |
| **DEFERRED** | not executed. Say why |
| **UNVERIFIED** | could not be executed in the environment available |
| **N/A** | does not apply to this build, with the reason |

**Do not record `PASS` for anything not executed.** The whole point of this file is that the previous
round could not run it, and the value of the next round is in the difference between what was
checked and what was assumed.
