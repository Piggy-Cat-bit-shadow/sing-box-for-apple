# Jiejiebox Apple 客户端 — 架构审计报告

> **审计对象**：`jiejiebox/integrated`，基线 `upstream/dev` @ `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85`
> **审计时间**：2026-10-10
> **方法**：本地 Git 对象库实测 + 全树静态扫描（`git grep`、blob SHA 比对、符号清单）
> **不包含**：Swift 编译、真机 / 模拟器运行。这两项在本机不可能执行，见第 9 节。

本报告对每个结论标注 **FACT**（有可复现的命令输出支持）、**INFERENCE**（由事实推断，可能有别的解释）、
**UNKNOWN**（无法在本环境判定）。

---

## 1. 独立复核任务书第 1 节的先验线索

任务书要求「独立复核，不要盲从」。逐条结论如下。

### 1.1 分支关系表 — **FACT，但有两处数字需要更正**

实测 `merge-base` 与 `git rev-list --left-right --count`（相对 `upstream/dev` @ `089d35e`）：

| A | B | merge-base | A 独有 | B 独有 |
|---|---|---|---|---|
| `upstream/dev` | `origin/hako-ui` | `2b1763a` | 53 | **82** |
| `upstream/dev` | `origin/ipad-upstream-ui` | `2b1763a` | 53 | **91** |
| `upstream/dev` | `origin/fix/libbox-stringbox-callsites` | `2b1763a` | 53 | **94** |
| `upstream/dev` | `origin/fix/apple-notify-unknown` | `3bcb8ca` | 29 | 20 |
| `upstream/dev` | `origin/dev` | `3bcb8ca` | 29 | 19 |

**更正一**：任务书把 `hako-ui` / `ipad-upstream-ui` 相对**fork `dev`** 记为 `behind 43`；
相对 **`upstream/dev`** 实测是 `behind 53`。第 1.1 节表格的 82 / 91 / 94 与实测一致，
43 这个数字来源不明。结论不受影响（43 或 53 都不应机械合入），但数字必须改正。

**更正二（实质）**：`--cherry-pick` 复核显示，`upstream/dev` 那 53 个「独有」提交里
**有 18 个的主题在 fork 侧已存在等效实现**，只是 SHA 不同（fork 从更晚的
`upstream/main` 或已 rebase 的分支重建过）：

`efcebc1`↔`ab33c3f`、`c0e575f`↔`0cc2a57`、`f4968f6`↔`4f94415`、`58de956`↔`e98364f`、
`4443bce`↔`0c49b8f`、`0ba5472`↔`b2ecd9e`、`31f54a8`↔`5d129ee`、`9fa67f5`↔`a1e78ca`、
`d8c2282`↔`8d01771`、`2d1da67`↔`9bcd4c6`、`57ee030`↔`dee60c0`、`a2143fc`↔`3131ed6`、
`33294f8`↔`e6e4f08`、`5c59c6d`↔`dc6fe12`、`89eacf7`↔`ea89e88`、`4ffa778`↔`f8ad6d0`、
`60074f6`↔`e3edd71`、`023cb8f`↔`2070ae1`。

所以「ahead/behind」既不是要合入的提交数，也不是缺失的功能数。这直接改变了同步策略：
**不能 cherry-pick，只能按语义挑选**，否则会把 fork 已有的实现再叠一遍。

### 1.2 「已定位的真实架构问题」— 逐条复核

| 任务书判断 | 结论 | 证据 |
|---|---|---|
| `ipad-upstream-ui:SFI/Application.swift` 通过 `SFIUIFamily.current` 做 `.phone`/`.pad` 分流，思路基本正确 | **FACT，成立且已采用** | 该文件 72 行；`SFIUIFamily.resolve(idiom:)` 是纯函数。本轮采纳其思路并收紧规则（见 §3.1） |
| `ipad-upstream-ui` 的 `SFI/MainView.swift` 与上游**字节相同** | **FACT** | `git cat-file -s`：上游 21354，`ipad-upstream-ui` 21354，`hako-ui` 16093 |
| `MacLibrary/MainView.swift` 与上游相同 | **FACT** | blob 大小 8674，三个引用中 `ipad-upstream-ui` 与上游一致 |
| 「这只证明根视图文件恢复，不证明整条页面调用链恢复」 | **FACT，且是本报告最重要的一条** | 同一分支上 `SettingView.swift` 19983 字节（上游 8452）、`ToolsView.swift` 21535（上游 18624）、`DashboardView.swift` 5021（上游 5953）——**仍是 Hako 改写版**。iPad 经 `NavigationPage.contentView` 依旧进入 Hako 呈现 |
| `NavigationPage` 上 iPhone 个性化标题应保存在 Hako 专属层（历史上通过 `page.hakoTitle`） | **FACT，但任务书记错了实现** | `git grep hakoTitle origin/hako-ui` **无匹配**。该分支是把 `NavigationPage.title` 的返回值改成 "Home"/"More"，即污染了全平台词表。`ipad-upstream-ui:SFI/HakoPhoneRootView.swift:104` 调用了 `page.hakoTitle`，而该符号**在该分支任何文件里都不存在**——说明这个 iPad 分支顶端不是可编译状态。本轮据此新建 `HakoNavigation.swift` 承载 `hakoTitle`（见 §3.3） |
| `SettingView` / `ToolsView` 在 iPad 分支仍走 `HakoRootScaffold` | **FACT** | 静态扫描：`hako-ui` 上有 **33 个** Hako 自有文件之外的 `.swift` 引用 Hako 类型 |
| `DashboardView` / `ProfilePickerSheet` 的 UI/导航差异需检查 | **FACT，已检查** | `DashboardView` 由 5953 降到 5021 字节（结构改写）；`ProfilePickerSheet` 被 9 个 fork 提交改过 |
| 旧冻结基线 `fc7f77b` 早于 `c1935cf`，不可用作验收基线 | **FACT，成立** | `git merge-base --is-ancestor fc7f77b origin/hako-ui` 成功；`fc7f77b..origin/hako-ui` 只有 2 个提交（`24bd463` 只加文档，`c1935cf` 就是剩余流量功能） |
| 三份旧 docs 含过时描述 | **FACT** | 已在新文档中标注归档（见 §8） |
| 根 README 与上游几乎相同 | **FACT** | 本轮重写（见 §7） |
| `Libbox.xcframework` 只有 iOS slice，无 macOS slice | **FACT，且比任务书更严重** | 本工作树里 **`Libbox.xcframework` 根本不存在**：`.gitignore:2` 是 `/Libbox.xcframework/`。因此不只 macOS，**任何**平台的编译验证在本机都不可能。任务书说「若仍缺少 macOS slice，明确登记 macOS 编译无法验证」——实际要登记的是「全部 Apple 编译无法验证」 |

