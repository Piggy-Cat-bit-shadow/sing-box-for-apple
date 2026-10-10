# 第二阶段最终报告

> **分支**：`jiejiebox/integrated` ｜ **推送**：`PUSHED` ｜ **末次提交**：`b62363e`
> **上游基线**：`upstream/dev` @ `089d35e` ｜ **Hako 参照**：`hako-ui` @ `c1935cf`
> **环境**：Windows，无 Xcode / macOS / Swift 工具链，`Libbox.xcframework` 不存在

---

## 首屏结论

| 判定项 | 结果 |
|---|---|
| **手机完整 Hako 一级页面迁移** | **COMPLETE** —— 6 个一级页面全部经 `HakoPageContent` 路由到 Hako 页面本体（Home、Logs、Proxies、Activity、Tools、More）。**二级页面仍未迁移**，见 C.3 |
| **iPad / macOS 上游所有权静态审计** | **PASS** —— 12 项检查全部 PASS，无 UNKNOWN |
| **Apple 编译** | **UNVERIFIED** —— 无 Xcode、无 macOS、无 `Libbox.xcframework` |
| **真机 / 模拟器** | **DEFERRED** —— 无 Apple 设备 |
| **Git 推送** | **PUSHED** —— 本地 SHA == 远端 SHA（三处独立读取一致） |

**「静态 11/12 全过」不能替代第一项。** 所有权边界是干净的，产品目标未完成。

---

## A. 事实核验与错误更正

### A.1 第二轮开工时的现场读取（FACT）

| 项目 | 值 |
|---|---|
| `origin/jiejiebox/integrated`（开工时） | `c9946f5d66d521a259b2b1222a072e2aa2710059`，与提示词一致 |
| `upstream/dev` | `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` |
| 并发前进 | 无。`origin/jiejiebox/integrated` 是 HEAD 的祖先 |
| 未提交改动 | 无 |
| 六个 `HakoPageContent` case | 提示词说「目前六个 case 都调用上游页面」——**核实：当时确实全部是上游页面**，只有路由层已就位 |

### A.2 第一阶段报告的一处错误归因（**已更正**）

第一阶段报告（`docs/APPLE-ARCHITECTURE-AUDIT.md` §5.2）写道：

> 上游把失败的 `notify_get_state` 发布为 `recordLockState(false)`，在该内核上是
> `Box.LockStateChanged(false)` → `lifecycle.woke()`，即解除设备暂停。

**这是错的，两处都错：**

1. **上游从不调用 `recordLockState`。** `SagerNet/sing-box` 的
   `experimental/libbox/command_server.go` 只声明 `Pause`、`Wake`、`WakeNow`、`RecordScreenState`
   ——`RecordLockState` 在该内核里**不存在**。
2. 上游只注册了一个通知名 `com.apple.iokit.hid.displayStatus`，**从未观测锁屏轴**。

上游的真实代码（`089d35e`，19 行）：

```swift
notify_get_state(token, &state)            // 返回码丢弃
commandServer.recordScreenState(state == 1)
if state == 1 {
    commandServer.wakeNow()                // ← 真正的缺陷
}
```

**真正的缺陷**是 `WakeNow()` 被挂在「屏幕亮起」上。在上游内核里它是
`instance.PauseManager().DeviceWake()`——**唯一解除设备暂停的调用**。而 iOS 上推送通知就会点亮锁屏，
于是口袋里的手机被当成「设备可用」，释放了健康检查、URLTest 与 provider 刷新。
上游自己的 `box_lifecycle.go` 明文写着这正是 power policy 要防止的 wake storm。

丢弃返回码是**第二个、更小**的缺陷：它产生的是错误的*显示*事实（`recordScreenState(false)`），
不是解锁，**不产生**解除暂停。

### A.3 更正后发现的更重要事实（**新证据**）

本 fork **不针对上游内核出货**。父仓库 `Piggy-Cat-bit-shadow/sing-box`（默认分支 `testing`）
的内核已经改造了这条路径：

