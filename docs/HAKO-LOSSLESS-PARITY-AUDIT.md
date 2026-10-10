# Hako 原版 UI 无损保全审计

> **本文件回答一个问题：手机上的界面还是不是 `hako-ui@c1935cf` 定义的那个界面？**
>
> 它**不**回答"看起来是否一样"。静态证据的强度上限是 `STATIC_PARITY_EVIDENCE`；
> `PIXEL_PARITY_PASS` 与 `DEVICE_PASS` 需要真实设备截图，本文件从不使用这两个词作为结论。

| 项目 | 值 |
|---|---|
| 原版 iPhone UI 真值 | `hako-ui` @ `c1935cff77246f97498400f5a0a7f430cfabbd55`（**commit，不是分支**） |
| 首次发现问题的集成版本 | `e8e197a` |
| 本文件对应的集成版本 | `bb23b0c` 起 |
| 官方 UI pin | `upstream/dev` @ `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` |
| 工具 | `scripts/dev/audit_hako_lossless_parity.py` |
| 原版 UI 测试 | `SFIUITests/HakoNavigationUITests.swift`（18 例）、`HakoSnapshotUITests.swift`（28 例）——已恢复，逐字节相同 |
| 当前结论 | 六个一级页面 **0 个 UI token 丢失**；原版共享组件 **10 个逐字节相同**；二级页面 **未保全**（见 §5） |

---

## 1. 审计方法与它的边界

工具对每个页面做三件事：

1. 从固定 commit 读出原版文件，把它顶层的 `#if` 条件**按 iOS 解析**（`scripts/dev/swift_directives.py`）。
   构建配置类条件（`#if JAILBREAK`、`#if DEBUG`）**原样保留**，因为它们选的是构建而不是平台，
   手机两种构建都会编；把它解析成任一值都会凭猜测增删一行可见 UI。
2. 施加**声明过的**改名表（每个页面的表列在工具里），然后抽取 UI 承载 token。
3. 与原版逐集合比对。原版有、当前没有 = `MISSING_OR_DIFFERENT`，是失败。

抽取的 token 类别：本地化字符串（`String(localized:)`）、字面文案（`Text`/`Label`）、
`systemImage`、`HakoEmptyState` 的 symbol/title/message、`accessibilityIdentifier`、
navigation title 与 `hakoNavigationChrome(title:)`、全部 `Hako*` 组件名、`HakoTheme.*` 与
`HakoProductPalette.*` 设计 token。

**它证明不了什么**：两个渲染是否相同、间距是否一致、动画与手感、动态字号下的换行、
深浅色下的对比、真机截图。这些只能上设备。

### 分类口径

| 分类 | 含义 |
|---|---|
| `SOURCE_EQUIVALENT` | 同一段源码，未施加任何改名 |
| `ADAPTED_NO_UI_DELTA` | 只做了改名/作用域调整；token 集合相等，逐项可查 |
| `MISSING_OR_DIFFERENT` | 原版有、当前没有。**必须修**，不许改写成"已评审差异" |
| `UNVERIFIED` | 缺 Apple 环境无法证实；保留原版实现，登记待验 |
| `INTENTIONAL_UI_CHANGE` | **本轮不存在已授权项** |

---

## 2. 一级页面（六个，全部保全）

| 页面 | 原版来源 | 当前可达 | token | 分类 |
|---|---|---|---|---|
| Home | `HakoStyle/HakoHomeView.swift` | `HakoStyle/HakoHomeView.swift` | 28 本地化 / 3 systemImage / 2 可访问性 ID / 14 Hako 组件 | `SOURCE_EQUIVALENT` |
| Proxies | `Groups/GroupListView.swift` (+273/−30) | `HakoStyle/HakoGroupListView.swift` | 6 / 1 / 0 / 18 | `ADAPTED_NO_UI_DELTA` |
| Activity | `Connections/ConnectionListView.swift` (+207/−34) | `HakoStyle/HakoConnectionListView.swift` | 5 / 2 / 0 / 13 | `ADAPTED_NO_UI_DELTA` |
| Logs | `Log/LogView.swift` (+52/−10) | `HakoStyle/HakoLogView.swift` | 1 / 8 / 0 / 12，含 4 个 `HakoEmptyState` | `ADAPTED_NO_UI_DELTA` |
| Tools | `Tools/ToolsView.swift` (+304/−237) | `HakoStyle/HakoToolsView.swift` | 23 / 9 / 5 / 7 | `ADAPTED_NO_UI_DELTA` |
| More | `Setting/SettingView.swift` (+427/−191) | `HakoStyle/HakoSettingView.swift` | 22 / 8 / 2 / 13 | `ADAPTED_NO_UI_DELTA` |