### 1.3 「不要采用的错误捷径」— 逐条确认

七条全部成立，本轮逐条遵守。其中第 4 条（不要拷贝整套官方 iPad UI 到 `IPadUpstream/`）在本轮
**由结构而非纪律保证**：没有任何 iPad/Mac 页面被复制，它们就是上游文件本身。

---

## 2. 独立复核任务书 §1.3 的六个问题

### 2.1 哪些结论有真实源码/提交证据，哪些只是推断，哪些已过时？

见 §1.2 表格。补充三条任务书没说、由本轮实测得到的**新事实**：

**FACT-1｜HakoStyle 是自包含的。** 对 11 个文件做符号清单（声明集 ∪ 引用集，去注释去字符串）后，
它们使用的类型只有三类：**自身声明**、**`upstream/dev` 已声明**、**SDK 类型**
（SwiftUI / Foundation / Dispatch / AppKit / UIKit）。
唯一引用的 fork 专有符号是 `ProfilePreview`、`OverviewViewModel`、`ProfilePickerSheet`、
`StartStopButton`、`HTTPProxyCard`、`DashboardCard` —— 而这些在 `upstream/dev` **都存在**，
只是 `HakoHomeView` 用的是被 fork 改过签名的版本。

**FACT-2｜`HakoHomeView.swift` 因此是唯一不能原样取用的 Hako 文件。**
它在 `StartStopButton(showsRuntimeDuration:isCompact:)` 和
`HTTPProxyCard(...)` 上使用了 fork 专有初始化器。已隔离到 `docs/pending/`（见 §6.3）。

**FACT-3｜迁移面比任务书想象的小得多，但分布完全不同。**
按 `git diff --numstat 2b1763a..origin/hako-ui` 分组：

| 分组 | 文件数 | +行 | -行 |
|---|---|---|---|
| i18n / Xcode 工程 | 2 | 12095 | 9105 |
| HakoStyle（fork 自有设计系统） | 11 | 5266 | 0 |
| ApplicationLibrary 共享页面/组件 | 68 | 4812 | 1533 |
| Library/Tests（业务逻辑 + 测试） | 44 | 2279 | 43 |
| docs/scripts | 5 | 1014 | 0 |
| SFI/MacLibrary（平台根） | 3 | 415 | 377 |

即：**Hako 的视觉工作只有 5266 行在它自己的目录里，另有 4812 行散落在 68 个共享文件**。
真正的问题是后者，不是前者。

### 2.2 「把 Hako 共享页面全部拆出」是否真是最小侵入方案？

**是，但不是本轮实际采用的方案。** 两种方案的实测量化：

| 方案 | 改动量 | 长期成本 |
|---|---|---|
| (A) 为 iPhone 复制/重写每个共享页面为 Hako 变体 | 约 68 个文件、约 4800 行需要重写；且 `HakoHomeView` 依赖的 6 个组件签名也要一并复制 | 上游页面可原样更新；代价是 fork 侧多了一份页面实现 |
| (B) 在共享页面里放中性设计系统钩子，由 Hako 根注入 | 改动小得多 | 每个共享页面长期带一个钩子；上游每次改这些文件都可能冲突；且「钩子默认上游」这个不变量无法静态证明 |

**本轮的判断**：采用 **(A) 的结构**，但只迁移有确证价值且能静态验证的部分，
其余明确登记为待办，并在 `SFI/HakoPageContent.swift` 留下唯一的路由缝。

**为什么不做 (B)**：它把 68 个上游文件全部变成「fork 碰过的文件」，
与目标「多数上游拥有的 UI 文件能继续原样更新」直接冲突，
而且它的正确性依赖运行时环境值的注入顺序——**在本机无法编译验证的前提下，
一个无法验证的隐式钩子比一个明确的缺页更危险**。

**这是本轮最重要的判断分歧**：任务书 §4.2 建议「把 Hako 自有导航文本、视觉 tokens、
布局、定制页面通过 Hako 命名空间下的组件组成调用链」——这要求 iPhone 的页面实现
本身是 Hako 文件。本轮做到了调用链的结构（`HakoPhoneRootView` → `HakoPrimaryShell` →
`HakoPageContent`），但 `HakoPageContent` 的每个分支目前仍指向上游页面。
**因此 iPhone 当前拿到的是「Hako 外壳 + 上游页面」，不是完整的 Hako 视觉。**
这一点在 README 和最终报告中都如实写出，不宣称已完成。