| 内核 API | `SagerNet/sing-box` | `Piggy-Cat-bit-shadow/sing-box` |
|---|---|---|
| `RecordScreenState(on:)` | 只写 power report，**不碰暂停轴** | `+ Box.ScreenStateChanged(on)`；`on` = 仅 resume **EDGE** |
| `RecordLockState(locked:)` | **不存在** | `+ Box.LockStateChanged(locked)`；`false` = resume edge **且解除 LEVEL** |
| `WakeNow()` | `PauseManager().DeviceWake()`，客户端在屏幕亮起时调用 | 仍存在，语义收窄为「平台已另行确认的唤醒」 |

父仓库 `box_lifecycle.go` 第 16–21 行给出**契约表**，第 40–52 行点名缺失的客户端另一半：

> Before this file, the Apple level had no lift at all … and the shipped client never called the one
> method that did. … A platform that reports no such fact keeps the latch, and that is stated as a
> limitation rather than papered over with a guess: see the client patch in
> `docs/fork/apple-screen-state-observer.md`.

**结论**：第一阶段的客户端改动是**内核已经写好、并明文等待的客户端另一半**。
它的**论证**是错的，它的**改动**是对的。完整证据见 [`docs/SCREEN-STATE-FACTS.md`](SCREEN-STATE-FACTS.md)。

---

## B. 屏幕状态专项

### B.1 三类竞态的处理与判定

| 场景 | 判定 | 依据 |
|---|---|---|
| **部分注册** | `FIXED_WITH_TEST` —— 两者都尝试，任一失败则取消已成功者并上报失败的通知名（fail-closed） | 为什么 fail-closed 是对的：锁轴是**唯一**能解除 LEVEL 的来源；仅显示轴会精确复现内核文档所述的「进入 level、永不解除」。两个半成功不等价坏，所以选择都拒绝——保留内核文档中的回退（`sleep()`/`wake()`），并让失败进入日志而不是每次启动悄悄换一套暂停行为。**这是一个决定，写下来了** |
| **丢失解锁** | `RECOVERABLE_BY_DESIGN` + 残留 `NEEDS_DEVICE` | `ExtensionProvider.wake()` 调用 `resync()`，重读两个名字一次；快照只允许发布**睡眠**事实，所以 resume 能加暂停、不能凭空造唤醒。被挂起期间丢失的**锁**可恢复，丢失的**解锁**不可恢复（事实已消失）。残留形态：挂起期间解锁后不再有锁/解锁循环——释放由 governor 错峰，不是 wake storm |
| **快照编造唤醒** | `FIXED_WITH_TEST` | `notify_get_state` 对从未设置的 name 返回 `NOTIFY_STATUS_OK` 与 `0`，而锁轴的 `0` 是**已解锁**。`ScreenStatePolicy.decide` 因此拒绝任何来自 `.snapshot` 的非睡眠事实，但仍**记住**该值，使下一次真实跃迁能按它度量 |
| **cancel 竞态** | **`NO_BUG_FOUND`，附论证** | `observe()` 只从 notify 回调、`start()`、`resync()` 进入，三者都经 `syncOnQueue`，运行在观察者的**串行队列**上；`publish()` 是**同一队列上的同步调用**，不做任何派发。因此第二次 `isCurrent` 检查与 `publisher` 调用之间**没有任何东西能跑**。`cancel()` 在 `access` 下推进代际，但无法插入队列块中间。代际栅栏做的是实事——它挡住 `cancel()` **之前入队**的回调；此外还有第二道独立屏障：`observe` 还需要 `registration(for:)`，而 `cancel()` 已清空注册表 |

### B.2 实现改动：**无**

观察者与 `ExtensionProvider` 本阶段**未做任何修改**。实现已与内核契约一致，
按提示词自己的规则（「如果现有修复已正确且没有未决风险，就只补充分清事实的审计文档和测试，
不为改而改」），交付物是更正后的归因、内核契约证据，以及故障注入测试。

### B.3 测试

`Tests/HakoScreenState`：**33 个纯逻辑用例**，通过符号链接编译**出货的那份**
`Library/Network/ScreenStateObserver.swift`（经 `scripts/link-test-sources.sh`）。

覆盖：取值映射（含既非 0 也非 1 的值）；失败读不发不记；「失败的锁读绝不是解锁」的反事实；
重复值不构成边沿；快照只发睡眠事实、永不造唤醒；**完整真值表**（每个单元格都断言 unlock 不变量）；
两个名字都尝试且部分注册时清理无泄漏；失败后可重试；`start`/`cancel` 幂等；
`cancel()` 之后送达的回调不发；**在读取进行中调用 `cancel()`**；`resync` 可恢复丢失的锁且不能造唤醒；
`deinit` 释放 token。

