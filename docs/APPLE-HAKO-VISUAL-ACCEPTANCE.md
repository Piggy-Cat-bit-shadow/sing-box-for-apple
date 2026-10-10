# iPhone Hako 视觉验收清单（待 Apple 设备）

> 本清单**现在不执行**。它存在的意义是：等 Mac 与 iPhone 具备时，验收按同一套对照做，
> 而不是"看起来挺像就算过"。任何一条通过都需要截图或结构化记录，不接受口头判断。

前置条件：同一台 iPhone、同一 iOS 版本、同一显示比例与语言，动态字号与深浅模式逐项记录，
模拟数据相同。对照双方必须是：

| 侧 | 构建来源 |
|---|---|
| **原版** | `hako-ui` @ `c1935cff77246f97498400f5a0a7f430cfabbd55` |
| **当前** | `jiejiebox/integrated` 的 FINAL_SHA |

两侧用同一份配置（同一个 profile 文件、同一个远端订阅、同一个人造流量状态）。
下面每一行都要产出一张截图，文件名建议 `NN-<页面>-<状态>-<原版|当前>.png`。

---

## 0. 编译门（先于任何视觉对照）

| # | 命令 | 期望 |
|---|---|---|
| 0.1 | SFI scheme, Debug, iOS Simulator | 编译通过 |
| 0.2 | SFI scheme, Release, iOS Simulator | 编译通过 |
| 0.3 | SFM scheme, Debug, macOS | 编译通过 |
| 0.4 | SFM scheme, Release, macOS | 编译通过 |
| 0.5 | `swift test` in `Tests/HakoScreenState` | 通过（33 例） |
| 0.6 | `swift test` in `Tests/HakoSubscriptionUsage` | 通过 |

**0.1–0.6 任何一项失败都必须先修，且不得通过改设计来绕过。**

---

## 1. 共享组件逐字节（静态已证，此处复核渲染）

静态审计已证原版 10 个共享组件与 `c1935cf` 逐字节相同（见
[HAKO-LOSSLESS-PARITY-AUDIT.md](HAKO-LOSSLESS-PARITY-AUDIT.md) §3），所以这一节的对照是
**复核渲染确实来自它们**，而不是复核源码。

| # | 项 | 对照点 |
|---|---|---|
| 1.1 | 卡片圆角、描边、分隔线内缩 | `HakoCard` / `HakoRow` |
| 1.2 | 强调色语义（主操作 / 危险 / 中性） | `HakoTheme` |
| 1.3 | 页脚、分组标题字号与字重 | `HakoScaffold` |
| 1.4 | 空状态图标、标题、说明三段排版 | `HakoEmptyState` |
| 1.5 | 状态行（运行时、连接状态） | `HakoStatus` |
| 1.6 | 深浅色下的对比度 | 全部 |

---

## 2. 一级页面

每个页面拍摄：默认态、空态、加载态、错误态、深色、动态字号 XL。

### 2.1 Home

| # | 项 |
|---|---|
| 2.1.1 | 头部：配置名 `title2.weight(.bold)`、前置图标、状态圆点、`plus.circle.fill` |
| 2.1.2 | 头部动作：`HakoStartStopButton` 胶囊，`isCompact: true`，**不**整页宽；104pt 最小宽 |
| 2.1.3 | 未安装扩展时的条件行：**一行文字**，橙色，无独立按钮 |
| 2.1.4 | 系统代理卡片出现条件与位置 |
| 2.1.5 | 出站模式区（`clashMode` 卡片启用时） |
| 2.1.6 | 快捷行三项分别打开 Proxies / Activity / Logs |
| 2.1.7 | 配置中心 sheet：新建 / 编辑 / 删除 / 排序 / 二维码 / 更新 |
| 2.1.8 | **剩余流量行**：显示、条件隐藏、locale 与字号缩放 |
| 2.1.9 | `Working…` 在连接中 / 断开中显示；未安装时**不**显示 |
| 2.1.10 | 启动错误 alert（`checkStartupError` 路径） |

### 2.2 Proxies

| # | 项 |
|---|---|
| 2.2.1 | 汇总卡与指标 |
| 2.2.2 | 分组展开 / 收起；`allExpanded` 行为 |
| 2.2.3 | 成员行：延迟、选中态、`HakoSelectionMark` |
| 2.2.4 | **单组测速**：组头 spinner + **每一行** spinner（`testingItems`） |
| 2.2.5 | 单节点测速 |
| 2.2.6 | 搜索框与筛选结果 |
| 2.2.7 | 空态与加载态 |

### 2.3 Activity

| # | 项 |
|---|---|
| 2.3.1 | 汇总卡与指标 |
| 2.3.2 | 行内 rule / outbound 列 |
| 2.3.3 | 搜索与状态筛选菜单（`HakoConnectionMenuButton`） |
| 2.3.4 | 关闭全部连接 |
| 2.3.5 | 空态 |