### 2.3 哪些现有 Hako 修改实际是通用 bugfix，不应被当作「视觉污染」删除？

逐个审查了 68 个共享文件后，**确认为通用修复、且本轮已采纳或应当采纳**的：

| 修改 | 位置 | 判定依据 |
|---|---|---|
| `notify_get_state` 返回值被忽略；且 `wakeNow()` 被挂在「屏幕亮起」上 | `ScreenStateObserver.swift` | **上游缺陷**，与 UI 无关。**第二阶段更正**：失败读在旧代码里产生的是 `recordScreenState(false)`，不是「解锁」；真正会解除设备暂停的是 `wakeNow()`，而推送通知就会点亮屏幕。完整核验见 [`docs/SCREEN-STATE-FACTS.md`](SCREEN-STATE-FACTS.md) |
| `FormItem` 在无障碍字号下不换行，标题被挤没 | `Abstract/FormItem.swift` | 工程判断：`@Environment(\.dynamicTypeSize)` + `isAccessibilitySize` 分支；与 Hako 无关 |
| `FormNavigationLink` 的默认样式把整行染成强调色 | `Abstract/FormItem.swift` | 缺陷修复（`NavigationLink` 的 tint 作用在 label 之上） |
| WiFi 权限提示里的 `SFM` 是内部目标名 | `Abstract/GlobalChecksModifier.swift` | 文案修复 |
| `NavigationSheetContent` 的表单标题与实际页面不符（"Groups" 内页写 "Proxies"） | `Abstract/NavigationSheetContent.swift` | 一致性修复 |

**INFERENCE**：这几项与 Hako 视觉无关，属于 fork 期间顺手修的通用缺陷。本轮只采纳了
`ScreenStateObserver` 一项（因为它在本机可静态验证且有独立测试价值），其余登记为待办——
**没有把它们当作「视觉污染」删掉，但也没有在本轮仓促移植**。

### 2.4 哪些上游新版功能与 fork 自定义功能存在语义冲突，保留哪边？

| 冲突 | 上游 | fork | 本轮保留 | 理由 |
|---|---|---|---|---|
| `NavigationPage.title` 返回什么 | "Dashboard"/"Tools"/"Settings" | "Home"/"Tools"/"More" | **上游** | 该枚举被 iPad 侧边栏、iPad tab bar、Mac 侧边栏共读；手机的词表搬到 `HakoNavigation.swift` |
| 订阅流量元数据 | 无 | 有（`subscriptionInfo` + 剩余流量行） | **fork** | 产品要求保留；且它是**纯增量**（新增可空列 + 新增文件），不覆盖上游任何语义 |
| 屏幕状态观察者 | 19 行，忽略返回码 | 545 行，把失败建模为不可表示 | **fork** | 上游版本是缺陷：失败读解除设备暂停 |
| libbox `StringBox` 调用点 | `address()` 直返 `String` | `address()!.value` | **未采用（UNKNOWN）** | 见 §5.1：无 `Libbox.xcframework`，无法判定哪一侧匹配当前内核 |
| `HakoPrimaryShell` 的页签结构 | 上游是 4 个 tab（Dashboard/Logs/Tools/Settings） | 3 个（Home/Tools/More），Logs 作为 Tools 的子页 | **fork**（仅手机） | 这是手机呈现的核心；且它**派生自** `NavigationPage` 并写回，不替换导航模型 |

### 2.5 怎样证明 iPad 官方入口**和其所有可达呈现组件**都不误用 Hako 视觉？

本轮的证明分三层，每层的强度不同，如实说明：

**第一层（FACT，强）：全树反向依赖扫描。**
`scripts/dev/audit_apple_ui_boundary.py` 的 `no-reverse-dependency` 检查遍历
**每一个** `.swift` 文件（本轮 353 个），对 66 个 Hako 类型名与 13 个 Hako 成员名做全词匹配，
要求 `ApplicationLibrary/Views/HakoStyle/` 与三个手机根文件之外的文件**一个匹配都没有**。
当前结果：**339 个文件，0 匹配**。

这比「grep 33 个已知文件」强，因为它覆盖上游将来新增的文件。

**第二层（FACT，强）：上游可达页面的显式清单。**
`shared-pages-are-clean` 检查点名 20 个文件（`DashboardView`、`SettingView`、`ToolsView`、
`LogView`、`GroupListView`、`ConnectionListView`、`SidebarView`、`FormItem`、
`ViewModifiers`、`NavigationPage`、`SFI/MainView`、`MacLibrary/MainView` …）逐个验零匹配。

**第三层（FACT，最强的一条）：上游文件本身就是上游的字节。**
`upstream-files-untouched` 检查把工作树里**每个**文件与 `089d35e` 的 blob SHA 比对：
**459 个中 449 个字节相同**，其余 10 个全部在白名单里并各自写明理由。
`SFI/MainView.swift`、`MacLibrary/MainView.swift`、`ApplicationLibrary/Views/SidebarView.swift`、
`Abstract/SidebarLayout.swift`、`NavigationPage.swift`、`SettingView.swift`、`ToolsView.swift`、
`DashboardView.swift` —— **全部字节相同**。

**这三层合起来能证明什么、不能证明什么**：

- **能证明**：iPad/Mac 会加载的每一个页面文件里不含任何 Hako 符号；
  且这些文件与上游逐字节相同，因此行为与上游相同（在「上游行为由其源码决定」这一前提下）。
- **不能证明**：动态调用。通过闭包、泛型参数、运行时字符串拼出的类型名、
  Objective-C selector 或反射到达的 Hako 视图，静态扫描看不见。