**未执行**：本机无 Swift 工具链。`scripts/run-screen-state-tests.sh` 是运行命令。

### B.4 记录而不修改：屏幕关闭 ≠ 无需流量

热点场景（手机锁屏、电脑仍连着手机热点且需要转发）**客户端无法回答**：锁事实到暂停轴的映射在
内核（`box_lifecycle.go`），暂停设备仍转发什么在 `common/power` 与 governor。
从 Apple 客户端改这些等于无证据地改内核生命周期语义。登记为 `NEEDS_DEVICE`，
观察方式写在 `docs/SCREEN-STATE-FACTS.md` §6。

---

## C. Hako 页面迁移

### C.1 覆盖矩阵（审计脚本直接读取源码得出，非人工声明）

| 页面 | 参照（`hako-ui@c1935cf`） | `HakoPageContent` 路由 | 新文件 | 状态 |
|---|---|---|---|---|
| **Home** | `HakoHomeView.swift`（616 行） | `HakoHomeView` | `HakoStyle/HakoHomeView.swift`（600 行） | **MIGRATED** |
| **Logs** | `LogView.swift`（+52/-10） | `HakoLogView` | `HakoStyle/HakoLogView.swift` | **MIGRATED** |
| **Proxies**（groups） | `GroupListView.swift`（+273/-30） | `GroupListView`（上游） | — | **PENDING** |
| **Activity**（connections） | `ConnectionListView.swift`（+207/-34） | `ConnectionListView`（上游） | — | **PENDING** |
| **Tools** | `ToolsView.swift`（+304/-237） | `ToolsView`（上游） | — | **PENDING** |
| **More**（settings） | `SettingView.swift`（+427/-191） | `SettingView`（上游） | — | **PENDING** |

**6 / 6**。`hako-page-coverage` 检查**读取 `SFI/HakoPageContent.swift` 的 switch**，
所以「文件存在」无法被读成「页面已迁移」；无 `--allow-partial` 时它**失败**并点名其余四个。
逐项细节、参照 diff 与「新增页面的规则」见 [`docs/HAKO-UI-MIGRATION-MATRIX.md`](HAKO-UI-MIGRATION-MATRIX.md)。

### C.2 已完全迁移与部分迁移

**完全迁移**：Home（`HakoHomeView` 是 fork 自有页面，依赖全部在上游或 Hako 命名空间内解析）；
Logs 的**导航 chrome 与页面画布**。

**部分迁移**（点名，不掩盖）：

| 页面 | 已做 | 未做 | 原因 |
|---|---|---|---|
| Logs | 详情 chrome（圆形返回、内联居中标题、无根 tab bar）、页面画布 | 四处 `HakoEmptyState` 文案、日志表面的 `HakoCardSurface` | 它们是**私有内部视图的私有成员**（`LogContentInnerView.emptyContent` / `logScrollView`），外部无法触及。复制它们就是复制那 600 行——本文件存在的意义正是避免这件事 |
| Home | 外壳、头部、配置中心、模式行、快捷行、流量与运行时卡片、安装提示 | —— | 已完整 |

### C.3 二级页面（**仍未迁移**，点名）

六个一级页面是产品目标，已全部完成。但它们通往的**二级页面仍是上游的**，
参照改动对每一个都只是「一个修饰符或一行」。清单与顺序见迁移矩阵，按用户可达顺序：

| 分组 | 文件 | 参照改动 |
|---|---|---|
| Tools 目的地 | `NetworkQualityView`、`STUNTestView`、三份报告的 list 与 detail、`OutboundPickerView`、`TaildropView`、`USBIPServerView`、Tailscale 各页 | 每个 1–15 行 |
| More 目的地 | `CoreView`(212)、`PacketTunnelView`(158)、`OnDemandRulesView`(133)、`ProfileOverrideView`(74)、`SponsorsView`(29) | `HakoSettingsScaffold` |
| Proxies/Activity 详情 | `GroupView`(20)、`GroupItemView`(11)、`ConnectionView`(283) | 共享行语言 |
| 其它 | `TerminalSessionContentView`、`FontPickerView`、`ThemePickerView` | 各 1–4 行 |