每个页面的改名表就是它全部被允许的差异；表在工具里，逐条可读。

### 2.1 本轮修掉的两处真实丢失

这两处都是**先前的施工造成的回归**，由本审计发现，不是原版问题。

**Logs**（集成版本 `bb23b0c` 之前）：当时是 wrapper 套在上游 `LogViewContent` 外面，只加了导航
chrome。原版的四处 `HakoEmptyState` 与日志表面的 `HakoCardSurface` 是**私有内部视图的私有成员**，
wrapper 够不到，于是它们整批丢失——包括 `text.alignleft` / `ellipsis` /
`antenna.radiowaves.left.and.right` / `bolt.slash` 四个符号与三段文案。
当时把"chrome 做了"当成完成，这是错的：wrapper 无法呈现原版内部结构时，正确做法是**独立保留
原版实现**，而不是继续宣称迁移完成。现改为整页移植（537 行 iOS 解析后），并撤销了为此对上游
`LogView.swift` 做的可见性修改——该文件已回到上游逐字节。

**Home**（集成版本 `bb23b0c` 之前）：丢失 token `'The VPN extension is not installed yet. Install
it to start the tunnel.'`。原版把它放在 `private var condition: String?`，由头部画**一行 `Text`**；
当时改成了 `@ViewBuilder var condition: some View`，里面是 `VStack` + 文案 + 一个自己的 "Install"
按钮，并且文案用了 `Text("…")` 而非 `String(localized:)`（所以也不会被本地化）。
多出来的那个按钮才是设计差异：它把页面动作从设计给它的控件里挪走了。现已恢复原版形状。

### 2.2 为此新增的原版组件副本

Home 头部的动作是
`StartStopButton(showsRuntimeDuration: false, isCompact: true) { await installTunnel() }`。
上游的 `StartStopButton` 在 fork 基线之后的 43 个提交里丢了 `isCompact` 与 `install` 闭包，
所以手机**无法**向上游组件要到原版形态——而它同时是隧道唯一的状态机，iPad 与 Mac 也在用，
不能改。

因此按纠偏令的方案 C 建立手机自己的副本：
`HakoStyle/HakoStartStopButton.swift`（241 行），由 `scripts/dev/port_hako_components.py` 从
`c1935cf` 整份移植。**这是有意的代码重复**：重复是代价，胶囊按钮变成整页宽才是漂移。

---

## 3. 设计系统（逐字节）

原版 `HakoStyle/` 的 11 个文件中，10 个是共享组件，本工程要求与 `c1935cf` **逐字节相同**：

```
HakoCard、HakoData、HakoEmptyState、HakoPrimaryShell、HakoRow、
HakoScaffold、HakoStatus、HakoSurface、HakoTheme、HakoUITrace
```

当前：**10 / 10 逐字节相同**。改动其中任何一个都会同时改变使用它的每个页面，所以它们没有
"适配"的余地。

`HakoStyle/` 里另外 9 个文件的身份必须分清，否则读者会以为它们也是原版的：