- **不能证明**：视觉正确。iPad 在 Split View、Stage Manager、窄窗口下的实际布局，
  以及 `SidebarLayout.isEnabled(horizontalSizeClass)` 的实际取值，必须上设备看。

**因此本报告的主张是**：「iPad 的源码可达面不含 Hako 引用」是 **PASS**；
「iPad 的视觉与上游一致」是 **UNVERIFIED**。两者不能混为一谈。

### 2.6 哪些文件的可见内容属于「产品名」，哪些属于内部身份/协议/签名？

| 类别 | 位置 | 本轮处置 |
|---|---|---|
| **产品名（可见）** | `INFOPLIST_KEY_CFBundleDisplayName`，SFI / SFM 各 Debug+Release | **改为 `Jiejiebox`**（4 处） |
| **组件自己的名字** | 同一 key，`Extension` / `FileProviderExtension` / `IntentsExtension` / `ShareExtension` / `ShareExtension.System` / `SFM.System` / `SFT` / `WidgetExtension` / `TVExtension` | **不动**。tvOS 不在本轮范围；分享扩展会出现在分享面板的目的地列表里，改名会多出一个 "Jiejiebox" |
| **文档类型名** | `SFI/Info.plist` `CFBundleTypeName` = "sing-box Profile"、`UTTypeDescription` | **不动**。这是文件类型描述，不是应用名 |
| **URL scheme / UTI 前缀** | `CFBundleURLSchemes` = `sing-box`、`$(BASE_PACKAGE_IDENTIFIER)` | **不动**。改了会让 `sing-box://` 链接与 `.bpf` 文件关联失效 |
| **iCloud 容器显示名** | `NSUbiquitousContainerName` = "sing-box" | **不动**。属于容器身份，改了会影响已有数据的可见位置 |
| **权限说明文案** | `NSLocation*UsageDescription`、`NSCameraUsageDescription`、`NSLocalNetworkUsageDescription` | **不动**。见下方产品决定 |
| **VPN profile 名 / User-Agent / Siri** | `Variant.applicationName` = `SFI`/`SFM` | **不动**。它是协议面，不是显示名 |
| **Bundle ID / App Group / Keychain group / extension 标识** | `BASE_PACKAGE_IDENTIFIER`、`PRODUCT_BUNDLE_IDENTIFIER`、`APP_GROUP_IDENTIFIER` | **不动** |

**一处需要单独评估的产品决定（已登记，未擅自处理）**：
系统「设置 → 通用 → VPN 与设备管理」里显示的 profile 名来自
`Variant.applicationName`（进 `NETunnelProviderManager.localizedDescription`）。
如果那里仍显示 `SFI` 而不是 `Jiejiebox`，那是**另一个决定**，不是漏改的显示名。
本轮不改，因为改它会同时改 User-Agent、Siri 意图和已有 VPN 配置的身份。

同理，权限说明里的 "sing-box" 是**归属声明**而非品牌声明——
本项目确实是 sing-box 的非官方客户端，把权限说明改成 "Jiejiebox uses the Location permission…"
会丢失这层归属信息。本报告建议保持，但把它列为产品决定而非技术结论。

---

## 3. 目标架构与本轮实现

### 3.1 设备分流规则

```text
UIUserInterfaceIdiom
  .phone              -> .hakoPhone   -> HakoPhoneRootView  (fork 拥有)
  其它一切（.pad/.unspecified/.mac/.tv/.carPlay）
                      -> .upstreamPad -> SFI/MainView       (上游拥有，字节相同)
```

**为什么只有一个正向分支**：把 `.pad`、`.unspecified`、`.tv`、`.carPlay` 都写出来会引入
「在别的平台上不存在的 SDK case」的编译错误，而 `@unknown default` 单独使用对导入枚举不构成穷尽。
一个只授予 fork 呈现的正向分支，同时也是一条静态检查能验证的规则——
`phone-entry` 检查断言源码里存在 `case .phone:` 且**不存在**其它 idiom 的独立分支。

**`.unspecified` 为什么给上游**：`UIDevice.userInterfaceIdiom` 在 idiom 未解析时返回
`.unspecified`（扩展、预览、测试上下文）。在那里猜「手机」会把 Hako 外壳交给一个
**不能确定是手机**的东西；给上游是保守答案，且已写在源码注释里。

**`horizontalSizeClass` 为什么一次都不读**：iPad 在 Split View / Slide Over / Stage Manager /
窄窗口下仍然是 iPad。fork 的共享文件读过它，那正是 iPad 掉进 Hako 的机制。
`phone-entry` 检查断言根文件里不出现 `horizontalSizeClass`。

### 3.2 依赖方向（本轮实际达成）

```text
                    SagerNet upstream/dev  @089d35e
                              |
                              | 集成分支从该固定 SHA 建立（不是从任何 Hako 分支复制）
                              v
                    jiejiebox/integrated
                              |
              +---------------+----------------+
              |                                |
     SFI/Application.swift  SFIUIFamily 分流     MacLibrary/MainView.swift
              |                                |  （上游，字节相同）
      +-------+--------+                       |
      |                |                       |
 HakoPhoneRootView  MainView  (上游，字节相同)   SFM 上游侧边栏与页面
 （fork）            |
      |          ApplicationLibrary/Views/NavigationPage.swift
 HakoPrimaryShell   （上游，字节相同）
 （HakoStyle/）      |
      |          所有共享页面（上游，字节相同）
 HakoPageContent     |
 （SFI/，唯一路由缝） |
                     v
             Library / Libbox（共享业务层，一份）
```