**`MacAppView`（150 行）需要先单独判断**：它是应用设置页的 macOS 形态，
任何 Hako 变体都**不得**从 `SFM` 可达。

### C.4 本轮**修改的上游文件**（全部登记理由）

| 文件 | 改动 | 理由 |
|---|---|---|
| `ApplicationLibrary/Views/Log/LogView.swift` | `LogViewContent` 由 `private struct` 改为 `public struct`，`init` 加 `public`，`viewModel` 保持私有 | 让手机的 Logs 页能把 fork 的 chrome 套在**上游的内容**上，而不是复制 600 行。文件内部行为零改动 |

其余 9 个共享文件改动全部来自第一阶段，理由逐条写在审计脚本的 `REVIEWED_UPSTREAM_MODIFICATIONS` 里。
**官方 `ProfilePickerSheet.swift` 已恢复为上游字节**（见 §E.1）。

### C.5 不可静态验证的部分

`HakoHomeView`、`HakoLogView`、生成的 `HakoProfilePickerSheet` 全部**未经编译、未经运行**。
它们使用的上游 API 都经过逐个确认存在（`StartStopButton()`、`HTTPProxyCard` 的公开初始化器、
`OverviewViewModel.setSystemProxyEnabled`、`LogViewContent(commandClient:initialSearchText:)`），
但**符号存在不等于类型匹配**。见 `docs/APPLE-DEVICE-ACCEPTANCE.md`。

---

## D. iPad / Mac 官方 UI 边界

### D.1 检查结果

| 检查 | 结果 |
|---|---|
| 官方入口（`SFI/MainView.swift`、`MacLibrary/MainView.swift`、`SidebarView.swift`、`SidebarLayout.swift`、`NavigationPage.swift`） | **无任何 Hako 符号** |
| 官方 Profile Picker | **与 `089d35e` 逐字节相同**，且**不含**配额行、配额格式化器、`subscriptionInfo`、`%@ left` 本地化键 |
| 上游可达文件（20 个点名文件） | 零匹配 |
| 全树反向依赖 | **342 个 `.swift` 文件，零匹配**（覆盖上游将来新增的文件，不依赖人工列表） |
| 白空格 / 子模块 | 干净；`.gitmodules` blob 与 Runestone gitlink 均与 `089d35e` 相同 |

### D.2 新增的 `ipad-mac-ui-gate` 检查——它修的是第一阶段的真实漏洞

第一轮把 `ProfilePickerSheet.swift` 列入「已评审的共享修改」并写明理由，
理由是**真的**，但结果是**错的**：`#if os(iOS)` 覆盖 iPad，配额行的插入是无条件的，
**iPad 因此显示了上游 picker 没有的东西**。

> 白名单能说「这个文件是故意改的」。它**不能**说「这个文件给用户看了上游没有的东西」——
> 而后者才是产品要求的属性。

`ipad-mac-ui-gate` 现在同时断言两件事：官方 picker 的 blob 等于上游，**且**不含手机行内容的任何字符串。
负例套件里有一个案例专门做这件事：给官方 picker 加上配额行，它**必须失败**，即使该文件在白名单上。

### D.3 静态证据的边界（不夸大）

**能证明**：iPad/Mac 会加载的每个页面文件不含 Hako 符号，且与上游逐字节相同。
**不能证明**：动态调用（闭包、泛型参数、运行时字符串、selector、反射）；视觉一致性；
Split View / Stage Manager / 窄窗口下的实际布局。后者必须上设备。

---

## E. 品牌与安全

### E.1 品牌

| 项目 | 状态 |
|---|---|
| `CFBundleDisplayName` | `Jiejiebox`，**只**在 `SFI/Info.plist` 与 `SFM/Info.plist` 的 Debug+Release 四处 |
| 其余 8 处 `CFBundleDisplayName` | 有意不改：tvOS、`SFM.System`、两个 ShareExtension、各扩展。分享扩展会出现在分享面板的目的地列表里，改名会多出一个 "Jiejiebox" |
| `PRODUCT_NAME` / `PRODUCT_BUNDLE_IDENTIFIER` / `BASE_PACKAGE_IDENTIFIER` | 与上游**逐次出现次数与取值比对，完全相同**（新增断言） |
| `Variant.applicationName` | `SFI` / `SFM`，未变。它进 VPN profile 的 `localizedDescription`、User-Agent 与 Siri——是协议面不是显示名 |
| URL scheme、UTI 前缀、iCloud 容器名、权限说明文案 | 未动 |

