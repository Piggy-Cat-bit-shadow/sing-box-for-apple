# Jiejiebox — Apple 客户端

SagerNet 官方 [sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple) 的 **fork**，
面向 iPhone 的 Hako 界面分支。**这是非官方客户端**，与 SagerNet 无隶属关系；
内核来自 [jiejiebox 的 sing-box 分支](https://github.com/Piggy-Cat-bit-shadow/sing-box)。

本 README 是**本项目架构的权威说明**。它是给人和 AI 协作者读的：
读完这一页就能知道哪段代码归谁、新功能该写在哪里、哪些东西绝对不能碰。

> **集成分支**：`jiejiebox/integrated`，从 `upstream/dev` @ `089d35e` 建立，已推送到 origin。
> GitHub 上的**默认分支目前仍是 `dev`**，尚未切换。分支清单见
> [`docs/APPLE-REFACTOR-BASELINES.md`](docs/APPLE-REFACTOR-BASELINES.md)。

---

## Platform UI Ownership — 三个平台，三种所有权

| 设备 / 平台 | 界面归属 | 允许的自定义 | 长期策略 |
|---|---|---|---|
| **iPhone / iOS** | **本 fork 的 Hako 界面** | Hako 视觉、导航、配置与订阅相关自有功能 | 独立迭代；共享能力从上游获得 |
| **iPad / iPadOS** | **SagerNet 官方界面** | 仅最小且安全的可见产品名 | 正常吸收上游 UI、页面与行为更新 |
| **Mac / macOS** | **SagerNet 官方界面** | 仅最小且安全的可见产品名 | 同上 |
| 共享业务层 | 上游优先 | 少量经证据证明必要的扩展 | 一份数据 / 网络 / 生命周期 / 配置逻辑 |
| **tvOS** | 不在本项目定制目标 | 不主动修改 | 仅记录共享改动的影响 |

**决定界面归属的是设备类型（`UIUserInterfaceIdiom`），不是尺寸类别。**
iPad 在 Split View、Slide Over、Stage Manager 或窄窗口下**仍然是 iPad**，
仍然是官方界面。窄窗口只影响官方界面**内部**的自适应布局
（上游的 `SidebarLayout.isEnabled(horizontalSizeClass)`）。

这条规则由静态审计强制，不是靠自觉：

```bash
python scripts/dev/audit_apple_ui_boundary.py --upstream-ref 089d35e
```

---

## 产品所有权铁律（最高准则）

> **iPhone 界面设计来源：`hako-ui@c1935cf`。任何人不得擅自改变它——不改视觉、不改信息架构、不改交互、不改文案、不"顺手优化"。iPad 与 macOS 保持上游官方 UI。这两条同等必须满足。**

这是给后续 AI 与协作者的第一条约束，优先于任何"让代码更整洁""让视觉更现代"的施工提示。

| | |
|---|---|
| **iPhone UI 真值来源** | `hako-ui` @ `c1935cff77246f97498400f5a0a7f430cfabbd55`。已完成的界面就是它，不需要重新设计 |
| **iPad / macOS UI 真值来源** | `upstream/dev` @ `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85`（本 fork 的已审计 pin） |
| **两者冲突时** | 技术方案让步。宁可更严格的隔离、局部重复代码、专用适配器，也不牺牲原版设计 |
| **没有 Apple 编译条件时** | 如实标 `UNVERIFIED`，保留原版实现等待真机验证。**不是**重新发明界面的许可 |

### 谁是谁：原版设计 与 本工程的适配层

```text
hako-ui@c1935cf（原版 iPhone UI，唯一设计真值）
        │
        │  机械移植：scripts/dev/port_*.py
        │    · 平台条件解析为 iOS
        │    · 文件级类型改名进 Hako 命名空间
        │    · 丢弃共享层已拥有的声明（每项都有断言，找不到就失败）
        ▼
ApplicationLibrary/Views/HakoStyle/（手机 UI 的全部所有权边界）
        │
        │  唯一的可达性入口
        ▼
SFI/HakoPageContent.swift ──→ SFI/HakoPhoneRootView.swift
        │
        │  SFIUIFamily.resolve(idiom:) 只对 .phone 返回 Hako
        ▼
    iPhone 看到 Hako；.pad 与 macOS 看到上游官方 UI
```

**生成器是迁移工具，不是设计权威。** 它们只做机械改名与条件解析；任何无法机械表达的转换都必须失败并列出，不许猜。原版源码以固定 commit 读取，生成物由 `--check` 只读校验，`--regenerate` 必须显式指定——并且**只对已授权的目标生效**：目标已存在且与重新生成的候选不同时，`--regenerate` 会拒绝并列出每个目标的 `--replace=<path> --expect-sha256=<hex>`（一次授权只覆盖一个文件、一个 blob）。原因是候选是上游文本的新函数，而磁盘上的文件是"上一次生成 + 此后每一次人工修复"的产物：无条件覆盖会把修好的平台守卫和改过名的调用点按上游写法写回去，退出码却是 0，而 token 集合不变，所以无损审计不会发现。

### 三个不能靠"看起来差不多"判断的判据

| 判据 | 工具 | 当前 |
|---|---|---|
| **一级页面路由** | `audit_apple_ui_boundary.py --only hako-page-coverage`，读取 `HakoPageContent` 的 switch | 6 / 6 |
| **原版 UI 保全** | `audit_hako_lossless_parity.py`，把每个页面的 UI token（本地化字符串、`systemImage`、空状态符号与文案、可访问性 ID、Hako 组件、设计 token）与原版逐集合比对 | 6 个页面 0 token 丢失；设计系统 10 个文件逐字节相同 |
| **平台隔离** | 同一边界审计的 `phone-entry`、`ipad-mac-ui-gate`、`no-reverse-dependency`、`shared-declaration-duplicates` | PASS |

保全审计**只能**给出 `STATIC_PARITY_EVIDENCE`，且**永不输出** `PIXEL_PARITY_PASS` 或 `DEVICE_PASS`——那需要真实设备截图。逐项状态见 [docs/HAKO-LOSSLESS-PARITY-AUDIT.md](docs/HAKO-LOSSLESS-PARITY-AUDIT.md)，设备验收清单见 [docs/APPLE-HAKO-VISUAL-ACCEPTANCE.md](docs/APPLE-HAKO-VISUAL-ACCEPTANCE.md)。

## Architecture / Data Flow

```text
                     SagerNet upstream/dev  @ 089d35e
                                |
                                |  集成分支从该固定 SHA 建立
                                v
                     jiejiebox/integrated
                                |
        +-----------------------+-----------------------+
        |                                               |
  SFI/Application.swift                        MacLibrary/MainView.swift
  SFIUIFamily.resolve(idiom:)                  （上游文件，字节相同）
        |                                               |
   +----+---------------------+                         |
   |                          |                         |
   | .phone                   | 其它一切 idiom           |
   v                          v                         v
SFI/HakoPhoneRootView    SFI/MainView.swift      Mac 侧边栏与页面
（fork）                  （上游，字节相同）        （上游，字节相同）
   |                          |
   |  HakoPrimaryShell        |  NavigationPage.contentView
   |  （HakoStyle/）           |  （上游工厂，未改）
   |                          |
   |  HakoPageContent          |
   |  （SFI/，唯一路由缝）      |
   |                          |
   +-------------+------------+
                 |
                 v
   ApplicationLibrary / Views / Library / Libbox
   （共享业务层，一份：ExtensionEnvironments、CommandClient、
     ExtensionProfile、ProfileManager、报告管理器 …）

   可见应用名 overlay = "Jiejiebox"
   （不改 Bundle ID、App Group、签名、URL scheme、协议属性）
```

**四个不变量，全部由审计脚本验证：**

1. **反向依赖为零** — `ApplicationLibrary/Views/*` 中任何一个上游可达文件里
   **不得出现任何 Hako 类型名或 Hako 成员名**。当前：0 处匹配（由审计脚本实测，不写死计数）。
2. **上游根是上游的字节** — `SFI/MainView.swift`、`MacLibrary/MainView.swift`、
   `ApplicationLibrary/Views/SidebarView.swift`、`Abstract/SidebarLayout.swift`、
   `NavigationPage.swift` 与 `089d35e` **逐字节相同**。
3. **环境对象注入一次** — 在 `SFI/Application.swift` 的 `Group` 上，
   两条路由共用同一批模型对象。呈现不同，状态不分叉。
4. **品牌不外溢** — `PRODUCT_NAME`、`PRODUCT_BUNDLE_IDENTIFIER`、
   `BASE_PACKAGE_IDENTIFIER`、`Variant.applicationName`、App Group、Keychain group
   都不含产品名。

---

## Repository Layout

```text
SFI/                          iPhone / iPad 应用目标
  Application.swift           ★ 唯一的设备分流点（SFIUIFamily）
  HakoPhoneRootView.swift     fork 拥有的手机根视图
  HakoPageContent.swift       ★ 唯一的手机页面路由缝（六个一级页面全部指向 Hako 页面本体）
  MainView.swift              上游的 iPad 根视图（未被本 fork 修改）
  ApplicationDelegate.swift   App 代理
  *_WrapperView.swift         编辑器包装（共享）
  Info.plist / *.entitlements / *.plist

SFM/ , SFM.System/            macOS 应用与独立宿主目标
SFT/                          tvOS 目标（不在本项目定制范围）
MacLibrary/                   macOS 专属界面与窗口（MainView 与上游一致）
                              ApplicationDelegate、CodeEditTextView、
                              GhosttyConfigEditorWrapperView、菜单栏控制器 …

ApplicationLibrary/           共享的界面框架（iOS / macOS / tvOS 共用）
  Views/
    HakoStyle/                ★ 手机 UI 的全部所有权边界（19 个 .swift）

      原版共享组件（必须与 c1935cf 逐字节相同）：
        HakoTheme、HakoSurface、HakoCard、HakoRow、HakoScaffold、
        HakoStatus、HakoData、HakoEmptyState、HakoPrimaryShell、HakoUITrace

      原版页面（按 UI token 对照原版，不要求逐字节）：
        HakoHomeView

      从原版机械移植的页面（生成物，勿手改）：
        HakoGroupListView、HakoConnectionListView、HakoLogView、
        HakoToolsView、HakoSettingView

      原版组件的 fork 副本（上游已改，手机需要原版形态）：
        HakoStartStopButton、HakoProfilePickerSheet

      本工程新增、原版没有的：
        HakoNavigation（手机页面名；原版无此文件）
    Abstract/                 共享的页面原语（FormItem、ViewModifiers …）
    Dashboard/                仪表板与卡片（上游所有）
    Groups/  Connections/     代理组与连接（上游所有）
    Log/  Tools/  Setting/    日志、工具、设置（上游所有）
    Profile/  RemoteControl/  配置与远控（上游所有）
    Terminal/  Scanner/       终端与扫码（上游所有）

Library/                      共享业务层（一份，三个平台共用）
  Database/                   Profile、ProfileManager、GRDB 迁移、
                              RemoteProfileUpdatePolicy、RemoteRefreshApplier
  Network/                    CommandClient、ExtensionProfile、HTTPClient、
                              RemoteProfileFetcher、SubscriptionInfo、
                              ScreenStateObserver（+ Darwin 桥）、ExtensionProvider
  Shared/                     Variant、BlockingIO、报告归档与管理器
  Update/                     更新检查

Extension/                    网络扩展（PacketTunnelProvider）
SystemExtension/              macOS 系统扩展
HelperService/                特权助手（XPC）
Jailbreak/ , JailbreakDaemon/ 越狱构建的守护进程与打包脚本
ShareExtension*/ ActionExtension/ FileProviderExtension/
IntentsExtension/ TVExtension/ WidgetExtension/   各扩展目标

Frameworks/Runestone          子模块（gitlink，本 fork 未改动）

sing-box.xcodeproj/           Xcode 工程
Localizable.xcstrings         String Catalog（374 KB，生成物）
Tests/HakoSubscriptionUsage/  ★ 无需模拟器的 SwiftPM 测试包（订阅流量链路）
SFIUITests/ SFMUITests/ SFTUITests/ UITests/   上游的 UI 测试目标

scripts/
  dev/audit_apple_ui_boundary.py       ★ 静态边界审计（本项目的验收工具）
  dev/test_audit_apple_ui_boundary.py  ★ 审计的负例套件（14 个案例）
  dev/set_display_name.py              重新应用可见产品名（幂等，合并上游后运行）
  link-test-sources.sh                 把真实源码以符号链接接入测试包
  run-subscription-usage-tests.sh      运行上述测试包

docs/
  APPLE-REFACTOR-BASELINES.md          不可变引用与固定上游基线
  APPLE-ARCHITECTURE-AUDIT.md          ★ 架构审计报告（FACT / INFERENCE / UNKNOWN）
  UPSTREAM-SYNC-PLAYBOOK.md            ★ 上游同步的逐步操作手册
  APPLE-DEVICE-ACCEPTANCE.md           ★ 待执行的 Apple 平台验收清单
  APPLE-REFACTOR-FINAL-REPORT.md       本轮施工的最终报告
  SNAPSHOT-FIXTURE-CONTRACT.md         ★ 截图 fixture 读哪些变量、如何加状态、哪些状态测不到
  pending/                             未能原样取用的 fork 资产（含原因）
```

★ = 本项目架构的关键位置。

---

## Rules for AI Contributors — 协作者与 AI 的修改边界

新增功能前先确定它属于哪一层。**放错层的代价不是一次编辑，而是此后每一次上游同步。**

| 你想做的事 | 应该改哪里 |
|---|---|
| 改**手机**某页的视觉 | 在 `ApplicationLibrary/Views/HakoStyle/` 建 Hako 页面文件，把 `SFI/HakoPageContent.swift` 的对应分支指过去 |
| 改**某个页面的行为**（iPad/Mac 也能看到） | 改共享文件，写最小 diff，并把该文件加进审计脚本的 `REVIEWED_UPSTREAM_MODIFICATIONS` 并写明理由 |
| 加一个新的设计 token | 加进 `HakoStyle/`（新增是安全的） |
| 改**设备分流规则** | 只改 `SFI/Application.swift` 的 `SFIUIFamily`，并预期审计会检查你的改动 |
| 修一个上游也有的缺陷 | 改共享文件，独立提交，`BUGFIX` 与品牌重命名**不要混在同一个提交** |
| 改可见应用名 | 运行 `python scripts/dev/set_display_name.py`（幂等） |

### 绝对不要

1. **不要用 `#if os(iOS)` 表示「仅 iPhone」。** iPadOS 的 App 也满足它。
   设备家族只由 `SFIUIFamily.resolve(idiom:)` 决定。
2. **不要在共享组件里读 `UIDevice` 或 `horizontalSizeClass` 去改呈现。**
   这是 iPad 掉进手机外壳的机制，审计的 `phone-entry` 检查会失败。
3. **不要让上游可达页面引用任何 Hako 符号**（类型名或成员名，注释里也算）。
   审计的 `shared-pages-are-clean` 与 `no-reverse-dependency` 会失败。
4. **不要复制一整套官方 iPad/Mac 界面代码。** 那些文件就是上游文件本身，
   复制会产生两份需要同步的官方代码。
5. **不要把品牌改名扩散到** `PRODUCT_BUNDLE_IDENTIFIER`、`BASE_PACKAGE_IDENTIFIER`
   （它同时是 URL scheme 与 UTI 前缀）、`PRODUCT_NAME`、App Group、Keychain group、
   `Variant.applicationName`（它进 VPN profile 的 `localizedDescription`、User-Agent 和 Siri）、
   iCloud 容器名、扩展标识。
6. **不要动** `Frameworks/Runestone` 的 gitlink、任何签名设置、任何 entitlement。
7. **不要更新父仓库的 `clients/apple` gitlink，不要切换 GitHub 默认分支，
   不要打 tag 或建 Release。** 这些是发布动作，由人决定。
8. **不要整体替换 `Localizable.xcstrings`。** 它是生成物，逐键按序插入。
9. **不要为了让静态检查通过而改 libbox 调用点。** 那会掩盖隧道里的运行时故障，
   见 [`docs/UPSTREAM-SYNC-PLAYBOOK.md`](docs/UPSTREAM-SYNC-PLAYBOOK.md) 第 4 节。
10. **不要在没有验证的情况下声称编译或真机通过。** 见下面的构建状态。

### 改完之后必须运行

```bash
python scripts/dev/audit_apple_ui_boundary.py --upstream-ref 089d35e   # 应当是 PASS 9 FAIL 0
python scripts/dev/test_audit_apple_ui_boundary.py                     # 14/14 应当按设计行为
```

`UNKNOWN` 不是通过。它意味着一次比较没能进行——在继续之前把它修好。

---

## Upstream Sync Strategy

**唯一开发参考基线是 `upstream/dev`。** `main` 与 `stable` 不并入本分支。

四条规则：

1. **按语义挑选，不要 cherry-pick 计数。** 本 fork 的 ahead/behind 数字曾经两次误导：
   部分「上游独有」提交在 fork 侧已以不同 SHA 存在，而 merge-base 本身也被 rebase 过。
   先跑 `git log --left-right --cherry-pick`。
2. **界面优先官方。** 上游改 UI，就取上游的。
3. **手机 Hako 与品牌优先 fork。** 这些是产品差异，不是待合并的分歧。
4. **共享业务缺陷逐项审计。** 上游可能已经用更好的方式修了同一个问题；
   也可能像屏幕状态观察者那样**带着缺陷**，那就修它并登记理由。

完整操作步骤（含冲突分类表、pbxproj 处理规则、回退方式）见
[`docs/UPSTREAM-SYNC-PLAYBOOK.md`](docs/UPSTREAM-SYNC-PLAYBOOK.md)。

---

## Branch Roles

| 分支 | 角色 | 状态 |
|---|---|---|
| `jiejiebox/integrated` | **集成分支**，从 `upstream/dev` @ `089d35e` 建立 | 当前开发线 |
| `upstream/dev` | SagerNet 官方开发线，只 fetch 不推送 | 只读参考 |
| `hako-ui` | 历史：最新 iPhone Hako UI（含 `c1935cf` 剩余流量） | **保全，不再作为主线** |
| `ipad-upstream-ui` | 历史：曾恢复 iPad 官方根入口 | **保全**。它的 `SFIUIFamily` 思路已吸收；它的共享页面污染未解决 |
| `fix/libbox-stringbox-callsites` | 历史：libbox `StringBox` 调用点修复 | **保全**。判定为 UNKNOWN，未采纳，见审计 §5.1 |
| `fix/apple-notify-unknown` | 历史：屏幕状态观察者修复 | **保全**。已采纳为 `f77289f` |
| `dev`（fork 默认） | 历史：上游历史 + 少量 fork 提交 | **保全**。**默认分支仍是它** |
| `main` / `stable` | 上游历史 | 保全，不作为施工基线 |

**历史分支只保全，不再开发。** 不要删除它们，也不要把它们 rebase 到新线上：
其他工作可能仍在读取它们。

---

## Build and Validation Status

本仓库目前在 **Windows** 上维护，这台机器上**没有 Xcode、没有 macOS、没有 Swift 工具链，
并且 `Libbox.xcframework` 不存在**（`.gitignore` 排除了它，它来自父仓库内核的构建产物）。
因此验证必须分成三层来看，**它们不可互相替代**：

| 层次 | 本机状态 | 如何表达 |
|---|---|---|
| Git + 静态完整性 | **可以运行，且已通过** | `PASS 9 / FAIL 0 / UNKNOWN 0` |
| 审计的负例套件 | **可以运行，且已通过** | 14/14 按设计行为 |
| Swift 编译 / Xcode 构建 | **不可能** | `UNVERIFIED: no Xcode, no macOS, no Libbox.xcframework` |
| `swift test`（订阅流量包） | **不可能** | `UNVERIFIED: no Swift toolchain` |
| iPhone / iPad / Mac 真机与模拟器 | **未执行** | `DEFERRED: 无 Apple 设备` |
| NetworkExtension / Libbox 联调 | **未执行** | `DEFERRED: 需签名与设备` |

**这份 README 不声称任何编译或真机结果。** 完整清单见
[`docs/APPLE-DEVICE-ACCEPTANCE.md`](docs/APPLE-DEVICE-ACCEPTANCE.md)。

### 已完成的（源码层面）

- 设备分流：手机走 Hako 外壳，iPad 与 Mac 走上游根视图，由设备类型而非尺寸类别决定。
- iPad 与 Mac 的根视图、侧边栏、`NavigationPage` 与**全部共享页面**与上游逐字节相同。
- 339 个 Swift 文件中**没有一条**从上游可达代码指向 Hako 的依赖边。
- 订阅流量链路（解析 → 获取 → 合并 → 持久化 → 取件行显示）完整可静态追踪，
  并有独立的 SwiftPM 测试包。
- 可见产品名 overlay 为 `Jiejiebox`，身份 / 协议 / 签名面未动。
- 屏幕状态观察者的上游缺陷已修复（失败的通知读取不再被当作解锁）。

### 已知未完成

- **手机的 Hako 页面本体尚未迁移**：手机当前得到的是「Hako 外壳 + 上游页面」。
  功能不减，但视觉未达 Hako 目标。见 [`docs/pending/README.md`](docs/pending/README.md)。
- **libbox `StringBox` 调用点未决**：无框架，无法判定，见
  [`docs/APPLE-ARCHITECTURE-AUDIT.md`](docs/APPLE-ARCHITECTURE-AUDIT.md) §5.1。
- **全部 Apple 平台验证未执行**，见上一节。

---

## Related Documentation

- [第二阶段最终报告](docs/PHASE2-FINAL-REPORT.md) — 当前阶段的完整交付说明：首屏结论、核验与更正、屏幕状态专项、迁移矩阵、审计与测试证据
- [迁移矩阵](docs/HAKO-UI-MIGRATION-MATRIX.md) — 手机逐页的状态与新增页面的规则
- [第二阶段进度](docs/PHASE2-STATUS.md) — 正在进行的记录
- [屏幕状态与锁屏事实](docs/SCREEN-STATE-FACTS.md) — 内核契约与竞态判定
- [架构审计报告](docs/APPLE-ARCHITECTURE-AUDIT.md) — 独立复核、FACT/INFERENCE/UNKNOWN 判定、
  可达链审计、遗留风险与盲区
- [上游同步手册](docs/UPSTREAM-SYNC-PLAYBOOK.md) — 逐步操作、冲突分类、回退方式
- [设备验收清单](docs/APPLE-DEVICE-ACCEPTANCE.md) — 待执行的编译与真机检查
- [施工基线记录](docs/APPLE-REFACTOR-BASELINES.md) — 不可变引用、固定 SHA、差异矩阵
- [最终报告](docs/APPLE-REFACTOR-FINAL-REPORT.md) — 本轮施工的完整交付说明
- [待迁移资产](docs/pending/README.md) — 未能原样取用的 fork 工作及其原因

---

## Upstream, Documentation, License

本项目的上游是 SagerNet 的官方客户端：

- 上游仓库：<https://github.com/SagerNet/sing-box-for-apple>
- 内核仓库：<https://github.com/SagerNet/sing-box>
- 官方文档：<https://sing-box.sagernet.org/>
- 本 fork 的父仓库（含内核）：<https://github.com/Piggy-Cat-bit-shadow/sing-box>

**本项目是非官方客户端。** 上游的品牌、文档与版权归属予以保留，
不以 Jiejiebox 冒充官方 SagerNet 产品。

### License

```
Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.
```

完整许可证文本见 [`LICENSE`](LICENSE)。