**关键不变量（已静态验证）**：
1. 反向依赖为零：339 个文件里没有一条从上游可达代码指向 Hako 的边。
2. 上游根与全部上游页面与 `089d35e` 逐字节相同。
3. 环境对象在 `SFI/Application.swift` 的 `Group` 上注入一次，两条路由共用。
4. `NavigationPage.contentView` 仍归上游，手机不经它路由。

### 3.3 本轮实际提交

| 提交 | 内容 |
|---|---|
| `f2064a8` | `docs/APPLE-REFACTOR-BASELINES.md`：不可变引用与固定基线 |
| `c13e852` | `ApplicationLibrary/Views/HakoStyle/`：11 个设计系统文件（自包含，与 `c1935cf` 一致） |
| `0297c8e` | `SFIUIFamily` 分流 + `HakoPhoneRootView` + `HakoPageContent` + `HakoNavigation` |
| `2608bd5` | 订阅流量元数据链（4 个新文件 + 迁移 + 取件行） |
| `8cc4005` | `Tests/HakoSubscriptionUsage` 包与两个脚本（符号链接指向真实源码） |
| `7271382` | `CFBundleDisplayName = Jiejiebox`（4 处）+ 静态审计脚本 |
| `61b4c44` | 负例测试套件（14 个案例） |
| `f77289f` | 屏幕状态观察者修复 |
| `042af2b` | 审计强化：未评审的上游改动必须 FAIL；负例套件不再破坏源仓库 |

---

## 4. 三条运行时可达链的审计结果

### 4.1 iPhone 链

```text
SFI/Application.swift:SFIUIFamily.resolve(.phone)
  -> HakoPhoneRootView            (SFI/HakoPhoneRootView.swift)
     -> HakoPrimaryShell           (HakoStyle/HakoPrimaryShell.swift)
        -> HakoPrimaryTab          home / tools / more
        -> HakoPrimaryRoute        页面 -> (primary, child) 的纯映射
        -> HakoPrimaryChildArmer   子页推入状态机（shell 与 harness 共用同一规则）
        -> HakoPageContent         **唯一路由缝**（SFI/HakoPageContent.swift）
           -> 目前每个分支都指向上游页面
```

`selection` 仍是 `NavigationPage`，所有既有入口（通知跳转、深链、截图 harness、
`\.selection` 环境值）语义不变。

**状态**：入口与外壳 **PASS**；Hako 页面本体 **PENDING**（见 §6）。

### 4.2 iPad 链

```text
SFI/Application.swift:SFIUIFamily.resolve(非 .phone)
  -> SFI/MainView.swift            与 upstream/dev 字节相同
     -> SidebarLayout.isEnabled(horizontalSizeClass)
        true  -> NavigationSplitView { SidebarView } detail: { sidebarPageContent }
        true  -> (iOS 18+) TabView(.sidebarAdaptable)
        false -> 紧凑 TabView
     -> page.contentView           上游 NavigationPage 的工厂
        -> DashboardView / GroupListView / ConnectionListView / LogView / ToolsView / SettingView
           （全部与上游字节相同）
```

**状态**：**PASS**（源码层面）。真机视觉 **UNVERIFIED**。

### 4.3 macOS 链

```text
SFM/Application.swift -> MacApplication
  -> MacLibrary/MainView.swift     与 upstream/dev 字节相同
     -> ApplicationLibrary/Views/SidebarView.swift  与上游字节相同
        -> 上游页面，与 iPad 共用同一批文件
```

**状态**：**PASS**（源码层面）。编译与运行 **UNVERIFIED**——本机连 `Libbox.xcframework` 都没有。

---

## 5. 两个 fix 分支的逐项审查

### 5.1 `fix/libbox-stringbox-callsites`（3 个提交）— **判定：UNKNOWN，不采纳**

| 提交 | 内容 | 判定 |
|---|---|---|
| `8599039` | 20 处 libbox 访问器从 `address()` 改为 `address()!.value` | **UNKNOWN** |
| `37043ff` | `BridgeServiceSession.name()` 返回 `LibboxStringBox?` 而非 `String` | **UNKNOWN** |
| `2b23330` | 新增 `ScreenStateObserver.swift`（29 行）+ 在 `ExtensionProvider` 里安装 | **不需要**——上游 `089d35e` 已有 `Library/Network/ScreenStateObserver.swift`，且 `ExtensionProvider.swift:248` 已安装它 |

**第一个判定的证据与理由**：
- 上游 `089d35e` 的 `ExtensionPlatformInterface.swift` 用的是 `address()`（无 `.value`），
  见 `git grep -n "address()" 089d35e -- Library/Network/ExtensionPlatformInterface.swift` 的 8 处。
- 上游能编译（这是它发布的版本），所以上游构建所对的 `Libbox.xcframework`
  里 `address()` 返回可直接拼接的 `String`。
- fork 的版本用 `.value` 解包成 `String?`，说明它对应的是**另一个** libbox 构建。
- 两侧都没有把 `Libbox.xcframework` 纳入版本控制（`.gitignore:2` 是 `/Libbox.xcframework/`），
  所以**没有可读的证据链**判定哪一侧匹配用户父仓库当前的内核。

**结论**：不采纳。这不是「风险太高」，而是**无证据可依**——
按任务书 §2.2「不能靠静态推断安全修复」的边界，登记为 `BLOCKED`。

**给后续的精确行动**：在能拿到 `Libbox.xcframework` 的机器上执行
```bash
xcrun swift-api-digester -dump-sdk -module Libbox -o /tmp/libbox.json -I Libbox.xcframework/...
# 或最直接：在 fork dev 上编译，看 address() 的返回类型
```
判定 `LibboxRoutePrefix.address()` 的返回类型后，本项即可闭合。