| 文件 | 身份 |
|---|---|
| `HakoHomeView.swift` | 原版页面。按 token 对照，**不**逐字节——它的副本合理地引用了 `HakoStartStopButton`，而原版引用的是上游已改动的组件 |
| `HakoGroupListView`、`HakoConnectionListView`、`HakoLogView`、`HakoToolsView`、`HakoSettingView` | 从原版机械移植的页面（生成物） |
| `HakoStartStopButton.swift` | 原版组件的 fork 副本（见 §2.2） |
| `HakoProfilePickerSheet.swift` | 从原版 picker 生成的副本，保留原版配额行 |
| `HakoNavigation.swift` | **本工程新增，原版没有此文件**。它保存手机的页面名，避免改动共享 `NavigationPage` |

---

## 4. 生成器：它们做了什么，以及为什么可以信任

| 脚本 | 输入 | 断言 |
|---|---|---|
| `port_hako_pages.py` | `c1935cf` 的 blob | 引用 SHA 解析为自身 |
| `port_tools_and_more.py` | 同上 | 引用 SHA；`drop_declarations` 每项都必须在共享树里**真的存在**，否则失败 |
| `port_hako_components.py` | 同上 | 同上 |
| `make_hako_profile_picker.py` | 同上（经 `git show`） | 未解析的条件是失败而不是猜测 |
| `port_hako_secondary.py` | 同上 | 同上；**尚未运行，见 §5** |

共同的机械步骤（`scripts/dev/swift_directives.py`）：

* **平台条件按分支整体解析**。删掉 `#if os(macOS)` 这一行会让它的 `#else` 主体悬空——既语法错误，
  又可能悄悄选中错误的分支。解析器先断言整个指令结构（配对、`#elseif`/`#else` 顺序），再决定。
* **构建配置条件原样保留**。
* **无法判定的条件是失败**：`DEBUG`、`targetEnvironment(simulator)`、`arch(arm64)` 都会让脚本停下，
  由人去看，而不是掷硬币。
* **丢弃共享层已拥有的声明**时必须先在共享树里找到同名声明。这条是为了让上游将来的改名**打断脚本**
  而不是悄悄把重复声明再带回来——这正是本轮 P0 的成因。

### 4.1 本轮修掉的 P0

`e8e197a` 的 `HakoStyle/HakoSettingView.swift` 在模块作用域重复声明了 `SettingsPage` 与
`Notification.Name.navigateToSettingsPage`，上游的 `Setting/SettingView.swift` 也声明了它们。
**同一模块内同名声明重复 = 编译错误**，且对**每一个**编译该组合的 Apple 目标成立，不只是手机。
成因是 fork 的 `SettingView.swift` 就是 fork 基线时期的上游同名文件（`upstream/dev` 领先 43 个提交，
上游在这 43 个里加入了该文件），移植时把共享声明一起带了进来。

方向是丢弃 fork 的那份：**上游的枚举是超集**（多一个 `.sponsors`），而通知携带的就是
`SettingsPage`，保留 fork 的副本会让手机观察到一个与通知投递的类型不同的类型。
`settingsNavigationPath` 是第三处，它在 `#if os(macOS)` 里，被平台解析自然移除。

丢弃后有一处 `switch` 变得不完全：`settingsKey` 覆盖了 fork 的六个 case，上游有七个。生成器以
**声明过的 completion** 补上 `.sponsors: "sponsors"`（与上游一致）。**它不新增可见行**——
手机的 destination 列表仍是 fork 的，没有任何东西会构造 `.sponsors` 页面。手机是否要显示
Sponsors 一行由用户另行决定。

---

## 5. 二级页面：**未保全**（本文件最重要的未完成项）

六个一级页面只是入口。**从它们能点开的二级页面、详情页、报告页与专用 sheet 仍然是上游的**，
这是当前与原版最大的差距，必须点名而不是含糊。

工具 `scripts/dev/list_hako_secondary_pages.py` 从真实调用链列出清单：fork 改了
**60** 个 view 文件（六个页面与设计系统之外），其中 **40 个从手机可达**。