**一处需单独评估的产品决定**（登记，未擅自处理）：系统 VPN 设置里的 profile 名来自
`Variant.applicationName`。若那里仍显示 `SFI`，那是**另一个决定**，不是漏改的显示名。

### E.2 未做的危险操作

未强推、未重写历史、未删/移分支或 tag、未改父仓库 `clients/apple` gitlink、
未切默认分支（仍是 `dev`）、未建 PR/Release/tag、未改签名/entitlement/Bundle ID/App Group、
未触发任何 GitHub Actions（`actions/runs` 计数为 **0**，仓库 workflow 计数为 **0**）。

### E.3 凭据

token 只在那一条 `git push` 的参数里出现过一次，未写入任何持久化位置：
`origin` 的存储 URL 前后相同，`ghp_` 全文搜索零命中。

**提醒（未执行，属账号决策）**：该 PAT 的 scope 含 `delete_repo`、`admin:org`、`workflow`，
即账号下所有仓库的完全控制权，且以明文存放在 `~/.dsh/profiles/desktop/cordis.patch.yml`
所在的配置文件里。建议改用细粒度 PAT，只给本仓库 `Contents: read/write`。

---

## F. 测试与验收证据

### F.1 本机真实运行（末次提交上）

```
python scripts/dev/audit_apple_ui_boundary.py --root <checkout> --upstream-ref 089d35e
    PASS 12  FAIL 0  UNKNOWN 0

python scripts/dev/test_audit_apple_ui_boundary.py --root <checkout>
    16/16 案例按设计行为
```

无 `UNKNOWN`。`hako-page-coverage` 现已**不需要** `--allow-partial`：六个一级页面全部路由到 Hako 页面。
负例套件里仍有一个案例断言「迁移未完成时必须失败」，所以这个计数不会因为完成而失去约束力。

审计 12 项检查：`phone-entry`、`tablet-and-mac-entry`、`shared-pages-are-clean`、
`no-reverse-dependency`、`hako-page-coverage`、`hako-feature-preservation`、`ipad-mac-ui-gate`、
`upstream-files-untouched`、`project-membership`、`branding`、`subscription-feature`、
`repository-hygiene`。

### F.2 负例套件抓到的问题（这是本轮最有价值的证据）

**它抓到了审计自身 8 个缺陷**，其中 5 个是「检查在通过，而被检查的东西已经坏了」：

1. `project-membership` 在未给 `--upstream-ref` 时拿根提交做基线，把整棵树当新增。
2. `subscription-feature` 用字面量 `parse(header:)` 搜索，而声明处的空白从不匹配——它一直在「通过」却从未真正看过。
3. 同一检查验的是符号**被声明**而非**被使用**。
4. `repository-hygiene` 通过 `rev-parse` 读 `.gitmodules`，读的是 HEAD——改子模块指向要到提交后才被发现。
5. 两个与上游比对的检查在**比对根本没发生**时返回 `PASS`。
6. **`subscription-feature` 搜到配额行的名字就通过**——一个「声明了、绑定了、什么都不画」的行也能过。
7. **同一检查只要求某个文件*提到* `HakoProfilePickerSheet`**——而声明它的文件本身就提到了它，
   所以删掉呈现也能过。
8. `upstream-file-edited` 案例硬编码 `LogView.swift`，而该文件后来被加入白名单，案例因此在为错误的理由通过。

**它抓到 2 个测试自身的问题**：一个案例猜错了多行锚点的缩进；一个案例删除了**源仓库的真实 ref**
（worktree 与源仓库共享 refs 目录）——已即时报废并用「PATH 上放一个坏掉的 git」重写，
不再触碰仓库状态。

**它抓到 3 个审计检查的实质缺陷**（第 6、7 条及 `hako-page-coverage` 的解析器），
每一个都已修复并补了对应负例。

### F.3 本机不可能执行的（如实登记）