### 5.2 `fix/apple-notify-unknown`（1 个提交）— **判定：采纳**

> **本节在第二阶段被更正。** 初稿把上游的行为写成
> 「读失败 → `recordLockState(false)` → `lifecycle.woke()`」。**上游从不调用 `recordLockState`。**
> 更正后的完整事实核验见
> [`docs/SCREEN-STATE-FACTS.md`](SCREEN-STATE-FACTS.md)。要点：

上游 `089d35e` 的 `Library/Network/ScreenStateObserver.swift` 实测为 19 行，其回调是：

```swift
var state: UInt64 = 0
notify_get_state(token, &state)          // 返回码被丢弃
commandServer.recordScreenState(state == 1)
if state == 1 {
    commandServer.wakeNow()
}
```

**没有 `recordLockState` 调用**，也**没有注册 `com.apple.springboard.lockstate`**。

缺陷因此不是「失败被当作解锁」，而是两点：

1. **`wakeNow()` 被挂在「屏幕亮起」上。** 上游内核里 `WakeNow()` 是
   `instance.PauseManager().DeviceWake()`——**唯一真正解除设备暂停的调用**。而在 iOS 上
   推送通知就会点亮锁屏，所以上游客户端把「锁屏被点亮」当成了「设备可用」，
   这正是其父仓库 `box_lifecycle.go` 明文要避免的 wake storm。
2. `notify_get_state` 的返回码被丢弃，失败读与「读到 0」不可区分——屏幕事实因此也可能误报。

**第二阶段的更正还涉及一个更重要的发现**：本 fork 的目标内核
（父仓库 `Piggy-Cat-bit-shadow/sing-box`，`clients/apple` 指向它）**已经移除了那条
`WakeNow` 路径**，改为要求客户端上报**锁屏轴**：

| 内核 API | 上游 `SagerNet/sing-box` | 父仓库 `Piggy-Cat-bit-shadow/sing-box` |
|---|---|---|
| `RecordScreenState(on:)` | 只写 power report，**不碰暂停轴** | `Box.ScreenStateChanged(on)`；on = 仅 resume **EDGE** |
| `RecordLockState(locked:)` | **不存在** | `Box.LockStateChanged(locked)`；**unlocked 是唯一解除 LEVEL 的事实** |
| `WakeNow()` | `PauseManager().DeviceWake()`，客户端在屏幕亮起时调用 | 仍存在，但语义收窄为「平台已另行确认的唤醒」 |

即：**客户端的 `RecordLockState` 上报不是 fork 的发明，而是其内核已经设计好、并明文等待的
客户端另一半。** 父仓库 `box_lifecycle.go` 第 40–52 行写着：

> Before this file, the Apple level had no lift at all … and the shipped client never called the one
> method that did. … A platform that reports no such fact keeps the latch, and that is stated as a
> limitation rather than papered over with a guess: see the client patch in
> `docs/fork/apple-screen-state-observer.md`.

**本轮处置**：完整事实核验见 [`docs/SCREEN-STATE-FACTS.md`](SCREEN-STATE-FACTS.md)；
实现未改（它已与内核契约一致），但补了 33 个纯逻辑故障注入测试
（`Tests/HakoScreenState`，见 §7.4）。

**未验证**：两个通知名是否会投递给沙盒化的 NetworkExtension，只能由设备证据回答。
`ScreenStateStartResult` 会把失败的通知名带出来，正是为了让那一条日志成为证据。

---

## 6. Hako 功能保全清单

任务书 §4.3 要求逐项标注 `PRESERVED / PORTED / BLOCKED_UNVERIFIED`。
**重要**：本清单的判定标准是「源码链可达」，不是「设备上看见了」。