| 分组 | 代表 | 参照改动 |
|---|---|---|
| Proxies / Activity 详情 | `ConnectionView`(+283/−57)、`GroupView`(+20/−14)、`GroupItemView`(+11/−6)、`OutboundPickerView`(+8/−14) | `HakoDataRow`、共享行语言 |
| More 目的地 | `CoreView`(+212/−69)、`PacketTunnelView`(+158/−80)、`OnDemandRulesView`(+133/−131)、`ProfileOverrideView`(+74/−37)、`SponsorsView`(+29/−16) | `HakoSettingsScaffold` |
| Tools 目的地 | `PowerReportListView`(+37/−13)、`CrashReportListView`(+30/−10)、`OOMReportListView`(+25/−14)、三份 detail、`NetworkQualityView`(+14/−3)、`STUNTestView`(+1/−1)、`TaildropView`(+1/−1)、`USBIPServerView`(+1/−1)、`Tailscale*` | `HakoReportScaffold`、`.hakoNavigationChrome` |
| 共享 chrome | `ProfileSheetHelpers`(+15/−0，给 8 个 modal 加关闭控件)、`EditorToolbarView`、`TerminalSessionContentView`、`FontPickerView`、`ThemePickerView` | `HakoCloseButton`、`HakoSelectionMark`、按钮样式 |

**40 项每一个都只是一个修饰符或一行**。做成的方法与一级页面相同：复制进 Hako 命名空间并改名，
绝不改共享文件——改共享文件就是 iPad 泄漏，也就是第一阶段对官方 picker 犯过的错。

### 5.1 已经查清、但本轮未执行的两个阻塞点

1. **`ProfileSheetHelpers.swift` 不能简单改名。** 它声明的 `NavigationSheet` 与 `SheetSize` 是
   **共享类型**，被 9 个文件使用；把副本改名会让那 9 处引用指向不存在的类型。要让手机拿到原版的
   关闭控件，必须建立真正独立的 `HakoNavigationSheet` + `HakoSheetSize` 并同步更新手机侧调用点
   ——这是一个需要单独审查的改动，不能混在批量移植里。
   同样的问题存在于 `Tools/ReportShared.swift` 的 `ReportLabel` 与 `ReportFileContentView`。
2. **`port_hako_secondary.py` 已写好但未运行**，重命名表需要先按上面这条修正。
   它当前的配置**故意会在运行时失败**（对共享类型改名会撞上断言），而不是产出一个坏文件。

### 5.2 明确无法用机械方式表达、已登记的四个文件

| 文件 | 原因 |
|---|---|
| `EnvironmentValues.swift` | 不是页面。它声明 `HakoCompactRowsKey` 与 `hakoCompactRows` 环境值，属于手机的环境注入，与 `SFI/HakoPhoneRootView.swift` 的职责重叠，需要先决定是否要上游的环境文件承载它 |
| `Abstract/GlobalChecksModifier.swift` | 共享 modifier，所有平台都经过它。在这里加手机行为会到达 iPad，需要一个比"复制"更窄的挂载点 |
| `Connections/ConnectionListViewModel.swift` | 视图模型而非视图。fork 的两处改动是 `isLoading` 在客户端未连接时清除（**真实的缺陷修复**，应进共享视图模型）与一个截图夹具 |
| `Groups/GroupListViewModel.swift` | `testingItems` 已在前一轮加入共享视图模型，无剩余工作 |

---

### 5.3 原版 UI 测试套件（已恢复）

原版有两个 UI 测试套件，本分支**从未有过**——它们只存在于 fork 的历史里。本轮从一个完整的原版检出
（`_work/refs/up-hako` @ `c1935cf`）逐字节恢复：