### 2.4 Logs

| # | 项 |
|---|---|
| 2.4.1 | 详情 chrome：圆形返回、内联居中标题、无根 tab bar |
| 2.4.2 | 日志表面：`HakoCardSurface` 的 fill / separator / 圆角 / 内外边距 |
| 2.4.3 | 空状态一：已连接但无日志 → `text.alignleft` + "Empty logs" + 说明 |
| 2.4.4 | 空状态二：已连接未收到日志 → `ellipsis` + "Loading..." + busy |
| 2.4.5 | 空状态三：远端服务器存在 → `antenna.radiowaves.left.and.right` + "Connecting..." |
| 2.4.6 | 空状态四：服务未启动 → `bolt.slash` + "Service not started" + 说明 |
| 2.4.7 | 等级筛选菜单、搜索、暂停、导出 |
| 2.4.8 | 长日志滚动跟随与选中 |

### 2.5 Tools

| # | 项 |
|---|---|
| 2.5.1 | 分组标题、行图标、行说明、可访问性 ID |
| 2.5.2 | 每个工具行点开后到达的页面（见 §3） |

### 2.6 More

| # | 项 |
|---|---|
| 2.6.1 | 分组标题、行图标、行说明、颜色、位置 |
| 2.6.2 | push 进入各设置页再返回，层级正确 |
| 2.6.3 | 远端控制通知桥：从其他 tab 发起的请求在页面出现后被应用 |
| 2.6.4 | **不**应出现 Sponsors 行（本轮不新增可见行） |

---

## 3. 二级页面（**当前未保全，见保全审计 §5**）

以下每一项在设备上都要与原版对照；在静态层面它们**尚未**迁移，因此这一节现在应当**全部记录为差异**，
而不是记成通过。

| 分组 | 页面 | 原版期望 |
|---|---|---|
| Proxies / Activity 详情 | `ConnectionView`、`GroupView`、`GroupItemView`、`OutboundPickerView` | `HakoDataRow` 与共享行语言 |
| More | `CoreView`、`PacketTunnelView`、`OnDemandRulesView`、`ProfileOverrideView`、`SponsorsView`、`FontPickerView`、`GhosttyConfigurationView` | `HakoSettingsScaffold` |
| Tools | 三份报告 list + 三份 detail、`NetworkQualityView`、`STUNTestView`、`TaildropView`、`USBIPServerView`、`TailscaleExitNodePickerView`、`TailscaleSSHPromptView`、`ExportReportView` | `HakoReportScaffold`、`.hakoNavigationChrome` |
| 共享 chrome | 8 个 modal 的关闭控件（`HakoCloseButton`）、`EditorToolbarView`、`TerminalSessionContentView`、`ThemePickerView` | 见保全审计 §5.1 |

---

## 4. 平台边界（每一条都必须 PASS）

| # | 项 | 期望 |
|---|---|---|
| 4.1 | iPad 全屏 | 与上游官方 UI 一致；**无**任何 Hako 呈现 |
| 4.2 | iPad Split View 1/2、1/3 | 同上 |
| 4.3 | iPad Stage Manager | 同上 |
| 4.4 | iPad 上的官方配置 picker | **无**剩余流量行 |
| 4.5 | macOS | 与上游官方 UI 一致；无 Hako |
| 4.6 | 显示名 overlay | 仅 `Jiejiebox`；`Variant.applicationName` 未变 |
| 4.7 | tvOS | 未被破坏（非产品目标） |

---

## 5. 生命周期与状态延续

| # | 项 | 期望 |
|---|---|---|
| 5.1 | tab 切换后返回 | 子页面状态不丢（原版已修） |
| 5.2 | 首启无配置 | 页面正常，动作是安装而非灰按钮 |
| 5.3 | 只改数据不改结构时不整页重载 | 保持 |
| 5.4 | 锁屏 → 解锁 → 回前台 | 界面恢复；暂停轴按内核契约（见 SCREEN-STATE-FACTS.md） |
| 5.5 | 通知 / 深链选页 | 落到正确页面 |
| 5.6 | 截图环境变量 | Snapshot 路由仍有效；accessibilityIdentifier 未改名 |

---

## 6. 记录方式

每一项产出：截图文件、日期、iOS 版本、设备型号、动态字号与深浅色设置。
差异分三类登记：

* **不可避免的上游新增**（例如上游新增的系统权限文案）——记录即可；
* **原版设计差异**——**不得**自行批准，交用户决定；
* **回归**——修，并在此清单留下修复前后的两张截图。

**结论只允许写成 `STATIC_PARITY_EVIDENCE` 或逐项事实；没有截图就不写 `PASS`。**