| # | 功能 | 状态 | 证据 |
|---|---|---|---|
| 1 | 订阅流量元数据解析（`subscription-userinfo`） | **PORTED** | `Library/Network/SubscriptionInfo.swift:44` `parse(header:)`；未知键忽略、缺失键默认 0、无键值对返回 nil |
| 2 | 已用/剩余/占比算术，含溢出钳制 | **PORTED** | `usedBytes` 用 `addingReportingOverflow`；`remainingBytes` 在 `total == 0` 时返回 `nil`（不是 0） |
| 3 | 元数据持久化（DB 迁移） | **PORTED** | `Database.swift` 新增 `add_subscription_info`，四个**可空**列，一起写或不写 |
| 4 | 元数据随刷新更新，且不因正文未变而丢失 | **PORTED** | `RemoteProfileRefresh.evaluate` 的求值顺序；`RemoteRefreshApplier.apply` 保证 `persist` 总是先跑 |
| 5 | 仅元数据变化不触发服务重载 | **PORTED** | `RemoteRefreshOutcome.reloadService` 只在正文变化时为 true |
| 6 | 远程 URL 变更时清除旧面板的元数据 | **PORTED** | `Profile.normalizeRemoteSourceChange`，由 `ProfileManager.update` 从数据库行比较后调用 |
| 7 | 配置行显示剩余流量（`c1935cf` 的核心） | **PORTED** | `ProfilePickerSheet.swift` 的 `remainingTrafficInfo` + `Int64.remainingTrafficText` + 目录键 `"%@ left"` |
| 8 | 余量格式化（十进制单位、≥10 无小数、<10 一位） | **PORTED** | 同上，含 `9.95 GB` 读作 `10 GB` 的舍入 |
| 9 | 英文行宽自适应（`lineLimit(1)` + `minimumScaleFactor(0.8)`） | **PORTED** | `c1935cf` 的两个布局属性 |
| 10 | 中文保留完整相对时间（"6天前"） | **PORTED** | `Date.relativeFormat(forPickerRow:)` 对 `zh` 前缀回退到 `relativeFormat` |
| 11 | 面板未报总额时不显示该行 | **PORTED** | `if let remainingBytes = profile.subscriptionInfo?.remainingBytes` — nil 即不渲染 |
| 12 | Hako 三页签外壳（Home / Tools / More） | **PORTED** | `HakoPrimaryShell` + `HakoPrimaryTab`；`HakoPrimaryChildArmer` 的推入规则带 14 个 harness 断言 |
| 13 | 手机页面命名（Home / Proxies / Activity / More） | **PORTED，且搬到独立文件** | `HakoNavigation.swift` 的 `hakoTitle`；不再改 `NavigationPage.title` |
| 14 | Hako 设计系统（tokens、卡片、行、脚手架、状态、数据组件） | **PORTED** | `HakoStyle/` 11 个文件，与 `c1935cf` 一致（`HakoPrimaryShell.swift` 除外，见 §6.1） |
| 15 | Hako 的 Home 页（`HakoHomeView`） | **BLOCKED_UNVERIFIED** | 见 §6.3 |
| 16 | 共享页面（设置、工具、仪表板、连接、代理组、日志、配置编辑）的 Hako 视觉 | **BLOCKED_UNVERIFIED** | 上游版本就在设备上跑；Hako 版本尚未迁移。`HakoPageContent` 每个分支都写明这是待迁移项 |
| 17 | UI 测试（`HakoNavigationUITests` / `HakoSnapshotUITests`） | **NOT PORTED** | 它们断言的是 Hako 页面本体与固定的可访问性标识；在页面本体未迁移前移植会得到一套必然失败的测试。已保留在 `docs/pending/` 供后续取用 |
| 18 | 手机首个一级页的 Hako 卡片网格布局 | **BLOCKED_UNVERIFIED** | `HakoHomeView` 所属；当前用上游 `OverviewView` 的卡片网格 |
| 19 | 截图 harness 的 `SCREENSHOT_PAGE` 支持 | **PARTIAL** | `HakoPhoneRootView` 读该环境变量选 `NavigationPage`；`HakoHomeView` 的扩展案例（proxies/activity/settings 子页）未迁移 |
| 20 | 设备分流本身 | **PORTED** | `SFIUIFamily.resolve(idiom:)`，`phone-entry` 检查覆盖 |

### 6.1 `HakoPrimaryShell.swift` 与 `c1935cf` 的差异

本轮取用的 `HakoPrimaryShell.swift` 与 `c1935cf` 的版本**有一个可察觉差异**：
`hako-ui` 分支的 `NavigationPage.hakoPrimary` 用 `#if os(macOS)` 处理 `groups`/`connections`；
本轮取用的版本（来自 `ipad-upstream-ui` 线的 HakoStyle）覆盖同样的映射。
两者都只被手机路径使用，语义一致。**FACT**：审计的 `no-reverse-dependency`
确认这个文件不在任何上游可达路径上。

### 6.2 关于旧冻结基线与新基线

任务书要求「重新定义有审计记录的最新保护基线，保留旧 tag 且禁止暗改期待值」。
本轮的处理：

- **保留** `iphone-hako-ui-freeze-v1`（指向 `fc7f77b`）**不动**。
- **不新建 tag**——任务书 §2.1.8 禁止本次施工打正式 tag。
- 新的保护基线是**内容基线**而非 tag：审计脚本的
  `no-reverse-dependency` + `shared-pages-are-clean` + `upstream-files-untouched`
  三项一起，比按 blob 冻结更严格（它冻结的是**边界**而非字节，
  因此上游更新这些文件时不会误报，而 fork 侧越界会立即失败）。
- 旧冻结脚本 `scripts/dev/check-iphone-hako-freeze.sh` **未移植**：
  它的期待值锚定在 `fc7f77b`，而该提交**早于**本轮保留的 `c1935cf` 功能，
  用它做验收会要求回滚剩余流量显示。这一判断与任务书 §1.2 的警告一致。

### 6.3 待迁移项的确切位置

`HakoHomeView.swift` 与两个 UI 测试文件、四个旧脚本已放在
**`docs/pending/`**（不是被删除，也不是被忽略目录），每个文件带一份
`docs/pending/README.md` 说明它为什么不能原样取用。

**这是一个明确的缺口，不是「已完成」**。它影响的是手机的**首屏外观**，
不影响任何功能的可达性。

---

## 7. 本机能做的验证，以及真实结果

### 7.1 静态审计（真实运行）

```bash
python scripts/dev/audit_apple_ui_boundary.py --upstream-ref 089d35e
```

结果：**PASS 9 / FAIL 0 / UNKNOWN 0**。

```bash
python scripts/dev/test_audit_apple_ui_boundary.py
```

结果：**14 个案例全部按设计行为**（1 个正例 + 13 个负例/不变量）。

### 7.2 负例套件发现的 5 个审计自身缺陷（已修）

这是本轮最有价值的一段证据：**一个不能失败的守卫不是守卫**。

1. `project-membership` 在未给 `--upstream-ref` 时拿根提交做基线，把整棵树当新增，
   于是上游自己有意排除的 Xcode membership 被报成 fork 的错误。
2. `subscription-feature` 用字面量 `parse(header:)` 搜索，而声明处的空白从不匹配——
   这个检查一直在「通过」，却从未真正看过。
3. 同一个检查验的是符号**被声明**而非**被使用**，所以重命名辅助函数、
   或把行从选择器上摘掉，都能通过。