| 验证 | 状态 | 原因 |
|---|---|---|
| Swift 编译（任何 scheme） | **UNVERIFIED** | 无 Xcode、无 macOS，**且 `Libbox.xcframework` 不在仓库中**（`.gitignore` 排除，需父仓库内核构建产物） |
| `swift test`（两个测试包） | **UNVERIFIED** | 无 Swift 工具链 |
| iPhone / iPad / Mac 真机与模拟器 | **DEFERRED** | 无 Apple 设备 |
| NetworkExtension / Libbox 联调 | **DEFERRED** | 需签名与设备 |
| Actions 是否触发 | **已验证为不触发** | workflow 数 0、webhook 数 0、`actions/runs` 计数 0 |

**本报告没有一处声称编译通过或真机通过。**

---

## G. 技术债务与下一步

### P0

| # | 事项 | 为什么未完成 | 下一次的具体起点 |
|---|---|---|---|
| 1 | **二级页面仍是上游页面** | 六个一级页面已全部完成；二级页面每一个的参照改动都只是一个修饰符或一行，本阶段未做 | 见 §C.3 与迁移矩阵的顺序清单 |
| 2 | **全部 Apple 编译未验证** | 环境不可能 | Mac + `Libbox.xcframework`（含 macOS slice）。四条构建命令见验收清单 §1 |
| 3 | Logs 的四处空状态与日志表面卡片 | 私有成员，不可从外部触及 | 若要完成，需在 `LogView.swift` 上再打开一处可见性（登记理由）或把 `LogContentInnerView` 的参数化拆出来 |
| 4 | 截图夹具中伪造的群组数据 | 参考实现把它删掉了（「客户端的群组应当像其他页面一样来自 client」），但那是独立的行为变更，未混入页面移植 | `GroupListViewModel.connect()` 的 `if Variant.screenshotMode` 分支 |

### P1

| # | 事项 | 状态 |
|---|---|---|
| 1 | libbox `StringBox` 调用点 | **BLOCKED** —— 无框架，无证据可依。判定方法见审计 §5.1 |
| 2 | 屏幕状态修复未运行验证 | 33 个纯逻辑用例已写；运行时行为需真机 |
| 3 | 热点场景（锁屏后转发） | 属内核仓库的问题；本报告只提供客户端侧证据 |
| 4 | `docs/pending/` 中的资产会随上游演进腐化 | 它们引用 `c1935cf` 时期的组件签名 |
| 5 | VPN profile 显示名是否改为 `Jiejiebox` | 产品决定，未擅自处理 |

### P2

| # | 事项 |
|---|---|
| 1 | `HakoPrimaryChildArmer` 的断言仍只在 fork 的 harness 里（需要构建 macOS framework）。应改写成 `swift test` 目标，那就能在任何有 Swift 的地方跑 |
| 2 | 两个 UI 测试包（`HakoNavigationUITests`、`HakoSnapshotUITests`）在页面本体迁移完成后与页面同一次提交落地 |
| 3 | 第一轮登记的通用 bugfix（`FormItem` 无障碍字号换行、`FormNavigationLink` tint、WiFi 提示里的 `SFM`、`NavigationSheetContent` 标题不符）仍未移植 |

### G.1 只能在 Mac / 设备上闭合的

编译（四条 scheme）、`swift test`（两个包）、libbox API 判定、
iPhone 全部视觉与生命周期、**iPad 在每一种窗口环境下必须保持官方呈现**、
Mac 官方界面、跨设备数据兼容。逐条可执行清单见
[`docs/APPLE-DEVICE-ACCEPTANCE.md`](APPLE-DEVICE-ACCEPTANCE.md)。

---

## 与第一阶段的关系

第一阶段证明了**可隔离性**，并在论证中犯了一个错（把上游的缺陷归错因）。
本阶段更正了归因、发现了那条论证背后更重要的内核契约事实、把手机的第一个完整 Hako 页面
（Home）和第二个（Logs）真正接上、补上了第一阶段的真实漏洞（配额行出现在 iPad 上）、
并把审计从 9 项扩到 12 项、负例从 14 个扩到 16 个。

**未完成的是产品目标本身**：还有四个页面是上游的。这一点写在首屏、写在迁移矩阵、
写在 `docs/PHASE2-STATUS.md`，也写在审计的 `UNKNOWN` 里。