| 文件 | 内容 |
|---|---|
| `SFIUITests/HakoNavigationUITests.swift`（588 行，18 例） | tab 顺序稳定、冷启动落在 Home 且无子页、Home→Logs 推入后返回落到 Tools、被弹出的页面不回来、同一子页连点两次只推一次、点当前 tab 不推入、快速切 tab 落在最后一个、Tools 从未打开过时的 Logs 深链、Groups/Connections sheet 开关、每个 root 上根 tab 可达、推入详情隐藏根 tab 且弹出恢复、Proxies 搜索、Activity 搜索、Tunnel 页显示用户标题且不显示原始属性名、每一个可导航行都能打开、任何页面都不出现原始内部 key、每一个可导航行只画一个指示符 |
| `SFIUITests/HakoSnapshotUITests.swift`（706 行，28 例） | 逐页截图：Home、Tools、More、More 滚到底、出站模式缺席与出现、配置读取失败、Home 与代理 sheet 一致、远端 Home、无隧道的 Home、Logs、On-Demand、Tunnel、Core、Profile Override、Client Settings、Network Quality、报告收件箱空态、三份报告的 list 与 detail、Proxies 折叠与展开、Activity、Activity 数据密度、手动编辑器、配置中心、Add Configuration |
| `scripts/dev/check-hako-primary-route.{sh,swift}` | 用已构建的 framework 实际执行 shell 的页面映射与 child-arming 决策。其自身头注释登记为 `BLOCKED_BY_ENVIRONMENT`，阻塞点精确（PLCrashReporter 的 framework module map 只存在于 Xcode 构建布局内） |

`SFIUITests/` 是 `PBXFileSystemSynchronizedRootGroup`，两个测试文件因此自动加入 UI 测试 bundle，
无需改 `project.pbxproj`——这正是它们自己头注释里写明的机制，也是它们早年被放在 `scripts/dev/` 时
的失败原因：那里不属于任何同步组，`build-for-testing` 报成功而类根本不在 bundle 里。

恢复过程中两条审计检查一度报 FAIL，两条都是**正确的观察**而不是缺陷：
`check-hako-primary-route.swift` 是 Swift，所以文件遍历找到了它，既把它当作"Hako 命名空间外却引用
Hako 符号的文件"，又当作"不属于任何同步组的文件"。它是被 shell 脚本对着已构建 framework 编译的
独立工具，所以它引用 Hako 类型、也不在任何 Xcode target 里。审计因此新增
`OUTSIDE_THE_APP`，只登记这一个文件并写明理由——不是给一整个目录开口子。

### 5.3.1 标识符覆盖的第二种测法

两个套件共寻址 **33** 个 `hako.*` 标识符。按字面搜索，其中 13 个不在树里；逐个查清后：

| 类别 | 数量 | 说明 |
|---|---|---|
| **插值生成，实际存在** | 8 | `"hako.tab.\(primary.rawValue)"`（`HakoPrimaryShell`，原版字节）、`"hako.more.\(destination.pageKey)"`（我们生成的 `HakoSettingView`）、`"hako.home.mode.\(mode)"`（Home）。字面搜索看不见，运行时解析正常 |
| **仍在上游文件里** | 5 | `hako.profile.createManually`（`NewProfileMenuView`）与 `hako.report.*`（三份报告 list/detail）——正是 §5 记录的二级页面缺口 |

两条证据是独立的：一条读源码，一条读原版测试自己的寻址清单，两边指向同一批文件。

---

## 6. 未验证的部分（`UNVERIFIED` / `DEFERRED`）

本机为 Windows，**没有** Xcode、macOS、Swift 工具链，且 `Libbox.xcframework` 不在仓库中
（`.gitignore` 排除，需父仓库内核构建产物）。因此：

| 项 | 状态 |
|---|---|
| SFI / SFM Debug+Release 编译 | `UNVERIFIED` |
| `Tests/HakoScreenState`、`Tests/HakoSubscriptionUsage`（`swift test`） | `UNVERIFIED` |
| iPhone / iPad / Mac 真机与模拟器 | `DEFERRED` |
| 视觉一致性、间距、动态字号、深浅色 | `DEFERRED`——**静态审计不能替代** |
| 本轮所有改动是否编译通过 | `UNVERIFIED`。所有"已恢复""无丢失"都是**静态阅读**的结论，不是编译结论 |

设备验收的逐项清单见 [APPLE-HAKO-VISUAL-ACCEPTANCE.md](APPLE-HAKO-VISUAL-ACCEPTANCE.md)。