4. `repository-hygiene` 通过 `rev-parse` 读 `.gitmodules`，而它读的是 HEAD——
   改子模块指向要到提交后才被发现。
5. 两个与上游比对的检查在**比对根本没发生**时返回 `PASS`。

这五条都已修复，且每一条都补了对应的负例。

### 7.3 本机不可能执行的验证（如实登记）

| 验证 | 状态 | 原因 |
|---|---|---|
| Swift 编译（任何 scheme） | **UNVERIFIED** | 本机无 Xcode、无 macOS、**且 `Libbox.xcframework` 不存在**（`.gitignore` 排除，需从父仓库内核构建产物取得） |
| Xcode 工程可解析 | **PARTIAL** | 只做了字节级结构检查（花括号平衡、configuration id ↔ INFOPLIST_FILE 锚定），未用 `xcodebuild -list` |
| iPhone 模拟器 / 真机 | **DEFERRED** | 无 Apple 环境 |
| iPad 模拟器 / 真机 | **DEFERRED** | 同上 |
| Mac 运行 | **DEFERRED** | 同上 |
| `swift test`（订阅流量测试包） | **UNVERIFIED** | 无 Swift 工具链。命令见 `docs/APPLE-DEVICE-ACCEPTANCE.md` |
| NetworkExtension / Libbox 联调 | **DEFERRED** | 需签名与设备 |

**明确声明**：本报告没有任何一处声称编译通过或真机通过。

---

## 8. 旧文档的处置

| 文件 | 处置 |
|---|---|
| `docs/HAKO-OWNERSHIP.md`（fork 加入，616 行） | **未移植**。它是 `hako-ui` 分支对当时工作树的快照，描述的 u 是与本分支不同的文件集合。已归档到 `docs/pending/HAKO-OWNERSHIP.md` 并在 `docs/pending/README.md` 里说明「不可当作现行架构指令」。**本轮的架构指令是根 README 与 `docs/APPLE-UI-ROUTING.md`** |
| `docs/APPLE-UI-ROUTING.md`（任务书提及） | 在 `hako-ui` 上**不存在**（`git grep` 无匹配）。本轮的对应物是审计脚本与 README 的 Platform UI Ownership 一节 |
| `docs/IPAD-UPSTREAM-PORT.md`（任务书提及） | 同样不存在于任何 fork 分支 |
| `docs/APPLE-ARCHITECTURE-AUDIT.md` | **本文件**，本轮新建 |
| `docs/APPLE-REFACTOR-BASELINES.md` | 本轮新建 |
| `docs/UPSTREAM-SYNC-PLAYBOOK.md` | 本轮新建 |
| `docs/APPLE-DEVICE-ACCEPTANCE.md` | 本轮新建 |
| `docs/APPLE-REFACTOR-FINAL-REPORT.md` | 本轮新建 |

**FACT**：任务书 §1.2 提到的 `docs/IPAD-UPSTREAM-PORT.md` 与 §6.1 提到的
`docs/APPLE-UI-ROUTING.md` 在 `origin/hako-ui`、`origin/ipad-upstream-ui`、
`origin/fix/libbox-stringbox-callsites` 三个分支上都不存在。任务书把它们当作既有文件，
这一点需要更正。

---

## 9. 遗留风险与盲区（点名，不掩盖）

### P0 — 会影响结果是否符合需求

| # | 风险 | 当前状态 |
|---|---|---|
| 1 | **iPhone 的 Hako 页面本体未迁移** | 已知缺口。手机拿到 Hako 外壳 + 上游页面。功能不减，视觉未达 Hako 目标。见 §6.3 |
| 2 | **全部 Apple 编译未验证** | 本机不可能。`Libbox.xcframework` 缺失使这一点比任务书预期的更严重 |
| 3 | 静态扫描看不见动态调用 | 通过闭包/泛型/运行时字符串/selector 到达的 Hako 视图不会被发现。已在审计文件头与 §2.5 点名 |
| 4 | iPad 视觉一致性 | 源码字节级相同是强证据，但不等于视觉一致。`SidebarLayout.isEnabled` 的实际取值需上设备 |

### P1 — 长期同步或业务风险

| # | 风险 | 当前状态 |
|---|---|---|
| 1 | libbox `StringBox` 调用点无证据 | 见 §5.1。父仓库内核更新后可能编译失败 |
| 2 | `Localizable.xcstrings` | 本轮只加 1 个键。若将来迁移 Hako 页面本体，会引入大量键；**不要**整文件替换（fork 版本与上游差异 12095/9105 行） |
| 3 | 屏幕状态修复未运行验证 | 静态不变量已断言，运行时行为未知 |
| 4 | `docs/pending/` 中的资产会腐化 | 它们引用的是 `c1935cf` 时期的 `HakoHomeView`；上游页面继续演进后，这些引用的组件签名会进一步偏离 |

### 已确认不存在的问题

- 没有复制两份官方 UI：iPad/Mac 页面就是上游文件，`upstream-files-untouched` 逐字节证明。
- 没有反向依赖：`no-reverse-dependency` 覆盖全部 353 个 Swift 文件。
- 没有品牌外溢：`branding` 检查断言 `PRODUCT_NAME`、`PRODUCT_BUNDLE_IDENTIFIER`、
  `BASE_PACKAGE_IDENTIFIER` 不含产品名，且 `Variant.applicationName` 未变。
- 没有子模块漂移：`.gitmodules` blob 与 Runestone gitlink 都与 `089d35e` 相同。
- 没有碰旧分支、旧 tag、父仓库 gitlink、默认分支。
